import { describe, expect, it } from "vitest";
import { API_TOKEN_SCOPES, MCP_TOOLS } from "@/types";
import {
  API_TOKEN_SCOPE_HINTS,
  API_TOKEN_SCOPE_LABELS,
  MCP_TOOL_SUMMARIES,
  claudeCodeAddCommand,
  claudeCodeProjectConfig,
  mcpConfigSnippet,
  mcpUrl,
} from "./tokens";

describe("tokens", () => {
  it("labels and explains every scope", () => {
    for (const scope of API_TOKEN_SCOPES) {
      expect(API_TOKEN_SCOPE_LABELS[scope]).toBeTruthy();
      expect(API_TOKEN_SCOPE_HINTS[scope]).toBeTruthy();
    }
  });

  it("derives the MCP endpoint from the origin without doubling slashes", () => {
    expect(mcpUrl("https://glass.example.net")).toBe("https://glass.example.net/mcp");
    expect(mcpUrl("https://glass.example.net/")).toBe("https://glass.example.net/mcp");
  });

  it("renders a client config carrying the bearer token", () => {
    const parsed = JSON.parse(mcpConfigSnippet("https://glass.example.net", "glass_abc")) as {
      glass: { url: string; headers: { Authorization: string } };
    };
    expect(parsed.glass.url).toBe("https://glass.example.net/mcp");
    expect(parsed.glass.headers.Authorization).toBe("Bearer glass_abc");
  });

  it("builds a user-scoped Claude Code command over HTTP with the bearer header", () => {
    expect(claudeCodeAddCommand("https://glass.example.net/", "glass_abc")).toBe(
      'claude mcp add --transport http --scope user glass https://glass.example.net/mcp --header "Authorization: Bearer glass_abc"',
    );
  });

  it("keeps the token out of a project .mcp.json by referencing the environment", () => {
    const parsed = JSON.parse(claudeCodeProjectConfig("https://glass.example.net")) as {
      mcpServers: { glass: { type: string; url: string; headers: { Authorization: string } } };
    };
    expect(parsed.mcpServers.glass).toEqual({
      type: "http",
      url: "https://glass.example.net/mcp",
      headers: { Authorization: "Bearer ${GLASS_TOKEN}" },
    });
  });

  it("describes every tool in the toolbox, and nothing else", () => {
    expect(Object.keys(MCP_TOOL_SUMMARIES)).toEqual([...MCP_TOOLS]);
    for (const tool of MCP_TOOLS) expect(MCP_TOOL_SUMMARIES[tool].length).toBeGreaterThan(20);
  });
});
