# typed: strict
# frozen_string_literal: true

module Triage
  module Detectors
    # An endpoint or job the agent caught running the same query once per
    # row: the textbook fix (eager loading), and nearly always worth it.
    #
    # The agent flags any statement repeated a few times in one run; that
    # includes loading in batches (find_each: one page query and one preload
    # per batch), which is the fix, not the problem. So where the flagged runs
    # were kept, their statements are read: a scalar-key lookup or a write
    # repeated per row is an N+1, a page query never is, and a preload
    # (`IN (?)`) only when it far outnumbers the pages. Runs never kept leave
    # nothing to read, and the flag stands.
    class NPlusOne < WorkDetector
      MIN_SEEN = 5
      MIN_SHARE = 0.1
      # Executions per run that make a repeat (the agent's N1_THRESHOLD).
      REPEATED = 5
      # A preload is one per batch; this many per batch and it is per row.
      PRELOADS_PER_BATCH = 2
      # The flagged, kept runs read for their statements.
      EXAMINED = 5
      # A page of a batched read: keyset (`id > ? ORDER BY`) or offset.
      PAGE = T.let(/>\s*\?.*\bORDER BY\b|\bOFFSET\s+\?/im, Regexp)
      PRELOAD = T.let(/\bIN\s*\(\s*\?\s*\)/i, Regexp)
      # One INSERT of several rows is a batch already.
      MULTI_ROW_INSERT = T.let(/\A\s*INSERT\b.*\bVALUES\s*\([^)]*\)\s*,\s*\(/im, Regexp)
      # Session and transaction control repeats by design and reads no rows
      # (the agent's Transaction::SESSION_STATEMENT): never the statement to
      # preload, though traces flagged before the agent knew it still list it.
      SESSION_STATEMENTS = T.let(%w[SET RESET SHOW BEGIN COMMIT ROLLBACK SAVEPOINT RELEASE].freeze, T::Array[String])
      NOT_SESSION = T.let("-resource:#{SESSION_STATEMENTS.flat_map { |word| [ "#{word}*", "#{word.downcase}*" ] }.join(',')}",
        String)
      # Solid Queue's per-job dispatch after an enqueue (the agent's
      # Transaction::QUEUE_STATEMENT): a concurrency-limited job takes its
      # semaphore one job at a time even when enqueued in bulk. The enqueue
      # itself stays — perform_later in a loop is the N+1 worth naming.
      QUEUE_BOOKKEEPING = T.let(%w[SELECT*solid_queue_* UPDATE*solid_queue_* DELETE*solid_queue_*
        INSERT*solid_queue_semaphores* INSERT*solid_queue_*executions*].freeze, T::Array[String])
      NOT_QUEUE = T.let("-resource:#{QUEUE_BOOKKEEPING.flat_map { |pattern| [ pattern, pattern.sub(/\A[A-Z]+/, &:downcase) ] }.join(',')}",
        String)

      FLAGGED_KEPT = "n_plus_one:true kept:true"

      sig { override.returns(Kind) }
      def self.kind = Kind::NPlusOne

      # A unit of work flagged often enough to be read for its statement.
      class Candidate < T::Struct
        const :key, WorkDetector::Key
        const :row, Scan::Row
        const :seen, Float
        const :share, Float
      end

      # What a candidate's kept runs say it repeats per row (see per_row).
      Verdict = T.type_alias { T.nilable(T.any(String, FalseClass)) }

      sig { override.returns(T::Array[Finding]) }
      def findings
        all = now
        candidates = seen.filter_map do |key, count|
          row = all[key]
          next if row.nil? || count < MIN_SEEN

          share = count / row["count"].to_f
          share < MIN_SHARE ? nil : Candidate.new(key: key, row: row, seen: count, share: share)
        end
        verdicts = per_row(candidates.map(&:key))
        candidates.filter_map do |candidate|
          key = candidate.key
          row = candidate.row
          count = candidate.seen
          share = candidate.share
          subject = work_subject(key)
          statement = verdicts[key]
          next if statement == false

          score = 20 + 30 * share + 10 * scale(row["avg(db_count)"], 50.0) + 10 * scale(count, 500.0)
          finding(subject, score: score,
            title: "#{label(subject)} repeats a query per row",
            summary: "#{Words.percent(share)} of its #{Words.count(row['count'])} #{Words.noun(key[1], row['count'])} ran an N+1 " \
                     "query; they average #{row['avg(db_count)'].to_f.round(1)} queries and #{Words.ms(row['avg(db)'])} in the database" \
                     "#{statement ? ". The one per row: #{Words.clip(statement, 80)}" : ''}.",
            figures: { "count" => row["count"], "seen" => count, "share" => share, "queries" => row["avg(db_count)"], "db_ms" => row["avg(db)"],
                       "statement" => statement || nil })
        end
      end

      sig { override.params(finding: Finding).returns(Detail) }
      def detail(finding)
        subject = finding.subject
        filter = subject_filter(subject)
        current = subject_now
        kept = scan.list(source: "transactions", filter: "#{filter} #{FLAGGED_KEPT}", limit: 20).filter_map { |row| row["trace"] }.uniq
        evidence = [
          chart("Queries per call", scan.chart(source: "transactions", filter: filter, compute: [ "avg(db_count)", "avg(db)" ])),
          repeated(kept),
          traces("Traces that ran it", "#{filter} n_plus_one:true", order: "-db_count"),
          phases(current, subject_before)
        ]
        work_detail(finding,
          description: "An N+1 is a query run once to load a list and then once more for every item in " \
                       "it — typically an association read inside a loop or a view. It grows with the data, so it gets worse " \
                       "on its own. The repeated statements below are read from the kept traces' spans: the one with the most " \
                       "executions is the association to preload.",
          facts: work_facts(subject, current) + [ fact("Queries per call", current["avg(db_count)"]&.to_f&.round(1)) ].compact,
          evidence: evidence,
          steps: [
            "Take the most-repeated statement below and find the association it loads in #{subject.name} or the views it renders.",
            "Preload it (includes / preload / eager_load), or replace the per-row reads with one query.",
            "Add a test that counts queries, so it cannot come back unnoticed.",
            "Done when queries per call no longer grow with the number of rows and the N+1 flag stops appearing."
          ])
      end

      private

      # How many of each unit of work's rows carried the N+1 flag.
      sig { returns(T::Hash[WorkDetector::Key, Float]) }
      def seen
        group_by = %w[app kind name]
        rows = scan.table(source: "transactions", group_by: group_by, compute: %w[count], filter: scan.filter(narrow, "n_plus_one:true"))
        scan.keyed(rows, group_by).transform_values { |row| row["count"].to_f }
      end

      # The statement each unit of work runs once per row, read from its
      # flagged, kept runs: the most repeated one that is neither a page of a
      # batched read nor a preload per page. nil when no run was kept or its
      # statements never arrived (the flag is all there is), false when the
      # runs hold none — they load in batches.
      #
      # Three statements for every candidate together — their newest kept
      # runs, then those traces' runs and statements — rather than three
      # each. A reading that comes back full may have been cut, and the
      # candidates it could have shortchanged are read alone, as before.
      sig { params(keys: T::Array[WorkDetector::Key]).returns(T::Hash[WorkDetector::Key, Verdict]) }
      def per_row(keys)
        examined = examined(keys)
        everything = examined.values.flatten.uniq
        together = everything.empty? ? nil : read_traces(everything)
        together = nil if together && (together.first.size >= Query::Request::MAX_LIMIT || together.last.size >= Query::Request::MAX_LIMIT)
        keys.to_h do |key|
          traces = T.must(examined[key])
          next [ key, nil ] if traces.empty?

          runs, statements = together || read_traces(traces)
          [ key, repeats(traces, runs, statements) ]
        end
      end

      # The traces of each unit of work's EXAMINED newest flagged, kept runs:
      # one list of every candidate's, newest first, and a list of its own
      # for a candidate that list may have cut short.
      sig { params(keys: T::Array[WorkDetector::Key]).returns(T::Hash[WorkDetector::Key, T::Array[String]]) }
      def examined(keys)
        return {} if keys.empty?

        rows = scan.list(source: "transactions", limit: Query::Request::MAX_LIMIT,
          filter: scan.filter(narrow, FLAGGED_KEPT, Query::Filter.quote_any("kind", keys.map { |key| key[1].to_s }.uniq),
            Query::Filter.quote_any("name", keys.map { |key| key[2].to_s }.uniq)))
        full = rows.size >= Query::Request::MAX_LIMIT
        mine = T.let(rows.group_by { |row| [ row["app"], row["kind"], row["name"] ] }, T::Hash[WorkDetector::Key, T::Array[Scan::Row]])
        keys.to_h do |key|
          runs = mine.fetch(key, [])
          if full && runs.size < EXAMINED
            runs = scan.list(source: "transactions", filter: "#{subject_filter(work_subject(key))} #{FLAGGED_KEPT}", limit: EXAMINED)
          end
          [ key, runs.first(EXAMINED).filter_map { |row| row["trace"] }.uniq ]
        end
      end

      # How many flagged, kept runs each trace holds, and its SQL statements
      # by how often they ran.
      sig { params(traces: T::Array[String]).returns([ T::Hash[T.untyped, Float], T::Array[Row] ]) }
      def read_traces(traces)
        # A trace can hold many runs (a fan-out of jobs): count per run that
        # was flagged and kept — the ones whose spans hold the repeats.
        runs = scan.table(source: "transactions", group_by: %w[trace], compute: %w[count],
          filter: "trace:#{traces.join(',')} #{FLAGGED_KEPT}")
          .to_h { |row| [ row["trace"], [ row["count"].to_f, 1.0 ].max ] }
        statements = scan.table(source: "spans", group_by: %w[trace resource], compute: %w[count],
          filter: "trace:#{traces.join(',')} kind:sql #{NOT_SESSION} #{NOT_QUEUE}")
        [ runs, statements ]
      end

      # The statement `traces` repeat per row, from their runs and
      # statements (see per_row).
      sig { params(traces: T::Array[String], runs: T::Hash[T.untyped, Float], statements: T::Array[Row]).returns(Verdict) }
      def repeats(traces, runs, statements)
        wanted = traces.to_set
        statements = statements.select { |row| wanted.include?(row["trace"]) }
        return nil if statements.empty?

        repeats = statements.group_by { |row| row["trace"] }.flat_map do |trace, rows|
          each = rows.to_h { |row| [ row["resource"].to_s, row["count"].to_f / runs.fetch(trace, 1.0) ] }
          batches = [ each.select { |resource, _| PAGE.match?(resource) }.values.max.to_f, 1.0 ].max
          each.select do |resource, times|
            next false if times < REPEATED || PAGE.match?(resource) || MULTI_ROW_INSERT.match?(resource)

            !PRELOAD.match?(resource) || times > PRELOADS_PER_BATCH * batches
          end.to_a
        end
        repeats.max_by { |_, times| times }&.first || false
      end

      # The SQL the kept traces ran most often: which query repeats.
      sig { params(traces: T::Array[String]).returns(T.nilable(Evidence)) }
      def repeated(traces)
        return nil if traces.empty?

        rows = scan.table(source: "spans", group_by: %w[resource], compute: [ "count", "avg(duration)", "sum(duration)" ],
          filter: "trace:#{traces.join(',')} kind:sql #{NOT_SESSION} #{NOT_QUEUE}", limit: 8)
        table("The statements that repeat", [ column("resource", "Statement"), column("count", "Executions"),
          column("avg(duration)", "Avg", "ms"), column("sum(duration)", "Total", "ms") ], rows,
          note: "Across #{traces.size} kept traces of it that were flagged.")
      end
    end
  end
end
