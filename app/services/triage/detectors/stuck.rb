# typed: strict
# frozen_string_literal: true

module Triage
  module Detectors
    # A job still running far past its habit: the profiler keeps sampling
    # it on a host where it has not finished since, for several times the
    # longest it usually takes. It holds a worker thread the whole time, so
    # everything behind it on its queue waits — the queue finding that
    # follows is this one's symptom, and ranks below it.
    class Stuck < WorkDetector
      # How many of its p99 runs a job must have been going…
      TIMES = 5
      # …and this long at least.
      MIN_STUCK_MS = 900_000.0
      # The stretch a job must be sampled in, up to the end of the range,
      # to count as running now…
      RECENT = T.let(10.minutes, ActiveSupport::Duration)
      # …and the share of one thread's time it must hold there and since it
      # last finished: a thread in it all along, not runs that come and go.
      HELD = 0.8

      sig { override.returns(Kind) }
      def self.kind = Kind::Stuck

      sig { override.returns(T::Array[Finding]) }
      def findings
        habits = job_habits
        running.group_by { |row| [ row["app"], row["transaction"] ] }.filter_map do |(app, name), hosts|
          habit = habits[[ app, name ]]
          next if habit.nil?

          threshold = [ MIN_STUCK_MS, TIMES * habit ].max
          held = hosts.filter_map { |row| held(app, name, row["host"].to_s, threshold) }
          next if held.empty?

          since = held.map { |found| found[:since] }.min.to_f
          threads = held.sum { |found| found[:threads] }
          elapsed = (window.to.to_f - since) * 1000
          subject = Subject.new(kind: self.class.kind, app: app, work: "job", name: name.to_s)
          finding(subject, score: 75 + 20 * scale(elapsed / threshold, 20.0),
            title: "#{label(subject)} has run #{Words.elapsed(elapsed)} without finishing",
            summary: "#{threads} worker #{threads == 1 ? 'thread has' : 'threads have'} been inside it since " \
                     "#{Time.at(since).utc.strftime('%Y-%m-%d %H:%M')} UTC on #{held.map { |found| found[:host] }.join(', ')}; " \
                     "it usually finishes within #{Words.ms(habit)} (p99). Everything behind it on its queue waits.",
            figures: { "since" => since, "elapsed_ms" => elapsed, "p99" => habit, "threads" => threads,
                       "hosts" => held.map { |found| found[:host] } })
        end
      end

      sig { override.params(finding: Finding).returns(Detail) }
      def detail(finding)
        subject = finding.subject
        filter = subject_filter(subject)
        hosts = Array(finding.figures["hosts"])
        samples = [ "app:#{subject.app}", Query::Filter.quote("transaction", subject.name), Query::Filter.quote_any("host", hosts) ].join(" ")
        Detail.build(finding: finding,
          description: "The profiler samples every thread once a few milliseconds and names the job it is in; this one has " \
                       "been sampled without a break since it last finished on the host, for far longer than any run of it " \
                       "takes. It is not slow, it is stuck — waiting on something that will not answer (a subprocess, a " \
                       "socket without a timeout, a lock) or looping. Each stuck run holds a worker thread, so jobs on the " \
                       "same queue wait behind it: a queue wait finding for that queue is this, not a capacity problem.",
          facts: [ fact("App", subject.app), fact("Job", subject.name), fact("Hosts", hosts.join(", ")),
                   fact("Threads held", finding.figures["threads"]), fact("Running since", Time.at(finding.figures["since"].to_f).utc.iso8601),
                   fact("Usual run (p99)", Words.ms(finding.figures["p99"])) ].compact,
          evidence: [
            chart("Profiled time in the job", scan.chart(source: "profiles", filter: samples, compute: [ "sum(ms)" ])),
            started(subject, hosts),
            functions(samples),
            traces("Runs that finished", filter)
          ],
          steps: [
            "Read the functions table: the stack the stuck thread sits in (IO#wait, Process.wait, a socket read, a mutex) is what it waits on.",
            "Open the trace of the run that started and never finished (get_trace) for what it did before it stopped.",
            "Put a timeout on that call — a subprocess, an HTTP request, a lock — so a run that cannot finish fails instead of holding a worker.",
            "Restart the worker to free the threads now; the jobs queued behind it will drain.",
            "Done when no run of #{subject.name} outlives #{Words.ms(TIMES * finding.figures['p99'].to_f)} and its queue's wait falls back."
          ],
          source: "transactions", filter: filter)
      end

      private

      # Jobs sampled on a host through the last minutes of the range, held
      # most of that time: rows of app, host and transaction.
      sig { returns(T::Array[Row]) }
      def running
        from = window.to - RECENT
        terms = (subject = scan.subject) ? Query::Filter.quote("transaction", subject.name) : nil
        rows = scan.table(source: "profiles", group_by: %w[app host transaction], compute: [ "sum(ms)" ], filter: scan.filter(terms),
          between: [ from, window.to ])
        rows.select { |row| row["transaction"].present? && row["sum(ms)"].to_f >= HELD * RECENT.in_seconds * 1000 }
      end

      # How long each job usually takes, by app and name: its p99 over the
      # range or the window before, whichever is shorter — a run that hung
      # before and was killed must not raise the bar for the next. A job
      # that never finished in either has no habit to be past.
      sig { returns(T::Hash[[ T.untyped, T.untyped ], Float]) }
      def job_habits
        [ false, true ].each_with_object({}) do |baseline, habits|
          scan.table(source: "transactions", group_by: %w[app name], compute: [ "p99(duration)" ], filter: scan.filter("kind:job"),
            baseline: baseline).each do |row|
            key = [ row["app"], row["name"] ]
            habits[key] = [ habits[key], row["p99(duration)"].to_f ].compact.min
          end
        end
      end

      # A host where the job has run, without finishing, for longer than
      # `threshold`: since its last run there finished (or the range began),
      # a thread has been in it nearly all the time. nil when not.
      sig do
        params(app: T.untyped, name: T.untyped, host: String, threshold: Float)
          .returns(T.nilable({ host: String, since: Float, threads: Integer }))
      end
      def held(app, name, host, threshold)
        last = scan.list(source: "transactions", filter: "app:#{app} kind:job #{Query::Filter.quote('name', name)} #{Query::Filter.quote('host', host)}",
          limit: 1).first
        since = [ window.from.to_f, last ? last["ts"].to_f + last["duration"].to_f / 1000 : 0.0 ].max
        return nil if (window.to.to_f - since) * 1000 < threshold

        rows = scan.table(source: "profiles", group_by: %w[host], compute: [ "sum(ms)" ],
          filter: "app:#{app} #{Query::Filter.quote('transaction', name)} #{Query::Filter.quote('host', host)}", between: [ Time.at(since), window.to ])
        sampled = rows.first&.dig("sum(ms)").to_f
        span = (window.to.to_f - since) * 1000
        return nil if sampled < HELD * span

        { host: host, since: since, threads: [ (sampled / span).round, 1 ].max }
      end

      # The starts of the job on its hosts that no finished run answers: the
      # log line a run writes as it begins carries its span, and a run that
      # finished is a row under the same span.
      sig { params(subject: Subject, hosts: T::Array[String]).returns(Evidence) }
      def started(subject, hosts)
        on = [ "app:#{subject.app}", Query::Filter.quote_any("host", hosts) ].join(" ")
        finished = scan.list(source: "transactions", filter: "#{on} #{subject_terms(subject)}", limit: 200).to_set { |row| row["span"] }
        rows = scan.list(source: "logs", filter: "#{on} #{Query::Filter.quote_text(subject.name)}", limit: 50)
          .reject { |row| row["span"].nil? || finished.include?(row["span"]) }
          .group_by { |row| row["span"] }.values.map { |lines| T.must(lines.min_by { |row| row["ts"].to_f }) }
        Evidence.new(type: Evidence::Type::Logs, title: "Started, never finished",
          rows: rows.first(6).map { |row| row.slice("ts", "app", "level", "message", "source", "release", "trace").compact },
          note: "The first line each unfinished run wrote; its trace is the run to open.")
      end
    end
  end
end
