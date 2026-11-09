# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class SlowEndpoints < Base
      # What the ranking reads, and the key each figure is answered under.
      COMPUTES = T.let({
        "count" => :count, "sum(duration)" => :total_ms, "avg(duration)" => :avg_ms, "p50(duration)" => :p50_ms,
        "p95(duration)" => :p95_ms, "p99(duration)" => :p99_ms, "error_rate" => :error_rate, "avg(db)" => :avg_db_ms,
        "avg(db_count)" => :avg_queries, "avg(view)" => :avg_view_ms, "avg(ext)" => :avg_external_ms
      }.freeze, T::Hash[String, Symbol])
      SORTS = T.let({
        "time" => "sum(duration)", "p95" => "p95(duration)", "p99" => "p99(duration)", "avg" => "avg(duration)",
        "errors" => "error_rate", "count" => "count"
      }.freeze, T::Hash[String, String])
      KINDS = Telemetry::Work::TIMED

      tool_name "slow_endpoints"
      title "Slow endpoints and jobs"
      description "Endpoints and jobs ranked by where the time goes: for each, how often it ran, the total time it " \
        "consumed, avg / p50 / p95 / p99 duration, its error rate, and how its average splits into database, view " \
        "and outbound-call time. `sort: \"time\"` (the default) ranks by total time consumed — the endpoints worth " \
        "fixing; `p95` and `p99` rank by tail latency (set `min_count` so one slow call does not top the list); " \
        "`errors` by error rate. Follow up with `query` (shape list, order \"-duration\") for the slowest individual " \
        "requests and `get_trace` on one of them."
      input_schema(
        properties: {
          app: { type: "string", description: "An app's slug. Omit for the whole fleet." },
          kind: { type: "string", enum: KINDS, description: "Only requests, or only jobs. Default both." },
          from: time_property("Start of the range. Default one hour before `to`."),
          to: time_property("End of the range. Default now."),
          filter: { type: "string", description: "Further filter terms over transactions, e.g. “release:abc1234” or “-path:/up”." },
          sort: { type: "string", enum: SORTS.keys, description: "What to rank by. Default time." },
          min_count: { type: "integer", description: "Leave out endpoints that ran fewer times than this. Default 1." },
          limit: { type: "integer", description: "1–100, default 20." }
        },
        required: []
      )
      annotations(title: "Slow endpoints and jobs", **READ_ONLY)

      # Ranked in SQL, thinned by min_count here: enough groups are read
      # that the thinning still leaves a full page.
      FETCH = 500

      sig { params(server_context: T.untyped, arguments: T.untyped).returns(MCP::Tool::Response) }
      def self.call(server_context:, **arguments)
        answer do
          context = query_context(server_context)
          from, to = TimeRange.resolve(from: arguments[:from], to: arguments[:to])
          kind = arguments[:kind].to_s.presence
          sort = choice(SORTS, arguments[:sort], default: "time", name: "sort by")
          rows = rows(context, source: "transactions", shape: "table", from: from, to: to,
            filter: filter_of(app_term(context, arguments[:app]), kind && "kind:#{kind}", arguments[:filter]),
            group_by: %w[app kind name], compute: COMPUTES.keys, order: "-#{sort}", limit: FETCH)
          least = [ arguments[:min_count].to_i, 1 ].max
          kept = rows.select { |row| row["count"].to_f >= least }.first(limit_of(arguments[:limit], default: 20, max: 100))
          { from: McpSerializer.time(from), to: McpSerializer.time(to), sorted_by: sort,
            endpoints: kept.map { |row| endpoint_json(row) } }
        end
      end

      sig { params(row: T::Hash[String, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
      def self.endpoint_json(row)
        { app: row["app"], kind: row["kind"], name: row["name"] }.merge(figures(COMPUTES, row))
      end
      private_class_method :endpoint_json
    end
  end
end
