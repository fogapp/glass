# typed: strict
# frozen_string_literal: true

module Triage
  module Detectors
    # An agent that stopped reporting, or one shedding what it collects:
    # either way the rest of Triage is reading less than happened.
    class Reporting < Detector
      # A process kind that reported within this long and has no live
      # process now has stopped, not finished.
      RECENTLY = T.let(1.day, ActiveSupport::Duration)
      STOPPED = "stopped"
      SHEDDING = "shedding"
      # Shedding less than this of what the agents collected leaves no gap
      # anyone could see in a chart: a burst the buffer absorbed but for a
      # few records.
      MIN_SHED_SHARE = 0.01

      sig { override.returns(Kind) }
      def self.kind = Kind::Reporting

      sig { override.returns(T::Array[Finding]) }
      def findings
        return [] unless window.current?

        groups = processes.group_by { |process| [ scan.context.slug(process.app_id), process.kind ] }
        groups.flat_map do |(app, kind), members|
          [ stopped(app, kind, members), shedding(app, kind, members) ].compact
        end.select { |found| (subject = scan.subject).nil? || found.subject.id == subject.id }
      end

      sig { override.params(finding: Finding).returns(Detail) }
      def detail(finding)
        subject = finding.subject
        members = processes.select { |process| scan.context.slug(process.app_id) == subject.app && process.kind == subject.work }
        rows = members.map do |process|
          { "host" => process.host, "pid" => process.pid, "release" => process.release, "last_seen_at" => process.last_seen_at.to_f,
            "live" => process.live? ? "yes" : "no", "records" => process.records,
            "dropped" => process.dropped.sum { |_, count| count.to_i },
            "shed" => process.dropped.select { |_, count| count.to_i.positive? }.map { |type, count| "#{type} #{count}" }.join(", ") }
        end
        stopped = subject.name == STOPPED
        Detail.build(finding: finding,
          description: stopped ? "Glass hears from an agent every ten seconds; this kind of process has " \
                                 "gone quiet. Either the process is down (crashed, scaled to zero, stuck in a boot loop) or it is " \
                                 "running but its agent cannot reach Glass (a changed key, GLASS_URL, a network fault). Fog's " \
                                 "app page says which: a running container with no reports is the agent."
                               : "An agent drops what it cannot send rather than slow the app down — so " \
                                 "these counts are telemetry that never arrived, and every figure for #{subject.app} undercounts. " \
                                 "Usually a buffer too small for a burst, or batches failing to send (a 429 from Glass shedding, " \
                                 "a slow network).",
          facts: [ fact("App", subject.app), fact("Process kind", subject.work), fact("Processes", members.size) ].compact,
          evidence: [
            table("Processes", [ column("host", "Host"), column("pid", "PID"), column("release", "Release", "sha"), column("live", "Live"),
              column("last_seen_at", "Last report", "time"), column("records", "Records"), column("shed", "Shed") ], rows),
            markers(subject.app)
          ],
          steps: stopped ? [
            "Check the app in fog: is the #{subject.work} container running, restarting, or stopped?",
            "If it is running, read its logs for the agent's own warnings (an ingest key rejected, GLASS_URL unreachable).",
            "Done when a #{subject.work} process for #{subject.app} reports again (Fleet shows it live)."
          ] : [
            "Read which record types were shed: spans and logs are the usual ones under a burst.",
            "Lower the volume at the source (log level, trace sampling in Settings › Apps) or raise the agent's buffer.",
            "Done when the shed counts stop growing."
          ],
          source: "transactions", filter: subject_filter(subject))
      end

      private

      sig { returns(T::Array[Telemetry::AgentProcess]) }
      def processes
        @processes ||= T.let(begin
          ids = scan.app ? [ scan.context.app_id(T.must(scan.app)) ].compact : scan.context.app_ids
          Telemetry::AgentProcess.where(app_id: ids, last_seen_at: RECENTLY.ago..).to_a
        end, T.nilable(T::Array[Telemetry::AgentProcess]))
      end

      sig { params(app: T.nilable(String), kind: String, members: T::Array[Telemetry::AgentProcess]).returns(T.nilable(Finding)) }
      def stopped(app, kind, members)
        return nil if members.any?(&:live?)

        last = members.map(&:last_seen_at).max
        finding(Subject.new(kind: self.class.kind, app: app, work: kind, name: STOPPED), score: 80,
          title: "#{app}'s #{kind} processes stopped reporting",
          summary: "#{members.size} #{kind} #{members.size == 1 ? 'process' : 'processes'} reported in the last day; " \
                   "none has since #{last&.utc&.iso8601}.",
          figures: { "processes" => members.size, "last_seen_at" => last&.to_f })
      end

      sig { params(app: T.nilable(String), kind: String, members: T::Array[Telemetry::AgentProcess]).returns(T.nilable(Finding)) }
      def shedding(app, kind, members)
        live = members.select(&:live?)
        shed = live.sum { |process| process.dropped.sum { |_, count| count.to_i } }
        return nil if shed.zero?

        sent = live.sum(&:records)
        share = shed.to_f / (sent + shed)
        return nil if share < MIN_SHED_SHARE

        finding(Subject.new(kind: self.class.kind, app: app, work: kind, name: SHEDDING), score: 25 + 40 * scale(share, 0.2),
          title: "#{app}'s #{kind} agents are shedding telemetry",
          summary: "Live #{kind} processes have dropped #{Words.count(shed)} records since they started — " \
                   "#{Words.percent(share)} of what they collected.",
          figures: { "shed" => shed, "records" => sent, "share" => share })
      end
    end
  end
end
