# typed: strict
# frozen_string_literal: true

module Fog
  # fog's MCP surface (fog's internal/mcpserver), called as plain JSON-RPC:
  # stateless streamable HTTP with JSON responses, a token minted in fog's
  # Settings › AI access. Read tools only. (Not FogClient: that name is the
  # vendored fog-client gem's, whose sign-in kit Glass also uses.)
  class McpClient
    extend T::Sig
    include UpstreamHttpClient
    include HouseholdUpstream

    sig { params(setting: AppSetting).returns(T.nilable(McpClient)) }
    def self.for(setting)
      url = setting.fog_url.presence
      token = setting.fog_token.presence
      return nil if url.nil? || token.nil?

      new(base_url: url, token: token)
    end

    sig { override.returns(String) }
    def service_name = "fog"

    # fogd on the host, reached at host.docker.internal from a container,
    # entered by the operator (HouseholdUpstream).
    sig { returns(Integer) }
    def read_timeout = 15

    # One tool, one answer: the tool's structured output as a Hash.
    sig { params(name: String, arguments: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
    def call_tool(name, arguments = {})
      response = http_post_json("#{base_url}/mcp",
        body: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } },
        headers: { "Accept" => "application/json, text/event-stream" })
      raise Error.new("fog answered #{response.status} to #{name}", status: response.status) unless response.status == 200

      envelope = JSON.parse(response.body.to_s)
      error = envelope["error"]
      raise Error.new("fog #{name}: #{error['message']}") if error.is_a?(Hash)

      result = envelope["result"] || {}
      raise Error.new("fog #{name}: #{tool_error_text(result)}") if result["isError"]

      structured = result["structuredContent"]
      return structured if structured.is_a?(Hash)

      text = Array(result["content"]).find { |item| item["type"] == "text" }&.fetch("text", nil)
      parsed = text ? JSON.parse(text) : {}
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError => e
      raise Error.new("fog #{name}: unreadable answer: #{e.message}")
    end

    sig { returns([ T::Boolean, String ]) }
    def test_connection
      apps = Array(call_tool("fog_apps_list")["apps"])
      [ true, "fog answered — #{apps.size} #{'app'.pluralize(apps.size)} managed" ]
    end

    private

    sig { params(result: T::Hash[String, T.untyped]).returns(String) }
    def tool_error_text(result)
      Array(result["content"]).filter_map { |item| item["text"] }.join(" ").truncate(200).presence || "tool error"
    end
  end
end
