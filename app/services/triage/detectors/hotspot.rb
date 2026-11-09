# typed: strict
# frozen_string_literal: true

module Triage
  module Detectors
    # Where an app's time goes: the endpoint or job that takes a large share
    # of all the time its app spends, and is slow while doing it. Not a
    # change — a standing cost, and the best return on an hour of tuning.
    class Hotspot < WorkDetector
      MIN_COUNT = 20
      MIN_SHARE = 0.2
      # A share of an app's time means something only beside others: an app
      # with one job spends all its job time in it.
      MIN_NEIGHBOURS = 3

      sig { override.returns(Kind) }
      def self.kind = Kind::Hotspot

      sig { override.returns(T::Array[Finding]) }
      def findings
        totals = app_totals
        now.filter_map do |key, row|
          next unless Telemetry::Work::TIMED.include?(key[1])

          total, names = totals.fetch([ key[0], key[1] ], [ 0.0, 0 ])
          next if names < MIN_NEIGHBOURS
          spent = row["sum(duration)"].to_f
          next if total <= 0 || row["count"].to_f < MIN_COUNT

          share = spent / total
          p95 = row["p95(duration)"].to_f
          job = key[1] == "job"
          next if share < MIN_SHARE || !slow?(key[1], p95)

          subject = work_subject(key)
          db_share = row["avg(duration)"].to_f.positive? ? row["avg(db)"].to_f / row["avg(duration)"].to_f : 0.0
          score = job ? 10 + 25 * share + 15 * scale(p95, 60_000.0) : 15 + 30 * share + 25 * scale(p95, 2_000.0)
          finding(subject, score: score,
            title: "#{label(subject)} takes #{Words.percent(share)} of #{key[0]}'s #{key[1]} time",
            summary: "#{Words.count(row['count'])} #{Words.noun(key[1], row['count'])} at p95 #{Words.ms(p95)}, " \
                     "#{Words.ms(spent)} in all; #{Words.percent(db_share)} of it in the database " \
                     "(#{row['avg(db_count)'].to_f.round(1)} queries each).",
            figures: { "count" => row["count"], "share" => share, "p95" => p95, "p50" => row["p50(duration)"], "total_ms" => spent,
                       "db_share" => db_share, "queries" => row["avg(db_count)"] })
        end
      end

      sig { override.params(finding: Finding).returns(Detail) }
      def detail(finding)
        subject = finding.subject
        filter = subject_filter(subject)
        current = subject_now
        evidence = [
          chart("Throughput and latency", scan.chart(source: "transactions", filter: filter, compute: [ "count", "p95(duration)" ])),
          phases(current, subject_before),
          functions(profile_filter(subject.app, [ subject.name ])),
          traces("Slowest in range", filter, order: "-duration"),
          by_release(subject)
        ]
        work_detail(finding,
          description: "Nothing about it is new — it is where #{subject.app}'s #{subject.work} time goes, " \
                       "so making it faster is worth more than any other #{subject.work} in the app. Read the phase table " \
                       "first: time in the database wants fewer or cheaper queries (an index, eager loading, a counter cache); " \
                       "time in views wants less rendered or a cache; time in the app's own code is in the functions table, " \
                       "from the profiler.",
          facts: work_facts(subject, current) + [ fact("Queries per call", current["avg(db_count)"]&.to_f&.round(1)) ].compact,
          evidence: evidence,
          steps: [
            "Read the phase table and the profile to decide which part of the time to cut.",
            "Open the slowest traces (get_trace) for the statements and calls that dominate them.",
            "Make the change, measure it against the p95 of #{Words.ms(finding.figures['p95'])} and the share of " \
            "#{Words.percent(finding.figures['share'])} of #{subject.app}'s #{subject.work} time.",
            "Done when p95 drops meaningfully without the result changing — and the slowest traces no longer show the same cost."
          ])
      end

      private

      # Every app's total time by kind of work, and how many names share
      # it — read without the subject's narrowing: a share needs the whole.
      # A scan of the fleet already holds the whole when its reading of work
      # was not cut at the limit.
      sig { returns(T::Hash[[ T.untyped, T.untyped ], [ Float, Integer ]]) }
      def app_totals
        if scan.subject.nil? && scan.work_complete?
          timed = now.select { |key, _| Telemetry::Work::TIMED.include?(key[1]) }
          return timed.group_by { |key, _| [ key[0], key[1] ] }.transform_values do |members|
            [ members.sum { |_, row| row["sum(duration)"].to_f }, members.size ]
          end
        end

        rows = scan.table(source: "transactions", group_by: %w[app kind], compute: [ "sum(duration)", "uniq(name)" ],
          filter: scan.filter("kind:#{Telemetry::Work::TIMED.join(',')}"))
        rows.to_h { |row| [ [ row["app"], row["kind"] ], [ row["sum(duration)"].to_f, row["uniq(name)"].to_i ] ] }
      end
    end
  end
end
