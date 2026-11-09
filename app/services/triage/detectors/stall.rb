# typed: strict
# frozen_string_literal: true

module Triage
  module Detectors
    # Several of an app's endpoints slow at the same moments, while the
    # profiler shows them opening database connections more than they used
    # to (Triage::Stalls): one problem in what they share — a quiet stretch
    # lets the pool close its connections, and the next visit pays to open
    # them again — not one regression each.
    class Stall < Detector
      NAME = "requests"

      sig { override.returns(Kind) }
      def self.kind = Kind::Stall

      sig { override.returns(T::Array[Finding]) }
      def findings
        scan.stalls.apps.values.map do |stalled|
          subject = Subject.new(kind: self.class.kind, app: stalled.app, work: "request", name: NAME)
          names = stalled.names
          widest = stalled.moments.map { |moment| moment.names.size }.max
          score = 35 + 20 * scale(stalled.moments.size, 20.0) + 25 * scale(stalled.excess_ms, 120_000.0)
          finding(subject, score: score,
            title: "#{stalled.app}'s requests wait on new database connections",
            summary: "#{Words.count(stalled.moments.size)} times, up to #{widest} endpoints were slow within the same " \
                     "#{Words.trim(Stalls::MOMENT_S, 0)} s (#{names.first(3).join(', ')}#{names.size > 3 ? ', …' : ''}), " \
                     "#{Words.ms(stalled.excess_ms)} lost in all; opening database connections takes " \
                     "#{Words.percent(stalled.connecting)} of their profiled time, against #{Words.percent(stalled.connecting_before)} before.",
            figures: { "moments" => stalled.moments.size, "endpoints" => names, "excess_ms" => stalled.excess_ms,
                       "connecting_share" => stalled.connecting, "connecting_share_before" => stalled.connecting_before })
        end
      end

      sig { override.params(finding: Finding).returns(Detail) }
      def detail(finding)
        subject = finding.subject
        stalled = T.must(scan.stalls.apps[subject.app.to_s])
        names = stalled.names
        filter = [ "app:#{subject.app}", "kind:request", Query::Filter.quote_any("name", names) ].join(" ")
        moments = stalled.moments.sort_by { |moment| -moment.at }.first(12).map do |moment|
          { "ts" => moment.at, "endpoints" => moment.names.size, "names" => moment.names.join(", "),
            "slowest" => moment.rows.first&.dig("duration") }
        end
        kept = stalled.moments.flat_map(&:rows).select { |row| row["kept"] }.filter_map { |row| row["trace"] }.uniq.first(20)
        Detail.build(finding: finding,
          description: "These endpoints were slow at the same instants — each well past its own median, within a couple " \
                       "of seconds of the others — and much less so in between, while the profiler shows them opening " \
                       "database connections far more than before. Code paths that share nothing but the process do not " \
                       "slow down together on their own: what they share does. A pool that closes idle connections " \
                       "(Rails' `idle_timeout`, five minutes by default) leaves none open after a quiet stretch, so the " \
                       "next visit opens them again and prepares its statements anew — the first query of each request " \
                       "is the slow one. It shows when traffic is sparse, which is why the comparison with busier hours " \
                       "looks like every endpoint regressed.",
          facts: [ fact("App", subject.app), fact("Moments", stalled.moments.size), fact("Endpoints", names.join(", ")),
                   fact("Time lost", Words.ms(stalled.excess_ms)) ].compact,
          evidence: [
            table("The moments", [ column("ts", "When", "time"), column("endpoints", "Endpoints", "count"), column("names", "Which"),
              column("slowest", "Slowest", "ms") ], moments, note: "The latest first. Requests within #{Words.trim(Stalls::MOMENT_S, 0)} s are one moment."),
            statements(kept),
            functions(profile_filter(subject.app, names)),
            traces("Slowest requests in range", filter, order: "-duration"),
            markers(subject.app)
          ],
          steps: [
            "Open a slow trace from a moment (get_trace): its first query should be the slow one — an indexed lookup waiting on its connection.",
            "Keep the web process's connections open between visits — raise `idle_timeout` in config/database.yml (0 never " \
            "reaps them), or keep the pool warm — rather than tuning each endpoint.",
            "If restarts line up with the moments instead (the deploys table), it is a fresh process opening its pool: warm it at boot.",
            "Done when slow requests come alone, not several endpoints at once."
          ],
          source: "transactions", filter: filter)
      end

      private

      # The statements the moments' kept traces ran, slowest first: the
      # first query of a request on a new connection is the slow one.
      sig { params(traces: T::Array[String]).returns(T.nilable(Evidence)) }
      def statements(traces)
        return nil if traces.empty?

        rows = scan.table(source: "spans", group_by: %w[resource], compute: [ "count", "max(duration)", "avg(duration)" ],
          filter: "trace:#{traces.join(',')} kind:sql", order: "-max(duration)", limit: 8)
        table("The statements those requests waited on", [ column("resource", "Statement"), column("count", "Executions"),
          column("max(duration)", "Slowest", "ms"), column("avg(duration)", "Avg", "ms") ], rows,
          note: "From #{traces.size} kept traces in the moments. An indexed lookup that is slow only here was waiting on its connection.")
      end
    end
  end
end
