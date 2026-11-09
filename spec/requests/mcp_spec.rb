# typed: false
# frozen_string_literal: true

require "rails_helper"

# Drives the MCP surface the way a real client does: initialize, tools/list,
# then tools/call. Stateless Streamable HTTP in JSON mode — every POST is
# self-contained, no session header.
RSpec.describe "MCP surface", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household, email: "agent-owner@example.com") }
  let(:full_token) { ApiToken.generate(user: user, name: "Claude").token }
  let(:read_token) { ApiToken.generate(user: user, name: "Claude (read)", scope: ApiToken::Scope::Read).token }
  let(:hook) { create_app(household: household, slug: "hook") }
  let(:now) { Time.now.utc }
  let(:trace) { SecureRandom.hex(16) }
  let(:span) { SecureRandom.hex(8) }

  def rpc_headers(token)
    bearer(token).merge("Content-Type" => "application/json", "Accept" => "application/json")
  end

  def rpc(method, params = {}, token: full_token, id: 1)
    post "/mcp", params: { jsonrpc: "2.0", id: id, method: method, params: params }.to_json, headers: rpc_headers(token)
  end

  # tools/call → the tool's result and its text.
  def call_tool(name, arguments = {}, token: full_token)
    rpc("tools/call", { name: name, arguments: arguments }, token: token)
    expect(response).to have_http_status(:ok)
    result = json.fetch("result")
    [ result, result.dig("content", 0, "text") ]
  end

  def tool_json(name, arguments = {}, token: full_token)
    result, text = call_tool(name, arguments, token: token)
    expect(result["isError"]).to be_falsey, "tool #{name} errored: #{text}"
    JSON.parse(text)
  end

  def tool_error(name, arguments = {})
    result, text = call_tool(name, arguments)
    expect(result["isError"]).to be(true), "tool #{name} answered: #{text}"
    text
  end

  def txn(name, dur, at: now - 60, **rest) = wire_txn(at: at, name: name, dur: dur, http: 200, **rest)

  # A small fleet: one app with a slow endpoint, a fast one, a failing job, a
  # kept trace with a span and a log line, a gauge, and a profile window.
  def report!
    write_batch(hook, [
      txn("Wants#index", 900.0, trace: trace, span: span, kept: true, db_ms: 700.0, db_n: 12),
      txn("Wants#index", 700.0),
      txn("Health#show", 2.0),
      txn("Health#show", 3.0),
      txn("SyncJob", 50.0, kind: "job", status: "error", error: "Timeout::Error", http: nil),
      wire_span(trace: trace, at: now - 59.9, parent: span, name: "Want Load", res: "SELECT ? FROM wants", dur: 650.0),
      wire_log("Started GET /wants", at: now - 59.5, trace: trace, span: span),
      wire_log("connection refused by indexer", at: now - 30, lvl: "error"),
      wire_metric("ruby.threads", at: now - 30, tags: { process: "web" }, sum: 9, last: 9),
      { t: "profile", ts: now.to_f - 120, dur: 60.0, hz: 100,
        funcs: [ [ "main", "app.rb", 1, "app" ], [ "serialize", "app/s.rb", 5, "app" ], [ "IO#read", "<cfunc>", 0, "native" ] ],
        stacks: [ [ 0, 1 ], [ 0, 1, 2 ], [ 0, 2 ] ],
        samples: [ [ 0, "Wants#index", "running", 60 ], [ 1, "Wants#index", "idle", 30 ], [ 2, nil, "running", 10 ] ] }
    ])
  end

  describe "authentication" do
    it "401s without a token, with a bearer challenge" do
      post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["WWW-Authenticate"]).to include("Bearer")
      expect(json["errors"]).to eq([ "unauthorized" ])
    end

    it "401s a session token, an unknown API token, an expired one and an ingest key" do
      session = ApiSession.generate!(user: user, device: "spec")
      expired = ApiToken.generate(user: user, name: "old", expires_at: 1.day.ago)
      [ session.token, "glass_nope", expired.token, ingest_key_for(hook).token ].each do |credential|
        rpc("tools/list", token: credential)
        expect(response).to have_http_status(:unauthorized)
      end
    end

    it "stamps the token on use" do
      token = ApiToken.generate(user: user, name: "x")
      rpc("tools/list", token: token.token)
      expect(token.record.reload.last_used_at).to be_present
    end
  end

  describe "the protocol handshake" do
    it "answers initialize with server identity and instructions" do
      rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "spec", version: "0" } })
      expect(response).to have_http_status(:ok)
      result = json.fetch("result")
      expect(result.dig("serverInfo", "name")).to eq("glass")
      expect(result["instructions"]).to include("whoami", "UTC")
      expect(result["capabilities"]).to have_key("tools")
    end

    # The 2026-07-28 lifecycle: no handshake, the version in a header and in
    # every request's _meta. A client on it asks for a notification stream.
    it "answers subscriptions/listen as unimplemented — there is no stream to hold open" do
      version = MCP::Configuration::LATEST_MODERN_PROTOCOL_VERSION
      meta = { "io.modelcontextprotocol/protocolVersion" => version, "io.modelcontextprotocol/clientCapabilities" => {} }
      post "/mcp",
        params: { jsonrpc: "2.0", id: 1, method: "subscriptions/listen",
                  params: { _meta: meta, notifications: { toolsListChanged: true } } }.to_json,
        headers: rpc_headers(full_token).merge("Accept" => "application/json, text/event-stream",
          "MCP-Protocol-Version" => version, "Mcp-Method" => "subscriptions/listen")
      expect(response).to have_http_status(:not_found)
      expect(json.dig("error", "code")).to eq(-32601)
    end

    it "405s GET instead of serving the SPA shell" do
      get "/mcp", headers: rpc_headers(full_token)
      expect(response).to have_http_status(:method_not_allowed)
    end
  end

  describe "tools/list" do
    let(:names) do
      %w[whoami list_apps describe_data query field_values slow_endpoints top_functions get_trace tail_logs
         list_incidents list_monitors list_markers list_processes model_usage get_session triage]
    end

    it "advertises every tool, in catalog order, each marked read-only with a described schema" do
      rpc("tools/list")
      tools = json.dig("result", "tools")
      expect(tools.map { |tool| tool["name"] }).to eq(names)
      tools.each do |tool|
        expect(tool.dig("annotations", "readOnlyHint")).to be(true), tool["name"]
        expect(tool["description"].length).to be > 60
        expect(tool.dig("inputSchema", "properties").values).to all(include("description")), tool["name"]
      end
    end

    it "shows a read-only token and a guest the same tools — they all only read" do
      rpc("tools/list", token: read_token)
      expect(json.dig("result", "tools").map { |tool| tool["name"] }).to eq(names)

      guest = create_user(household: household, role: "guest")
      rpc("tools/list", token: ApiToken.generate(user: guest, name: "guest").token)
      expect(json.dig("result", "tools").map { |tool| tool["name"] }).to eq(names)
    end
  end

  describe "whoami and list_apps" do
    it "says who the token acts for, what time it is, and which apps report" do
      report!
      write_batch(hook, [ txn("Health#show", 2.0, at: now - 5) ])
      me = tool_json("whoami", {}, token: read_token)
      expect(me["user"]).to eq("name" => "Test User", "role" => "member")
      expect(me["token"]).to eq("name" => "Claude (read)", "scope" => "read")
      expect(Time.iso8601(me["now"])).to be_within(60).of(now)
      expect(me["apps"]).to eq("all" => [ "hook" ], "reporting" => [ "hook" ])
      expect(me["processes"]).to eq("live" => 1, "total" => 1)
      expect(me["throughput_per_second"]).to be > 0
      expect(me["open_incidents"]).to eq(0)
    end

    it "lists apps with their health" do
      report!
      create_app(household: household, slug: "feed")
      apps = tool_json("list_apps")
      expect(apps.map { |app| app["slug"] }).to eq(%w[feed hook])
      expect(apps.last).to include("reporting" => true, "live_processes" => 1, "release" => "abc1234")
      expect(apps.first).to include("reporting" => false)
      expect(Time.iso8601(apps.last["last_seen_at"])).to be_within(60).of(now)
    end
  end

  describe "describe_data and field_values" do
    before { report! }

    it "describes the sources, one source, and the metrics" do
      catalog = tool_json("describe_data")
      expect(catalog["sources"].map { |source| source["name"] }).to eq(%w[transactions spans logs profiles page_events visits model_calls])
      expect(catalog["apps"]).to eq([ "hook" ])
      expect(catalog["metrics"]).to include("1 reported")
      duration = catalog["sources"].first["fields"].find { |field| field["name"] == "duration" }
      expect(duration).to eq("name" => "duration", "label" => "Duration", "type" => "number", "measure" => true, "unit" => "ms")

      logs = tool_json("describe_data", { source: "logs" })
      expect(logs["fields"].map { |field| field["name"] }).to include("level", "message")

      metrics = tool_json("describe_data", { source: "metrics", metric_prefix: "ruby." })
      expect(metrics["metrics"]).to eq([ { "name" => "ruby.threads", "kind" => "gauge", "series" => 1, "apps" => [ "hook" ], "tags" => [ "process" ] } ])
      expect(tool_json("describe_data", { metric_prefix: "nope." })["total"]).to eq(0)

      expect(tool_error("describe_data", { source: "nope" })).to include("Unknown source")
    end

    it "lists the values a field takes" do
      values = tool_json("field_values", { source: "transactions", field: "name" })
      expect(values["values"]).to eq([
        { "value" => "Health#show", "count" => 2.0 }, { "value" => "Wants#index", "count" => 2.0 }, { "value" => "SyncJob", "count" => 1.0 }
      ])
      narrowed = tool_json("field_values", { source: "transactions", field: "name", prefix: "want", filter: "kind:request" })
      expect(narrowed["values"].map { |row| row["value"] }).to eq([ "Wants#index" ])
      tags = tool_json("field_values", { source: "metrics", metric: "ruby.threads", field: "process" })
      expect(tags["values"]).to eq([ { "value" => "web", "count" => 1.0 } ])
    end
  end

  describe "query" do
    before { report! }

    it "answers a table by default, over the last hour, with ISO times" do
      result = tool_json("query", { source: "transactions", group_by: [ "name" ], compute: [ "count", "p95(duration)" ],
                                    filter: "app:hook kind:request", order: "-p95(duration)" })
      expect(result["shape"]).to eq("table")
      expect(result["rows"].map { |row| row["name"] }).to eq([ "Wants#index", "Health#show" ])
      expect(result["rows"].first).to include("count" => 2.0, "p95(duration)" => 890.0)
      expect(Time.iso8601(result["to"]) - Time.iso8601(result["from"])).to be_within(1).of(3600)
    end

    it "lists rows with readable times and without blanks, and pages back" do
      result = tool_json("query", { source: "transactions", shape: "list", from: "-10m", order: "-duration", limit: 2 })
      first = result["rows"].first
      expect(first).to include("app" => "hook", "name" => "Wants#index", "duration" => 900.0, "trace" => trace, "kept" => true)
      expect(first).not_to include("queue", "error", "n_plus_one")
      expect(Time.iso8601(first["ts"])).to be_within(1).of(now - 60)

      page = tool_json("query", { source: "logs", shape: "list", limit: 1 })
      expect(page["rows"].map { |row| row["message"] }).to eq([ "connection refused by indexer" ])
      older = tool_json("query", { source: "logs", shape: "list", limit: 1, before: page["next_before"] })
      expect(older["rows"].map { |row| row["message"] }).to eq([ "Started GET /wants" ])
    end

    it "draws a timeseries, a histogram, and a metric" do
      series = tool_json("query", { source: "transactions", shape: "timeseries", from: "-30m", step: 600, compute: [ "count" ] })
      expect(series["step_seconds"]).to eq(600)
      expect(series["times"].map { |at| Time.iso8601(at) }).to all(be_a(Time))
      expect(series["series"].first["values"].sum).to eq(5.0)

      histogram = tool_json("query", { source: "transactions", shape: "histogram", field: "duration" })
      expect(histogram["buckets"].sum { |bucket| bucket["count"] }).to eq(5.0)
      expect(histogram["buckets"].first).to include("from", "to")
      expect(histogram).not_to include("edges", "counts")

      metric = tool_json("query", { source: "metrics", metric: "ruby.threads", group_by: [ "process" ], compute: [ "avg" ] })
      expect(metric["rows"]).to eq([ { "process" => "web", "avg" => 9.0 } ])
    end

    it "takes explicit ISO and Unix bounds" do
      inside = tool_json("query", { source: "transactions", from: (now - 600).iso8601, to: now.to_f })
      expect(inside["rows"]).to eq([ { "count" => 5.0 } ])
      outside = tool_json("query", { source: "transactions", from: (now - 7200).iso8601, to: (now - 3600).iso8601 })
      expect(outside["rows"]).to eq([ { "count" => 0.0 } ])
    end

    it "hands back the compiler's sentence for a query it cannot read" do
      expect(tool_error("query", { source: "transactions", filter: "nmae:x" })).to include("did you mean “name”")
      expect(tool_error("query", { source: "transactions", from: "yesterday" })).to include("“from” is not a time")
      expect(tool_error("query", { source: "transactions", from: "-1h", to: "-2h" })).to include("ends before it starts")
      expect(tool_error("field_values", { source: "transactions", field: "name", from: "-900d" })).to include("wider than 800 days")
      expect(tool_error("query", { source: "metrics" })).to include("needs a metric name")
      expect(tool_error("query", { source: "transactions", shape: "pie" })).to be_present
      expect(tool_error("query", {})).to include("source")
    end
  end

  describe "slow_endpoints" do
    before { report! }

    it "ranks endpoints by time consumed, with the breakdown" do
      result = tool_json("slow_endpoints")
      expect(result["sorted_by"]).to eq("sum(duration)")
      expect(result["endpoints"].map { |row| row["name"] }).to eq([ "Wants#index", "SyncJob", "Health#show" ])
      expect(result["endpoints"].first).to include("app" => "hook", "kind" => "request", "count" => 2.0, "total_ms" => 1600.0,
        "avg_ms" => 800.0, "p95_ms" => 890.0, "error_rate" => 0.0, "avg_db_ms" => 350.0, "avg_queries" => 6.0)
    end

    it "narrows by app and kind, sorts by errors, and drops the rarely-run" do
      jobs = tool_json("slow_endpoints", { app: "hook", kind: "job" })
      expect(jobs["endpoints"].map { |row| row["name"] }).to eq([ "SyncJob" ])
      failing = tool_json("slow_endpoints", { sort: "errors", limit: 1 })
      expect(failing["endpoints"]).to match([ a_hash_including("name" => "SyncJob", "error_rate" => 1.0) ])
      errors = tool_json("query", { source: "transactions", filter: "status:error", group_by: [ "error" ] })
      expect(errors["rows"]).to eq([ { "error" => "Timeout::Error", "count" => 1.0 } ])
      busy = tool_json("slow_endpoints", { sort: "p95", min_count: 2 })
      expect(busy["endpoints"].map { |row| row["name"] }).to eq([ "Wants#index", "Health#show" ])
    end

    it "names the apps there are when asked about one there is not" do
      expect(tool_error("slow_endpoints", { app: "syncthing" })).to eq("No app “syncthing” — apps are hook")
    end
  end

  describe "triage" do
    before do
      write_batch(hook, Array.new(4) { |index| txn("SyncJob", 50.0, at: now - 60 - index, kind: "job", status: "error", error: "Timeout::Error", http: nil) })
    end

    it "lists what needs fixing over the last day, and answers one as a brief" do
      listed = tool_json("triage")
      expect(Time.iso8601(listed["to"]) - Time.iso8601(listed["from"])).to eq(1.day.to_i)
      finding = listed["findings"].find { |row| row["kind"] == "failing" }
      expect(finding).to include("app" => "hook", "severity" => "critical", "title" => "hook · SyncJob is failing")

      result, brief = call_tool("triage", { id: finding["id"] })
      expect(result["isError"]).to be_falsey
      expect(brief).to start_with("# hook · SyncJob is failing")
      expect(brief).to include("| Timeout::Error | 4 |", %(app:hook kind:job name:"SyncJob"))
    end

    it "leaves out what a person ignored, and says how many" do
      finding = tool_json("triage")["findings"].find { |row| row["kind"] == "failing" }
      TriageDismissal.create!(household: household, finding_id: finding["id"], mode: "ignored", score: 1, severity: "notice", title: "x")
      listed = tool_json("triage")
      expect(listed["findings"].map { |row| row["id"] }).not_to include(finding["id"])
      expect(listed["dismissed_or_ignored"]).to eq(1)
    end

    it "says what to do with an id it cannot read, or one that no longer stands out" do
      expect(tool_error("triage", { id: "nope!" })).to include("list findings without `id`")
      calm = Triage::Subject.new(kind: Triage::Kind::Failing, app: "hook", work: "request", name: "Health#show").id
      expect(tool_error("triage", { id: calm })).to include("no longer stands out")
      expect(tool_error("triage", { app: "syncthing" })).to eq("No app “syncthing” — apps are hook")
    end
  end

  describe "top_functions" do
    before { report! }

    it "ranks functions by self time, and by total" do
      result = tool_json("top_functions", { app: "hook" })
      expect(result).to include("total_ms" => 1000.0, "samples" => 100, "filter" => "app:hook")
      expect(result["functions"].map { |row| row["name"] }).to eq([ "serialize", "IO#read", "main" ])
      expect(result["functions"].first).to eq("name" => "serialize", "file" => "app/s.rb", "line" => 5, "category" => "app",
        "self_ms" => 600.0, "self_share" => 0.6, "total_ms" => 900.0, "total_share" => 0.9)

      by_total = tool_json("top_functions", { order: "total", limit: 1 })
      expect(by_total["functions"]).to match([ a_hash_including("name" => "main", "self_ms" => 0.0, "total_ms" => 1000.0) ])
    end

    it "narrows to an endpoint and a thread state" do
      result = tool_json("top_functions", { transaction: "Wants#index", state: "running" })
      expect(result["filter"]).to eq('transaction:"Wants#index" state:running')
      expect(result["total_ms"]).to eq(600.0)
      expect(result["functions"].map { |row| row["name"] }).to eq(%w[serialize main])
    end

    it "says what to check when nothing was sampled" do
      result = tool_json("top_functions", { transaction: "Nope#index" })
      expect(result).to include("samples" => 0, "functions" => [])
      expect(result["note"]).to include("No profile samples match")
    end
  end

  describe "get_trace" do
    before { report! }

    it "tells a trace as transactions, spans with offsets, and logs" do
      result = tool_json("get_trace", { trace_id: trace })
      expect(result).to include("trace" => trace, "duration_ms" => 900.0)
      expect(result["transactions"]).to match([ a_hash_including("app" => "hook", "name" => "Wants#index", "span" => span, "offset_ms" => 0.0, "db" => 700.0) ])
      expect(result["spans"]).to match([ a_hash_including("kind" => "sql", "resource" => "SELECT ? FROM wants", "parent" => span, "duration" => 650.0) ])
      expect(result["spans"].first["offset_ms"]).to be_within(1).of(100)
      expect(result["logs"]).to match([ a_hash_including("level" => "info", "message" => "Started GET /wants", "span" => span) ])
      expect(result).not_to include("note")
    end

    it "keeps the longest spans of a trace with too many" do
      write_batch(hook, (1..5).map { |n|
        wire_span(trace: trace, at: now - 59 + n, parent: span, name: "q#{n}", res: nil, dur: n.to_f)
      })
      result = tool_json("get_trace", { trace_id: trace.upcase, max_spans: 2 })
      expect(result["spans"].map { |row| row["duration"] }).to eq([ 650.0, 5.0 ])
      expect(result["note"]).to include("6 spans", "2 longest")
    end

    it "refuses what is not a trace id, and says when there is no such trace" do
      expect(tool_error("get_trace", { trace_id: "abc" })).to include("32 hex characters")
      expect(tool_error("get_trace", { trace_id: SecureRandom.hex(16) })).to include("No trace")
    end
  end

  describe "tail_logs" do
    before { report! }

    it "answers the newest lines first, narrowed by level and text" do
      all = tool_json("tail_logs", { app: "hook" })
      expect(all["rows"].map { |row| row["message"] }).to eq([ "connection refused by indexer", "Started GET /wants" ])
      expect(all["rows"].last).to include("level" => "info", "trace" => trace, "app" => "hook")
      expect(all).not_to include("shape")

      expect(tool_json("tail_logs", { min_level: "warn" })["rows"].map { |row| row["level"] }).to eq([ "error" ])
      expect(tool_json("tail_logs", { filter: '"GET /wants"' })["rows"].size).to eq(1)
      expect(tool_json("tail_logs", { from: "-20s" })["rows"]).to eq([])
    end
  end

  describe "monitors, incidents, markers and processes" do
    before do
      report!
      Current.household = household
      rule = household.monitors.create!(name: "hook is slow", kind: "threshold", comparison: "gt", threshold: 100, window_seconds: 300,
        for_seconds: 0, notify: false, query: { "source" => "transactions", "filter" => "app:hook", "compute" => "p95(duration)" })
      Monitors::Evaluator.call(rule, now: now)
      household.monitors.create!(name: "quiet", kind: "absence", window_seconds: 300, notify: false,
        query: { "source" => "transactions", "filter" => "app:feed" })
      Current.reset
    end

    it "lists monitors with their state, and incidents open first" do
      create_app(household: household, slug: "feed")
      monitors = tool_json("list_monitors")
      expect(monitors.map { |monitor| monitor["name"] }).to eq([ "hook is slow", "quiet" ])
      expect(monitors.first).to include("state" => "alert", "app" => "hook", "condition" => "p95(duration) > 100.0 over 5 min")
      expect(monitors.first["open_incident"]).to include("app" => "hook")
      expect(tool_json("list_monitors", { state: "alert" }).size).to eq(1)
      expect(tool_json("list_monitors", { app: "feed" }).map { |monitor| monitor["name"] }).to eq([ "quiet" ])

      incidents = tool_json("list_incidents", { open_only: true })
      expect(incidents).to match([ a_hash_including("monitor" => "hook is slow", "app" => "hook", "open" => true,
        "query" => a_hash_including("compute" => "p95(duration)")) ])
      expect(incidents.first["peak_value"]).to be > 100
      expect(tool_json("list_incidents", { app: "feed" })).to eq([])
      expect(tool_json("list_incidents", { since: "-1h" }).size).to eq(1)
      expect(Time.iso8601(incidents.first["opened_at"])).to be_within(5).of(now)
      expect(Time.iso8601(monitors.first["open_incident"]["opened_at"])).to be_within(5).of(now)
      expect(monitors.first["open_incident"]).not_to have_key("closed_at")
      expect(tool_error("list_monitors", { app: "nope" })).to include("No app “nope”")
      expect(tool_error("list_incidents", { app: "nope" })).to include("No app “nope”")
      expect(tool_json("whoami")["open_incidents"]).to eq(1)
    end

    it "lists markers and the reporting processes" do
      markers = tool_json("list_markers", { kind: "incident" })
      expect(markers["markers"]).to match([ a_hash_including("kind" => "incident", "title" => "hook is slow alerting", "app" => "hook") ])
      expect(Time.iso8601(markers["markers"].first["ts"])).to be_within(5).of(now)
      expect(tool_json("list_markers", { from: "-3h", to: "-2h" })["markers"]).to eq([])

      processes = tool_json("list_processes", { app: "hook", live_only: true })
      expect(processes).to match([ a_hash_including("app" => "hook", "kind" => "web", "host" => "spec-host", "release" => "abc1234", "live" => true) ])
      expect(processes.first).not_to include("id")
    end
  end

  describe "model_usage and get_session" do
    let(:aio) { create_app(household: household, slug: "aio") }

    def llm(at:, **fields) = wire_llm(at: at, session: "ses_1", **fields)

    before do
      write_batch(aio, [
        wire_run(at: now - 50.minutes, dur: 10_000, model_ms: 6000, tool_ms: 2000, tok_in: 100, tok_out: 200, cost: 0.02, ttft_ms: 9500),
        wire_run(at: now - 40.minutes, dur: 40_000, model_ms: 5000, wait_ms: 30_000, tok_in: 1000, tok_out: 300, cost: 0.08, stall_ms: 800),
        wire_run(at: now - 39.minutes, dur: 5_000, name: "compaction", trigger: "compaction", channel: nil, model_ms: 4900),
        wire_run(at: now - 30.minutes, dur: 9_000, session: "ses_2", cost: 0.5),
        llm(at: now - 50.minutes),
        llm(at: now - 40.minutes, in: 1000, cache_read: 0, cost: 0.03),
        llm(at: now - 40.minutes, provider: "local", model: "qwen3:8b", purpose: "reviewer", origin: "internal", cost: 0, cache_read: 0,
          status: "error", error: "timeout"),
        llm(at: now - 20.minutes, purpose: "judge", origin: "eval", cost: 9.0)
      ], kind: "gateway")
    end

    it "ranks model spend by model and purpose, leaving evals out unless asked" do
      usage = tool_json("model_usage", { app: "aio", from: "-2h" })
      expect(usage).to include("sorted_by" => "sum(cost)", "total_cost_usd" => 0.04)
      expect(usage["groups"]).to eq([
        { "model" => "claude-sonnet-4-6", "purpose" => "turn", "calls" => 2.0, "cost_usd" => 0.04, "input_tokens" => 1100.0,
          "cached_input_tokens" => 900.0, "output_tokens" => 400.0, "cache_hit_rate" => 0.45, "p50_ms" => 1000.0, "p95_ms" => 1000.0,
          "p95_ttft_ms" => 500.0, "output_tokens_per_second" => 400.0, "error_rate" => 0.0 },
        { "model" => "qwen3:8b", "purpose" => "reviewer", "calls" => 1.0, "cost_usd" => 0.0, "input_tokens" => 100.0,
          "cached_input_tokens" => 0.0, "output_tokens" => 200.0, "cache_hit_rate" => 0.0, "p50_ms" => 1000.0, "p95_ms" => 1000.0,
          "p95_ttft_ms" => 500.0, "output_tokens_per_second" => 400.0, "error_rate" => 1.0 }
      ])

      with_evals = tool_json("model_usage", { app: "aio", from: "-2h", include_evals: true, group_by: [ "origin" ], sort: "calls" })
      expect(with_evals["groups"].map { |group| [ group["origin"], group["calls"] ] }).to eq([ [ "production", 2.0 ], [ "eval", 1.0 ], [ "internal", 1.0 ] ])
      expect(tool_error("model_usage", { sort: "vibes" })).to include("not one of")
    end

    it "tells a conversation as its runs, oldest first, with where the time and the money went" do
      session = tool_json("get_session", { session: "ses_1", from: "-2h" })
      expect(session).to include("session" => "ses_1", "app" => "aio")
      expect(session["totals"]).to eq("runs" => 3.0, "cost_usd" => 0.1, "input_tokens" => 1100.0, "output_tokens" => 500.0,
        "active_ms" => 25_000.0, "waiting_on_a_person_ms" => 30_000.0)
      expect(session["runs"].map { |run| [ run["name"], run["trigger"], run["duration"], run["active"] ] }).to eq([
        [ "owner-chat", "message", 10_000.0, 10_000.0 ], [ "owner-chat", "message", 40_000.0, 10_000.0 ], [ "compaction", "compaction", 5000.0, 5000.0 ]
      ])
      expect(session["runs"].first).to include("channel" => "telegram", "stop" => "ok", "model_ms" => 6000.0, "tool_ms" => 2000.0,
        "ttft" => 9500.0, "cost" => 0.02, "trace" => match(/\A[0-9a-f]{32}\z/))
      expect(Time.iso8601(session["first_at"])).to be_within(2).of(now - 50.minutes)

      expect(tool_error("get_session", { session: "ses_nope" })).to include("No runs under session “ses_nope”")
    end
  end

  describe "the household boundary" do
    it "never shows another household's telemetry or configuration" do
      report!
      other = create_household(name: "Next door")
      stranger = ApiToken.generate(user: create_user(household: other), name: "theirs").token

      expect(tool_json("whoami", {}, token: stranger)["apps"]).to eq("all" => [], "reporting" => [])
      expect(tool_json("list_apps", {}, token: stranger)).to eq([])
      expect(tool_json("query", { source: "transactions" }, token: stranger)["rows"]).to eq([ { "count" => 0.0 } ])
      expect(tool_json("tail_logs", {}, token: stranger)["rows"]).to eq([])
      expect(tool_json("list_processes", {}, token: stranger)).to eq([])
      expect(call_tool("get_trace", { trace_id: trace }, token: stranger).last).to include("No trace")
      expect(call_tool("slow_endpoints", { app: "hook" }, token: stranger).last).to eq("No app “hook” — no apps report yet")
    end
  end

  describe "the record" do
    it "writes one activity row per tool call, naming the tool, its arguments and the token" do
      expect { tool_json("query", { source: "logs", shape: "list" }) }.to change(ActivityEntry, :count).by(1)
      entry = ActivityEntry.recent.first
      expect(entry).to have_attributes(source: "mcp", event: "mcp.tool_call", summary: "Agent called query", household_id: household.id)
      expect(entry.payload).to include("tool" => "query", "token" => "Claude", "arguments" => { "source" => "logs", "shape" => "list" })
      expect { rpc("tools/list") }.not_to change(ActivityEntry, :count)
    end

    it "answers an unknown tool with a protocol error, not a crash" do
      rpc("tools/call", { name: "drop_everything", arguments: {} })
      expect(response).to have_http_status(:ok)
      expect(json.dig("error", "message")).to be_present
    end
  end
end
