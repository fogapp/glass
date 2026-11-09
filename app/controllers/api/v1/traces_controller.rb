# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # One trace, whole: every transaction that carried the id (a request and
    # the jobs it enqueued, across apps) and the spans kept for them.
    class TracesController < BaseController
      sig { void }
      def show
        id = Traces::Lookup.normalize(params.require(:trace_id))
        return render_errors("A trace id is 32 hex characters", status: :bad_request) if id.nil?

        context = Query::Context.new(current_household!)
        found = Traces::Lookup.call(id: id, context: context)
        return render_not_found if found.nil?

        render json: TraceSerializer.trace_json(found, context)
      end
    end
  end
end
