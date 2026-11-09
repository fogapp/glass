# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class ListApps < Base
      tool_name "list_apps"
      title "The apps that report"
      description "Every app in the fleet: its slug (what `app:` takes in a filter), whether it is reporting, from " \
        "how many live processes, the release it is on, what fog says about it, and the agent settings it runs under."
      input_schema(properties: {}, required: [])
      annotations(title: "The apps that report", **READ_ONLY)

      sig { params(server_context: T.untyped, _extra: T.untyped).returns(MCP::Tool::Response) }
      def self.call(server_context:, **_extra)
        apps = context_household(server_context).apps.order(:name).to_a
        health = AppHealth.for(apps)
        json_response(apps.map { |app| McpSerializer.app_json(app, health: health[app.telemetry_id]) })
      end
    end
  end
end
