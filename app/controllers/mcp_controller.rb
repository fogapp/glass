# typed: strict
# frozen_string_literal: true

# The MCP surface: "why was hook slow at 3 am?" can be asked
# of an agent and answered from the data. Deliberately outside the console
# auth stack: the credential is an ApiToken (revocable per agent), never an
# ApiSession. A fresh MCP::Server is assembled per request; transport is
# stateless Streamable HTTP in JSON mode, so nothing survives a request and
# fog's overlapping blue-green replicas need no session affinity.
class McpController < ActionController::API
  extend T::Sig

  include BearerToken
  include ErrorEnvelope

  SERVER_VERSION = "1.0.0"

  INSTRUCTIONS = <<~TEXT
    Glass is this household's observability console: metrics, traces,
    profiles, logs and visitor analytics for every app the home fleet runs.
    These tools read it; nothing here changes anything.

    Call `whoami` first: it gives the server's clock and the apps that
    report. Every time is UTC. A time argument is ISO 8601
    (2026-09-30T03:00:00Z) or relative to now ("-15m", "-2h", "-7d"); when
    the person names a local time, convert it, and say which zone you
    assumed.

    To answer "why was X slow (or failing) at T": `list_markers` around T
    for a deploy or restart; `slow_endpoints` for where the time went;
    `query` to break it down (by release, route, status, over time) and to
    list the slowest requests; `get_trace` on one of them for its spans and
    logs; `top_functions` for the code responsible; `tail_logs` and
    `list_incidents` for what was said at the time. `describe_data` lists
    the fields and metrics `query` can name, `field_values` the exact
    values a field takes.

    Answers leave out fields that are empty or false. Durations are
    milliseconds unless a unit says otherwise; rates and shares are 0–1.
    When a tool says a query could not be read, the message says what to
    change — fix it and ask again.
  TEXT

  before_action :set_trace_id
  before_action :authenticate!
  after_action :reset_current

  sig { void }
  def handle
    server = MCP::Server.new(
      name: "glass", title: "Glass", version: SERVER_VERSION, instructions: INSTRUCTIONS,
      tools: Mcp::Toolbox.for(current_token),
      server_context: { user: Current.user, household: Current.household, token: current_token },
      configuration: mcp_configuration
    )
    transport = MCP::Server::Transports::StreamableHTTPTransport.new(
      server, stateless: true, enable_json_response: true,
      # Nothing here outlives a request, so there is no stream to hold open:
      # subscriptions/listen is answered as unimplemented, and not advertised.
      serve_subscriptions_listen: false,
      # Bearer auth already gates every request; fog's proxy owns Host routing.
      dns_rebinding_protection: false
    )
    status, headers, body = transport.handle_request(request)
    headers&.each { |key, value| response.set_header(key, value) }

    payload = body.respond_to?(:first) ? body.first : nil
    if payload.present?
      render json: payload, status: status
    else
      head status
    end
  end

  private

  sig { void }
  def set_trace_id
    Current.trace_id = request.request_id
  end

  sig { void }
  def authenticate!
    token = ApiToken.authenticate(bearer_token)
    if token.nil?
      response.set_header("WWW-Authenticate", 'Bearer realm="Glass MCP"')
      return render_errors("unauthorized", status: :unauthorized)
    end

    token.record_use!
    @token = T.let(token, T.nilable(ApiToken))
    user = T.cast(token.user, User)
    Current.user = user
    Current.household = user.household
    Current.api_token = token
  end

  sig { returns(ApiToken) }
  def current_token = T.must(@token)

  # What an agent asked is part of the operational record: each tool call is
  # one Activity row naming the tool and its arguments, and a tool that
  # raised is an error row (and reaches the error tracker through it).
  sig { returns(MCP::Configuration) }
  def mcp_configuration
    configuration = MCP::Configuration.new
    configuration.exception_reporter = ->(exception, _context) do
      Activity.record(source: "mcp", event: "mcp.error", severity: Activity::Severity::Error, exception: exception,
        summary: "MCP request failed: #{exception.class}: #{exception.message.to_s.truncate(200)}")
    end
    configuration.around_request = ->(data, &request_handler) do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
      result = request_handler.call
      if data[:method] == "tools/call"
        Activity.record(source: "mcp", event: "mcp.tool_call",
          summary: "Agent called #{data[:tool_name] || 'unknown tool'}",
          payload: { tool: data[:tool_name], arguments: data[:tool_arguments], token: current_token.name }.compact,
          duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f - started) * 1000).round)
      end
      result
    end
    configuration
  end

  sig { void }
  def reset_current
    Current.reset
  end
end
