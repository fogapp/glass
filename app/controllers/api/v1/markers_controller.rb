# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Deploys, restarts, incidents and events in a time range — what every
    # chart draws as vertical lines.
    class MarkersController < BaseController
      MAX = 500

      sig { void }
      def index
        context = Query::Context.new(current_household!)
        from, to = range_param

        kind = Telemetry::Marker::Kind.try_deserialize(params[:kind].to_s)
        markers = Markers.within(context, from: from, to: to, limit: MAX, app: params[:app].presence&.to_s,
          kinds: kind && [ kind.serialize ])

        render json: markers.map { |marker| MarkerSerializer.marker_json(marker, context) }
      end
    end
  end
end
