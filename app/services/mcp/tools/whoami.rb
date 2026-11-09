# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class Whoami < Base
      tool_name "whoami"
      title "Who am I acting for"
      description "Who this token belongs to, the server's clock (every time Glass gives or takes is UTC), the apps " \
        "that report, and whether telemetry is arriving right now. Call this first."
      input_schema(properties: {}, required: [])
      annotations(title: "Who am I acting for", **READ_ONLY)

      sig { params(server_context: T.untyped, _extra: T.untyped).returns(MCP::Tool::Response) }
      def self.call(server_context:, **_extra)
        user = context_user(server_context)
        household = context_household(server_context)
        token = T.cast(server_context[:token], ApiToken)
        context = query_context(server_context)
        now = Time.now.utc
        pulse = FleetPulse.for(context, now: now)
        processes = pulse.processes

        json_response(
          user: { name: user.name, role: user.role },
          household: household.name,
          token: { name: token.name, scope: token.scope },
          now: McpSerializer.time(now),
          apps: { all: context.slugs, reporting: processes.reporting.filter_map { |id| context.slug(id) }.sort },
          processes: { live: processes.live, total: processes.total },
          last_report_at: McpSerializer.time(processes.last_seen_at),
          # Requests and jobs a second over the last minute, fleet-wide.
          throughput_per_second: McpSerializer.number(pulse.throughput),
          open_incidents: household.incidents.open.count,
          glass_release: GlassVersion.short_sha
        )
      end
    end
  end
end
