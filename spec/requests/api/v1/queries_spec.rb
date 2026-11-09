# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Telemetry reads", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household, role: "guest") }
  let(:reporting_app) { create_app(household: household) }
  let(:now) { Time.now.utc }
  let(:trace) { SecureRandom.hex(16) }
  let(:span) { SecureRandom.hex(8) }

  before do
    write_batch(reporting_app, [
      wire_txn(at: now - 30, trace: trace, span: span, dur: 12.0, http: 200, kept: true),
      wire_span(trace: trace, at: now - 29.99, parent: span),
      wire_log("Completed 200", at: now - 29.9, trace: trace, span: span),
      wire_metric("ruby.threads", at: now - 30, tags: { process: "web" }, sum: 9, last: 9)
    ])
  end

  it "runs one query, and a batch, even for a guest" do
    post "/api/v1/query", params: { source: "transactions", shape: "table", from: now.to_f - 3600, to: now.to_f, compute: [ "count" ] }.to_json,
      headers: auth_headers(user).merge("Content-Type" => "application/json")
    expect(response).to have_http_status(:ok)
    expect(json["rows"]).to eq([ { "count" => 1.0 } ])

    post "/api/v1/query", params: { queries: [
      { source: "transactions", shape: "list", from: now.to_f - 3600, to: now.to_f },
      { source: "transactions", shape: "table", from: now.to_f - 3600, to: now.to_f, filter: "nope:1" }
    ] }.to_json, headers: auth_headers(user).merge("Content-Type" => "application/json")
    expect(response).to have_http_status(:ok)
    expect(json["results"][0]["rows"].first["name"]).to eq("A#index")
    expect(json["results"][1]["errors"].first).to include("no field")
  end

  it "answers 422 with the reason for a query it cannot compile" do
    post "/api/v1/query", params: { source: "transactions", shape: "table", from: now.to_f, to: now.to_f - 1 }.to_json,
      headers: auth_headers(user).merge("Content-Type" => "application/json")
    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"].first).to include("ends before")
  end

  it "describes the catalog and lists values" do
    get "/api/v1/query/sources", headers: auth_headers(user)
    expect(json["sources"].map { |s| s["name"] }).to include("transactions", "logs", "profiles")
    expect(json["apps"]).to eq([ "hook" ])
    expect(json["metrics"].first).to include("name" => "ruby.threads", "kind" => "gauge", "tags" => [ "process" ], "apps" => [ "hook" ])

    get "/api/v1/query/values", params: { source: "transactions", key: "name", from: now.to_f - 3600, to: now.to_f }, headers: auth_headers(user)
    expect(json).to eq([ { "value" => "A#index", "count" => 1.0 } ])
    get "/api/v1/query/values", params: { source: "metrics", metric: "ruby.threads", key: "process" }, headers: auth_headers(user)
    expect(json).to eq([ { "value" => "web", "count" => 1.0 } ])
  end

  it "shows a trace whole and its markers, and reports the fleet" do
    get "/api/v1/traces/#{trace}", headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    expect(json["transactions"].first).to include("name" => "A#index", "span" => span, "app" => "hook")
    expect(json["spans"].first).to include("kind" => "sql", "parent" => span)

    get "/api/v1/traces/#{SecureRandom.hex(16)}", headers: auth_headers(user)
    expect(response).to have_http_status(:not_found)

    get "/api/v1/fleet", headers: auth_headers(user)
    expect(json.first).to include("app" => "hook", "kind" => "web", "live" => true)

    get "/api/v1/status", headers: auth_headers(user)
    expect(json["apps"]).to eq("total" => 1, "reporting" => 1)

    get "/api/v1/markers", params: { from: now.to_f - 3600, to: now.to_f }, headers: auth_headers(user)
    expect(json).to eq([])
  end

  it "builds a flamegraph" do
    write_batch(reporting_app, [ { t: "profile", ts: now.to_f - 60, dur: 60.0, hz: 100, funcs: [ [ "main", "app.rb", 1, "app" ] ], stacks: [ [ 0 ] ],
                        samples: [ [ 0, "A#index", "running", 10 ] ] } ])
    post "/api/v1/profiles/flamegraph", params: { from: now.to_f - 3600, to: now.to_f, filter: "app:hook" }.to_json,
      headers: auth_headers(user).merge("Content-Type" => "application/json")
    expect(response).to have_http_status(:ok)
    expect(json["total_ms"]).to eq(100.0)
    expect(json["functions"].map { |f| f["name"] }).to include("main")
  end

  it "reads every range one way: garbage, backwards or too wide is a 422 that says so, never 1970" do
    get "/api/v1/markers", params: { from: "yesterday" }, headers: auth_headers(user)
    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"].first).to include("“from” is not a time")

    get "/api/v1/visitors/journeys", params: { from: 0, to: now.to_f }, headers: auth_headers(user)
    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"].first).to include("“from” is not a time")

    get "/api/v1/visitors/journeys", params: { from: (now - 801.days).to_f, to: now.to_f }, headers: auth_headers(user)
    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"].first).to include("wider than 800 days")

    get "/api/v1/query/values", params: { source: "transactions", key: "name", from: now.to_f, to: now.to_f - 60 }, headers: auth_headers(user)
    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"].first).to include("ends before it starts")

    post "/api/v1/profiles/flamegraph", params: { from: now.to_f - 3600 }.to_json,
      headers: auth_headers(user).merge("Content-Type" => "application/json")
    expect(json["errors"].first).to include("“to” is required")

    # What the console sends (Unix seconds), ISO and relative times all read.
    get "/api/v1/visitors/journeys", params: { from: "-1h", to: now.iso8601 }, headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    get "/api/v1/markers", headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
  end
end
