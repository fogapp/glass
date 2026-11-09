# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class ListMonitors < Base
      STATES = T.let(MonitorRule::State.values.map(&:serialize).freeze, T::Array[String])

      tool_name "list_monitors"
      title "Monitors and their state"
      description "What Glass is watching: each monitor's condition, the query behind it, its state right now " \
        "(ok, alert, no_data), the last value it saw and when, and its open incident if it has one."
      input_schema(
        properties: {
          state: { type: "string", enum: STATES, description: "Only monitors in this state." },
          app: { type: "string", description: "Only monitors whose filter names this app." }
        },
        required: []
      )
      annotations(title: "Monitors and their state", **READ_ONLY)

      sig { params(server_context: T.untyped, state: T.untyped, app: T.untyped, _extra: T.untyped).returns(MCP::Tool::Response) }
      def self.call(server_context:, state: nil, app: nil, **_extra)
        answer do
          slug = app_slug(query_context(server_context), app)
          scope = context_household(server_context).monitors.order(:name).includes(:open_incidents)
          if (wanted = MonitorRule::State.try_deserialize(state.to_s))
            scope = scope.where(state: wanted.serialize)
          end
          monitors = scope.to_a
          monitors = monitors.select { |monitor| monitor.app_slug == slug } if slug
          monitors.map { |monitor| McpSerializer.monitor_json(monitor) }
        end
      end
    end
  end
end
