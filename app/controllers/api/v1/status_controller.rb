# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # The console's status line: is telemetry arriving, from how many
    # processes, how fast, and how full is the disk budget. Polled every few
    # seconds, so everything here is one cheap query or a cached figure.
    class StatusController < BaseController
      STORAGE_TTL = T.let(60.seconds, ActiveSupport::Duration)

      sig { void }
      def show
        context = Query::Context.new(current_household!)
        ids = context.app_ids
        now = Time.now.utc
        pulse = FleetPulse.for(context, now: now)
        processes = pulse.processes
        setting = AppSetting.cached

        render json: {
          now: now.to_f,
          apps: { total: ids.size, reporting: processes.reporting.size },
          processes: { live: processes.live, total: processes.total },
          last_seen_at: processes.last_seen_at&.to_f,
          # Requests and jobs a second over the last minute, fleet-wide.
          throughput: pulse.throughput,
          storage: { used_bytes: storage_bytes, budget_bytes: setting.disk_budget_mb.megabytes },
          release: GlassVersion.short_sha
        }
      end

      private

      # pg_total_relation_size over every partition is cheap but not free;
      # the answer moves slowly, so it is asked once a minute per process.
      sig { returns(Integer) }
      def storage_bytes
        Rails.cache.fetch("status:telemetry_bytes", expires_in: STORAGE_TTL) { Telemetry::Partitions.total_bytes }
      end
    end
  end
end
