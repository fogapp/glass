# typed: strict
# frozen_string_literal: true

module Api
  module V1
    class DashboardsController < BaseController
      finds(:dashboard, Dashboard) { current_household!.dashboards }
      skip_before_action :set_dashboard, only: %i[index create]

      sig { void }
      def index
        render json: current_household!.dashboards.order(:position, :created_at).map { |d| DashboardSerializer.dashboard_json(d) }
      end

      sig { void }
      def show
        render json: DashboardSerializer.dashboard_json(dashboard)
      end

      sig { void }
      def create
        record = current_household!.dashboards.new(name: params[:name].to_s.strip, description: params[:description].presence&.to_s, widgets: widgets_param)
        record.save!
        render json: DashboardSerializer.dashboard_json(record), status: :created
      end

      sig { void }
      def update
        dashboard.name = params[:name].to_s.strip if params.key?(:name)
        dashboard.description = params[:description].presence&.to_s if params.key?(:description)
        dashboard.widgets = widgets_param if params.key?(:widgets)
        dashboard.save!
        render json: DashboardSerializer.dashboard_json(dashboard)
      end

      # Append one widget — what Explore's "pin" does.
      sig { void }
      def add_widget
        widget = Dashboard.widget_from(params[:widget])
        return render_errors("A widget needs a spec") if widget.nil?

        dashboard.widgets = dashboard.widgets + [ widget ]
        dashboard.save!
        render json: DashboardSerializer.dashboard_json(dashboard)
      end

      sig { void }
      def destroy
        dashboard.destroy!
        head :no_content
      end

      private

      sig { returns(T::Array[T::Hash[String, T.untyped]]) }
      def widgets_param
        raw = params[:widgets]
        return [] unless raw.is_a?(Array)

        raw.filter_map { |widget| Dashboard.widget_from(widget) }
      end
    end
  end
end
