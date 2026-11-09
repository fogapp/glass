# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    # What an agent harness spent on models, and how they behaved: the
    # Models page of the console, for an agent.
    class ModelUsage < Base
      # What the ranking reads, and the key each figure is answered under.
      COMPUTES = T.let({
        "count" => :calls, "sum(cost)" => :cost_usd, "sum(tokens_in)" => :input_tokens,
        "sum(cache_read)" => :cached_input_tokens, "sum(tokens_out)" => :output_tokens,
        "ratio(cache_read, input_total)" => :cache_hit_rate, "p50(duration)" => :p50_ms, "p95(duration)" => :p95_ms,
        "p95(ttft)" => :p95_ttft_ms, "avg(tokens_per_s)" => :output_tokens_per_second, "error_rate" => :error_rate
      }.freeze, T::Hash[String, Symbol])
      SORTS = T.let({
        "cost" => "sum(cost)", "calls" => "count", "p95" => "p95(duration)", "ttft" => "p95(ttft)", "errors" => "error_rate",
        "tokens" => "sum(tokens_in)"
      }.freeze, T::Hash[String, String])
      GROUPS = T.let(%w[provider model served purpose origin agent session stop error route tier].freeze, T::Array[String])

      tool_name "model_usage"
      title "Model spend and latency"
      description "What agent harnesses spent on models and how the models behaved: for each group, the number of " \
        "calls, cost in USD, input / cached-input / output tokens, the cache hit rate (cached input over all input), " \
        "p50 / p95 duration, p95 time to first token, output tokens per second and the error rate. Grouped by model " \
        "and purpose by default — `purpose` is why a call was made (turn, reviewer, title, compaction, judge …), which " \
        "is how hidden overhead shows; group by `agent`, `session`, `error` or `stop` to cut it differently. Calls " \
        "from evals are left out unless `include_evals` is true. Every call is counted (none is sampled). Follow up " \
        "with `query` on source model_calls for a timeseries (e.g. the cache hit rate over time around a deploy), or " \
        "with shape list for the individual calls, each of which carries the `trace` of the run it was made under."
      input_schema(
        properties: {
          app: { type: "string", description: "An app's slug. Omit for every app that reports model calls." },
          from: time_property("Start of the range. Default one day before `to`."),
          to: time_property("End of the range. Default now."),
          group_by: { type: "array", items: { type: "string", enum: GROUPS }, description: "Up to 3 fields. Default [\"model\", \"purpose\"]." },
          filter: { type: "string", description: "Further filter terms over model_calls, e.g. “purpose:turn” or “status:error”." },
          sort: { type: "string", enum: SORTS.keys, description: "What to rank by. Default cost." },
          include_evals: { type: "boolean", description: "Count calls made by evals too. Default false." },
          limit: { type: "integer", description: "1–100, default 30." }
        },
        required: []
      )
      annotations(title: "Model spend and latency", **READ_ONLY)

      sig { params(server_context: T.untyped, arguments: T.untyped).returns(MCP::Tool::Response) }
      def self.call(server_context:, **arguments)
        answer do
          context = query_context(server_context)
          from, to = TimeRange.resolve(from: arguments[:from], to: arguments[:to], default: 1.day)
          sort = choice(SORTS, arguments[:sort], default: "cost", name: "sort by")
          groups = Array(arguments[:group_by]).map(&:to_s).presence || %w[model purpose]
          rows = rows(context, source: "model_calls", shape: "table", from: from, to: to,
            filter: filter_of(app_term(context, arguments[:app]), arguments[:include_evals] == true ? nil : "-origin:eval",
              arguments[:filter]),
            group_by: groups, compute: COMPUTES.keys, order: "-#{sort}", limit: limit_of(arguments[:limit], default: 30, max: 100))
          total = rows.sum { |row| row["sum(cost)"].to_f }
          { from: McpSerializer.time(from), to: McpSerializer.time(to), sorted_by: sort, total_cost_usd: McpSerializer.number(total),
            groups: rows.map { |row| group_json(row, groups) } }
        end
      end

      sig { params(row: T::Hash[String, T.untyped], groups: T::Array[String]).returns(T::Hash[Symbol, T.untyped]) }
      def self.group_json(row, groups)
        McpSerializer.compact(groups.to_h { |name| [ name.to_sym, row[name] ] }.merge(figures(COMPUTES, row)))
      end
      private_class_method :group_json
    end
  end
end
