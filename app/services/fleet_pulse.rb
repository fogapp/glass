# typed: strict
# frozen_string_literal: true

# Whether telemetry is arriving right now: the household's agent processes
# and its requests and jobs a second over the last minute. The console's
# status line polls it every few seconds and whoami answers it, so it is
# read under the query engine's statement timeout like any other read.
class FleetPulse < T::Struct
  extend T::Sig

  RATE_WINDOW = T.let(60.seconds, ActiveSupport::Duration)

  const :processes, Telemetry::AgentProcess::Summary
  # Requests and jobs a second over RATE_WINDOW, fleet-wide.
  const :throughput, Float

  sig { params(context: Query::Context, now: Time).returns(FleetPulse) }
  def self.for(context, now: Time.now.utc)
    ids = context.app_ids
    Query::Runner.timed(slow: "the fleet's status is taking too long to read") do
      weight = Telemetry::Transaction.where(app_id: ids, ts: (now - RATE_WINDOW)..).sum(:weight).to_f
      new(processes: Telemetry::AgentProcess.summary(ids), throughput: weight / RATE_WINDOW.to_f)
    end
  end
end
