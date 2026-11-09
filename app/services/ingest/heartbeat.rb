# typed: strict
# frozen_string_literal: true

module Ingest
  # Every batch is its process's heartbeat: upsert the `processes` row, and
  # — because a process reporting a release this app has never reported
  # before *is* a deploy seen from the inside — write the deploy marker.
  # That gives every chart its deploy lines with no help from fog;
  # fog's own, exact deploy events replace the inference
  # when they are available.
  module Heartbeat
    extend T::Sig

    sig { params(app: App, header: Batch::Header, records: Integer, now: Time).void }
    def self.beat!(app, header, records:, now:)
      inserted = upsert(app, header, records: records, now: now)
      mark_deploy(app, header, now: now) if inserted
    end

    # True when this is the first batch from this process.
    sig { params(app: App, header: Batch::Header, records: Integer, now: Time).returns(T::Boolean) }
    def self.upsert(app, header, records:, now:)
      result = Telemetry::AgentProcess.upsert( # rubocop:disable Rails/SkipsModelValidations
        {
          app_id: app.telemetry_id, kind: header.kind, host: header.host, pid: header.pid,
          release: header.release, runtime: header.runtime, started_at: header.started_at,
          first_seen_at: now, last_seen_at: now, batches: 1, records: records, dropped: header.dropped
        },
        unique_by: %i[app_id host pid kind],
        on_duplicate: Arel.sql(<<~SQL.squish),
          release = EXCLUDED.release, runtime = EXCLUDED.runtime,
          started_at = COALESCE(EXCLUDED.started_at, processes.started_at),
          last_seen_at = EXCLUDED.last_seen_at,
          batches = processes.batches + 1, records = processes.records + EXCLUDED.records,
          dropped = EXCLUDED.dropped
        SQL
        returning: Arel.sql("(xmax = 0) AS inserted")
      )
      result.rows.dig(0, 0) == true
    end
    private_class_method :upsert

    # A release this app has not reported before, on an app that has
    # reported before: a deploy. The very first process of an app is not one.
    #
    # Runs inside the batch's transaction, under a lock per app held until it
    # commits: when web and worker report a new release at the same moment,
    # the second waits, then sees the first's process row and writes nothing.
    sig { params(app: App, header: Batch::Header, now: Time).void }
    def self.mark_deploy(app, header, now:)
      release = header.release
      return if release.blank?

      TelemetryRecord.connection.select_value(
        TelemetryRecord.sanitize_sql([ "SELECT pg_advisory_xact_lock(hashtext('glass.deploy'), ?)", app.telemetry_id ])
      )
      others = Telemetry::AgentProcess.where(app_id: app.telemetry_id)
        .where.not(host: header.host, pid: header.pid, kind: header.kind)
      return unless others.exists?
      return if others.exists?(release: release)

      Telemetry::Marker.insert!({ # rubocop:disable Rails/SkipsModelValidations
        ts: header.started_at || now, app_id: app.telemetry_id, kind: Telemetry::Marker::Kind::Deploy.serialize,
        title: "Deployed #{release.first(12)}", release: release, source: "agent", attrs: {}
      })
    end
    private_class_method :mark_deploy
  end
end
