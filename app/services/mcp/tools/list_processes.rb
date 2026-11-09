# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class ListProcesses < Base
      MAX = 200

      tool_name "list_processes"
      title "The reporting processes"
      description "Every process that reports — web workers, job workers — most recently heard from first: its " \
        "app, kind, host, release, runtime versions, when it started and last reported, whether it is live, and " \
        "what its agent has dropped. Shows a release that is only half rolled out, a process that went quiet, and " \
        "an agent shedding data under load."
      input_schema(
        properties: {
          app: { type: "string", description: "An app's slug. Omit for the whole fleet." },
          live_only: { type: "boolean", description: "Only processes reporting right now. Default false." }
        },
        required: []
      )
      annotations(title: "The reporting processes", **READ_ONLY)

      sig { params(server_context: T.untyped, app: T.untyped, live_only: T.untyped, _extra: T.untyped).returns(MCP::Tool::Response) }
      def self.call(server_context:, app: nil, live_only: nil, **_extra)
        answer do
          context = query_context(server_context)
          slug = app_slug(context, app)
          ids = slug ? [ context.app_id(slug) ] : context.app_ids
          scope = Telemetry::AgentProcess.where(app_id: ids).order(last_seen_at: :desc).limit(MAX)
          scope = scope.live if live_only == true
          scope.map { |process| McpSerializer.process_json(process, context) }
        end
      end
    end
  end
end
