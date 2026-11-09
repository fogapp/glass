# typed: strict
# frozen_string_literal: true

module ProcessSerializer
  extend T::Sig

  sig { params(process: Telemetry::AgentProcess, context: Query::Context).returns(T::Hash[Symbol, T.untyped]) }
  def self.process_json(process, context)
    {
      id: process.id, app: context.slug(process.app_id), kind: process.kind, host: process.host, pid: process.pid,
      release: process.release, runtime: process.runtime, started_at: process.started_at&.to_f,
      first_seen_at: process.first_seen_at.to_f, last_seen_at: process.last_seen_at.to_f, live: process.live?,
      batches: process.batches, records: process.records, dropped: process.dropped
    }
  end
end
