# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Every stretch a monitor was alerting, newest first, open ones first.
    class IncidentsController < BaseController
      sig { void }
      def index
        scope = current_household!.incidents.includes(:monitor).order(Arel.sql("closed_at IS NOT NULL, opened_at DESC"))
        render json: paginate(scope, default_per: 50).map { |incident|
          rule = T.must(incident.monitor)
          MonitorSerializer.incident_json(incident).merge(monitor: rule.name, condition: rule.condition_text)
        }
      end
    end
  end
end
