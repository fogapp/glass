# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class ListIncidents < Base
      tool_name "list_incidents"
      title "Recent incidents"
      description "Every stretch a monitor was alerting — open ones first, then newest first: which monitor, its " \
        "condition and the query it watches, the app, when it opened and closed, and the worst value seen. The " \
        "monitor's query is one you can run yourself with `query` over the incident's window to see what happened."
      input_schema(
        properties: {
          open_only: { type: "boolean", description: "Only incidents still open. Default false." },
          app: { type: "string", description: "Only incidents filed under this app's slug." },
          since: time_property("Only incidents opened at or after this. Default: no bound."),
          limit: { type: "integer", description: "1–100, default 20." }
        },
        required: []
      )
      annotations(title: "Recent incidents", **READ_ONLY)

      sig { params(server_context: T.untyped, arguments: T.untyped).returns(MCP::Tool::Response) }
      def self.call(server_context:, **arguments)
        answer do
          scope = context_household(server_context).incidents.includes(:monitor)
            .order(Arel.sql("closed_at IS NOT NULL, opened_at DESC"))
          scope = scope.open if arguments[:open_only] == true
          if (app = app_slug(query_context(server_context), arguments[:app]))
            scope = scope.where(app_slug: app)
          end
          if (since = TimeRange.optional(arguments[:since], "since"))
            scope = scope.where(opened_at: since..)
          end
          scope.limit(limit_of(arguments[:limit], default: 20, max: 100)).map { |incident| McpSerializer.incident_json(incident) }
        end
      end
    end
  end
end
