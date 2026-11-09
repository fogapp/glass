# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # What the query engine does not express: paths through an app, as the
    # transitions between consecutive pageviews of a visit.
    class VisitorsController < BaseController
      MAX_EDGES = 60

      # GET /api/v1/visitors/journeys?from&to&app&filter
      sig { void }
      def journeys
        context = Query::Context.new(current_household!)
        from, to = range_param
        statement = Query::Statement.new
        where = Query::Where.new(source: Query::Sources::PAGE_EVENTS, context: context, statement: statement)
        conditions = where.sql(from: from, to: to, filter: "#{params[:filter]} kind:pageview")
        sql = <<~SQL.squish
          WITH steps AS (
            SELECT visit_id, route, lag(route) OVER (PARTITION BY visit_id ORDER BY ts) AS prev
            FROM page_events WHERE #{conditions}
          )
          SELECT prev AS from_route, route AS to_route, count(*)::int AS n
          FROM steps WHERE prev IS NOT NULL AND prev <> route
          GROUP BY 1, 2 ORDER BY 3 DESC LIMIT #{MAX_EDGES}
        SQL
        rows = Query::Runner.select(statement.to_sql(sql))
        render json: { edges: rows.map { |row| { from: row["from_route"], to: row["to_route"], count: row["n"].to_i } } }
      end
    end
  end
end
