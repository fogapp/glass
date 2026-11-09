# typed: strict
# frozen_string_literal: true

module Api
  module V1
    class MonitorsController < BaseController
      finds(:monitor, MonitorRule) { current_household!.monitors }
      skip_before_action :set_monitor, only: %i[index create]

      sig { void }
      def index
        monitors = current_household!.monitors.order(:name).includes(:open_incidents)
        render json: monitors.map { |monitor| MonitorSerializer.monitor_json(monitor) }
      end

      sig { void }
      def show
        render json: MonitorSerializer.monitor_json(monitor, incidents: monitor.incidents.order(opened_at: :desc).limit(50).to_a)
      end

      sig { void }
      def create
        record = current_household!.monitors.new(monitor_params)
        record.save!
        render json: MonitorSerializer.monitor_json(record), status: :created
      end

      sig { void }
      def update
        monitor.update!(monitor_params)
        render json: MonitorSerializer.monitor_json(monitor)
      end

      # Evaluate right now — the form's "Test".
      sig { void }
      def evaluate
        Monitors::Evaluator.call(monitor)
        render json: MonitorSerializer.monitor_json(monitor.reload)
      end

      sig { void }
      def destroy
        monitor.destroy!
        head :no_content
      end

      private

      sig { returns(T::Hash[T.any(String, Symbol), T.untyped]) }
      def monitor_params
        permitted = params.permit(:name, :description, :enabled, :kind, :comparison, :threshold, :window_seconds, :for_seconds,
          :deploy_grace_seconds, :notify, query: %i[source filter compute metric]).to_h.to_h
        permitted["query"] = permitted["query"].to_h.transform_values(&:to_s) if permitted.key?("query")
        permitted
      end
    end
  end
end
