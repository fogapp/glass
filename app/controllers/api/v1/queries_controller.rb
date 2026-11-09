# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # The one read path over telemetry: every chart, table
    # and list in the console is a query posted here.
    class QueriesController < BaseController
      # Running a query is a read that happens to be a POST (the query is
      # the body), so read-only tokens and guests may.
      allow_read_scope :run
      skip_before_action :deny_guest_writes, only: :run

      # POST /api/v1/query — one query, or several under `queries` answered
      # in order (a dashboard asks for all its widgets in one round trip;
      # each answer is either a result or `{ errors: [...] }`).
      sig { void }
      def run
        context = Query::Context.new(current_household!)
        many = params[:queries]
        unless many.is_a?(Array)
          return render json: Query::Runner.run(Query::Request.from_params(query_params(params)), context)
        end
        return render_errors("At most #{MAX_BATCH} queries at once") if many.size > MAX_BATCH

        render json: { results: many.map { |query| answer(query, context) } }
      end

      MAX_BATCH = 24

      sig { void }
      def sources
        render json: Query::Catalog.describe(Query::Context.new(current_household!))
      end

      sig { void }
      def values
        from, to = range_param
        render json: Query::Catalog.values(
          context: Query::Context.new(current_household!), source: params.require(:source).to_s,
          key: params.require(:key).to_s, from: from, to: to, filter: params[:filter].to_s,
          prefix: params[:q].presence&.to_s, metric: params[:metric].presence&.to_s
        )
      end

      private

      sig { params(query: T.untyped, context: Query::Context).returns(T::Hash[Symbol, T.untyped]) }
      def answer(query, context)
        return { errors: [ "A query must be an object" ] } unless query.respond_to?(:to_unsafe_h)

        Query::Runner.run(Query::Request.from_params(query_params(query)), context)
      rescue Query::Invalid => e
        { errors: [ e.message ] }
      end

      # The query document as plain data. It is never mass-assigned to a
      # record — Query::Request reads each key it knows and ignores the rest.
      sig { params(source: T.untyped).returns(T::Hash[String, T.untyped]) }
      def query_params(source)
        source.to_unsafe_h.slice("source", "shape", "from", "to", "filter", "compute", "group_by", "step",
          "limit", "order", "metric", "field", "before")
      end
    end
  end
end
