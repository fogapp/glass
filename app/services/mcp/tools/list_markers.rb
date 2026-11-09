# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class ListMarkers < Base
      KINDS = T.let(Telemetry::Marker::Kind.values.map(&:serialize).freeze, T::Array[String])

      tool_name "list_markers"
      title "Deploys, restarts and events"
      description "What changed, and when: deploys (with the release and outcome), restarts, health transitions, " \
        "incidents and annotations in a range, newest first — the vertical lines on every chart. The first thing " \
        "to check when something got slower or started failing: did a deploy land just before?"
      input_schema(
        properties: {
          app: { type: "string", description: "An app's slug. Omit for every app and fleet-wide markers." },
          kind: { type: "string", enum: KINDS, description: "Only markers of this kind." },
          from: time_property("Start of the range. Default one day before `to`."),
          to: time_property("End of the range. Default now."),
          limit: { type: "integer", description: "1–500, default 50." }
        },
        required: []
      )
      annotations(title: "Deploys, restarts and events", **READ_ONLY)

      sig { params(server_context: T.untyped, arguments: T.untyped).returns(MCP::Tool::Response) }
      def self.call(server_context:, **arguments)
        answer do
          context = query_context(server_context)
          from, to = TimeRange.resolve(from: arguments[:from], to: arguments[:to], default: 1.day)
          kind = Telemetry::Marker::Kind.try_deserialize(arguments[:kind].to_s)
          markers = Markers.within(context, from: from, to: to, limit: limit_of(arguments[:limit], default: 50, max: 500),
            app: app_slug(context, arguments[:app]), kinds: kind && [ kind.serialize ])
          { from: McpSerializer.time(from), to: McpSerializer.time(to),
            markers: markers.map { |marker| McpSerializer.marker_json(marker, context) } }
        end
      end
    end
  end
end
