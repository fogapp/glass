# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    # The Explorer, for an agent: the same Query::Request the console posts
    # to /api/v1/query, compiled by the same engine.
    class RunQuery < Base
      SOURCES = T.let((Query::Sources::ALL.map(&:name) + [ "metrics" ]).freeze, T::Array[String])
      SHAPES = T.let(Query::Request::Shape.values.map(&:serialize).freeze, T::Array[String])
      # A list row is a whole request or log line; fifty of them is already
      # a long read.
      DEFAULT_LIST_LIMIT = 50

      tool_name "query"
      title "Run an Explorer query"
      description <<~TEXT.squish
        Ask the telemetry anything: aggregate or list requests, jobs and agent runs (transactions), spans, logs,
        profile samples, visitor events (page_events), visits, model calls (model_calls), or a named metric. `shape` decides the answer: `table` is one row per
        group (a top list); `timeseries` is each group over time; `list` is the raw rows, newest first; `histogram`
        and `heatmap` bucket one numeric `field`. `compute` takes count, rate, errors, error_rate, apdex(ms),
        uniq(field), ratio(a, b) — one total over another, e.g. ratio(cache_read, input_total) — and
        sum/avg/min/max/p50/p75/p90/p95/p99 of a measure — e.g. ["count","p95(duration)"].
        `filter` is the query bar's language: space-separated terms, ANDed — `app:hook status:error
        duration:>250ms http_status:5xx -path:/up route:/api/v1/* name:"WantsController#index" "free text"`;
        commas mean any-of, `*` is a wildcard, `key:*` means present, `@key` reads a row's free-form attributes.
        For `source: "metrics"` give `metric` (see describe_data); filters and group_by then name its tags, and
        compute is one of sum, avg, min, max, last, count, rate, p50…p99. Example — the slowest endpoints of hook
        in the last day: source transactions, shape table, from "-1d", filter "app:hook kind:request",
        group_by ["name"], compute ["count","p95(duration)"], order "-p95(duration)". And what an agent harness
        spent on models by why it called them: source model_calls, from "-1d", group_by ["purpose","model"],
        compute ["sum(cost)","count","p95(ttft)"].
      TEXT
      input_schema(
        properties: {
          source: { type: "string", enum: SOURCES, description: "What to read." },
          shape: { type: "string", enum: SHAPES, description: "The answer's shape. Default table." },
          from: time_property("Start of the range: ISO 8601 (UTC), or relative like “-1h”, “-7d”. Default one hour before `to`."),
          to: time_property("End of the range. Default now."),
          filter: { type: "string", description: "Filter terms, ANDed. Default none: everything in range." },
          compute: { type: "array", items: { type: "string" }, description: "What to compute. Default [\"count\"]." },
          group_by: { type: "array", items: { type: "string" }, description: "Up to 3 fields (or @attributes) to group by." },
          order: { type: "string", description: "table: a compute or group key, “-” prefix for descending (default: first compute, descending). list: a numeric field to rank by, e.g. “-duration” for the slowest rows." },
          limit: { type: "integer", description: "Rows or groups, 1–500. Default: table 50, timeseries 10 groups, list 50." },
          step: { type: "integer", description: "timeseries/heatmap bucket width in seconds. Default: chosen for about 180 points — pass a wider step (300, 3600) for a shorter answer." },
          metric: { type: "string", description: "The metric name, for source “metrics”." },
          field: { type: "string", description: "The numeric field a histogram or heatmap buckets. Default duration." },
          before: time_property("list: only rows older than this — pass the previous answer's next_before to page back.")
        },
        required: %w[source]
      )
      annotations(title: "Run an Explorer query", **READ_ONLY)

      sig { params(server_context: T.untyped, source: T.untyped, arguments: T.untyped).returns(MCP::Tool::Response) }
      def self.call(server_context:, source:, **arguments)
        answer do
          from, to = TimeRange.resolve(from: arguments[:from], to: arguments[:to])
          shape = arguments[:shape].presence || "table"
          result = ask(query_context(server_context), source: source.to_s, shape: shape.to_s, from: from, to: to,
            filter: arguments[:filter].to_s, compute: arguments[:compute], group_by: arguments[:group_by],
            order: arguments[:order], step: arguments[:step], metric: arguments[:metric],
            field: arguments[:field], limit: arguments[:limit] || (shape.to_s == "list" ? DEFAULT_LIST_LIMIT : nil),
            before: TimeRange.optional(arguments[:before], "before")&.to_f)
          McpSerializer.query_json(result)
        end
      end
    end
  end
end
