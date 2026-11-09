# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class TopFunctions < Base
      ORDERS = T.let(Profiles::TopFunctions::Order.values.map(&:serialize).freeze, T::Array[String])

      tool_name "top_functions"
      title "Top functions in the profile"
      description "Where the code spends its time, from the continuous profiler: the functions with the most " \
        "sampled time for a filter and a range, each with its file and line. `self` time is the function itself on " \
        "top of the stack (where the samples landed); `total` includes everything it called. Narrow to one endpoint " \
        "or job with `transaction` (its exact name, as slow_endpoints gives it) and to on-CPU work with " \
        "`state: \"running\"` — without a state, time spent idle in I/O and stalled waiting for the GVL counts too. " \
        "To see what a deploy changed, call it twice with two ranges and compare."
      input_schema(
        properties: {
          app: { type: "string", description: "An app's slug. Omit for the whole fleet." },
          transaction: { type: "string", description: "An endpoint or job name, e.g. “WantsController#index”." },
          state: { type: "string", enum: Telemetry::ProfileSample::STATES, description: "Thread state. Default all states." },
          from: time_property("Start of the range. Default one hour before `to`."),
          to: time_property("End of the range. Default now."),
          filter: { type: "string", description: "Further terms over profile samples: process, host, release." },
          order: { type: "string", enum: ORDERS, description: "Rank by self or total time. Default self." },
          limit: { type: "integer", description: "1–100, default 25." }
        },
        required: []
      )
      annotations(title: "Top functions in the profile", **READ_ONLY)

      sig { params(server_context: T.untyped, arguments: T.untyped).returns(MCP::Tool::Response) }
      def self.call(server_context:, **arguments)
        answer do
          context = query_context(server_context)
          from, to = TimeRange.resolve(from: arguments[:from], to: arguments[:to], max: Profiles::Flamegraph::MAX_RANGE)

          state = arguments[:state].to_s.presence
          filter = filter_of(app_term(context, arguments[:app]), quoted_term("transaction", arguments[:transaction]),
            state && "state:#{state}", arguments[:filter])
          graph = Profiles::Flamegraph.new(
            context: context, range: Profiles::Flamegraph::Range.new(from: from, to: to, filter: filter)
          ).build
          order = Profiles::TopFunctions::Order.try_deserialize(arguments[:order].to_s) || Profiles::TopFunctions::Order::Self
          functions = Profiles::TopFunctions.rank(graph, limit: limit_of(arguments[:limit], default: 25, max: 100), order: order)

          samples = graph.fetch(:samples).first.to_i
          McpSerializer.numbers(
            from: McpSerializer.time(from), to: McpSerializer.time(to), filter: filter, total_ms: graph.fetch(:total_ms),
            samples: samples, note: samples.zero? ? NO_SAMPLES : nil, functions: functions
          ).compact
        end
      end

      NO_SAMPLES = "No profile samples match. Check that the app reports profiles at all (list_apps → " \
        "agent_settings.profiling), that the transaction name is exact (field_values on source profiles, " \
        "field transaction), and that the range is within profile retention."
    end
  end
end
