import type { ApiTokenScope, McpTool } from "@/types";

export const API_TOKEN_SCOPE_LABELS: Record<ApiTokenScope, string> = {
  full: "Full",
  read: "Read-only",
};

export const API_TOKEN_SCOPE_HINTS: Record<ApiTokenScope, string> = {
  full: "Everything you can do in the console — for your own tools.",
  read: "May look at everything and change nothing — for an agent, a script, a wall display.",
};

/**
 * What each MCP tool is for, one line each. Keyed by the generated tool
 * names (app/services/mcp/toolbox.rb), so a tool added there without a line
 * here does not compile.
 */
export const MCP_TOOL_SUMMARIES: Record<McpTool, string> = {
  whoami: "Who the token acts for, the server's clock, and which apps are reporting.",
  list_apps: "Every app: reporting or not, live processes, release, agent settings.",
  describe_data: "The sources, fields, functions and metrics a query can name.",
  query: "Any Explorer query: tables, timeseries, raw rows, histograms, metrics.",
  field_values: "The values a field takes — the exact name of an endpoint, a release.",
  slow_endpoints: "Endpoints and jobs ranked by time consumed, tail latency or errors.",
  top_functions: "Where the code spends its time, from the profiler, for any filter.",
  get_trace: "One trace whole: the request, its spans, and the logs written during it.",
  tail_logs: "The newest log lines, by app, level and text.",
  list_incidents: "Every stretch a monitor was alerting, open ones first.",
  list_monitors: "What is being watched, and each monitor's state right now.",
  list_markers: "Deploys, restarts and events in a range — what changed, and when.",
  list_processes: "Every reporting process: release, heartbeat, what its agent dropped.",
  model_usage: "What agent harnesses spent on models, by model and purpose, and how the models behaved.",
  get_session: "One conversation with an agent, as its runs in order: where the time and the money went.",
  triage: "What needs fixing across the fleet, worst first — and any finding as a brief to act on.",
};

/** The MCP endpoint for this deployment. */
export function mcpUrl(origin: string): string {
  return `${origin.replace(/\/+$/, "")}/mcp`;
}

/** A generic MCP client entry: paste into any client that takes a URL + headers. */
export function mcpConfigSnippet(origin: string, token: string): string {
  return JSON.stringify(
    {
      glass: {
        url: mcpUrl(origin),
        headers: { Authorization: `Bearer ${token}` },
      },
    },
    null,
    2,
  );
}

/**
 * The one-liner that registers Glass with Claude Code for every project
 * (`--scope user`). Tokens are hex after the `glass_` prefix, so the header
 * needs no escaping beyond its double quotes.
 */
export function claudeCodeAddCommand(origin: string, token: string): string {
  return `claude mcp add --transport http --scope user glass ${mcpUrl(origin)} --header "Authorization: Bearer ${token}"`;
}

/**
 * A project-scoped `.mcp.json` for a repository. Claude Code expands
 * `${GLASS_TOKEN}` from the environment, so the token never lands in git.
 */
export function claudeCodeProjectConfig(origin: string): string {
  return JSON.stringify(
    {
      mcpServers: {
        glass: {
          type: "http",
          url: mcpUrl(origin),
          headers: { Authorization: "Bearer ${GLASS_TOKEN}" },
        },
      },
    },
    null,
    2,
  );
}
