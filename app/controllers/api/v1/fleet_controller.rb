# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Every reporting process: release, versions, heartbeat, and what its
    # agent says it has shed.
    class FleetController < BaseController
      sig { void }
      def index
        context = Query::Context.new(current_household!)
        processes = Telemetry::AgentProcess.where(app_id: context.app_ids).order(last_seen_at: :desc).limit(500)
        render json: processes.map { |process| ProcessSerializer.process_json(process, context) }
      end
    end
  end
end
