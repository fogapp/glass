# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Fog::Sync do
  let(:household) { create_household }
  let(:client) { Fog::McpClient.new(base_url: "http://fog.test:8080", token: "mcp_x") }
  let(:now) { Time.now.utc }

  def rpc(result)
    { status: 200, body: { jsonrpc: "2.0", id: 1, result: { structuredContent: result } }.to_json, headers: { "Content-Type" => "application/json" } }
  end

  def stub_tools(apps:, detail: nil)
    stub_request(:post, "http://fog.test:8080/mcp").with { |request| JSON.parse(request.body).dig("params", "name") == "fog_apps_list" }
      .to_return(rpc({ "apps" => apps }))
    stub_request(:post, "http://fog.test:8080/mcp").with { |request| JSON.parse(request.body).dig("params", "name") == "fog_app_get" }
      .to_return(rpc(detail || { "deploys" => [] }))
  end

  it "creates apps from the roster, keeps vitals as metrics, and marks deploys once" do
    stub_tools(
      apps: [ { "name" => "hook", "state" => "running", "healthy" => true, "cpuPercent" => 3.5, "memUsage" => 200_000_000, "currentRev" => 7, "hosts" => [ "app.example.net" ] } ],
      detail: { "deploys" => [ { "rev" => 7, "status" => "succeeded", "actor" => "webhook", "startedAt" => (now - 600).iso8601, "finishedAt" => (now - 500).iso8601 },
                               { "rev" => 6, "status" => "failed", "actor" => "ui", "startedAt" => (now - 86_000).iso8601 } ] }
    )
    result = described_class.call(household: household, client: client, now: now)
    expect(result).to have_attributes(apps: 1, created: 1, points: 3, markers: 2)

    app = App.unscoped.find_by(household_id: household.id, slug: "hook")
    expect(app).to have_attributes(fog_name: "hook", name: "Hook")
    expect(app.fog_state).to include("rev" => 7, "healthy" => true)
    expect(Telemetry::MetricSeries.where(app_id: app.telemetry_id).pluck(:name)).to contain_exactly("fog.container.cpu_pct", "fog.container.memory_bytes", "fog.container.up")
    markers = Telemetry::Marker.where(app_id: app.telemetry_id).order(:ts)
    expect(markers.map(&:kind)).to eq(%w[incident deploy])
    expect(markers.last.title).to eq("Deploy #7 succeeded by webhook")

    # Same rev again: nothing new; a health flip: one marker.
    stub_tools(apps: [ { "name" => "hook", "healthy" => false, "currentRev" => 7 } ])
    again = described_class.call(household: household, client: client, now: now + 60)
    expect(again).to have_attributes(created: 0, markers: 1, points: 0)
    expect(Telemetry::Marker.where(app_id: app.telemetry_id).order(:ts).last.title).to eq("Health check failing")
  end

  it "keeps whether each app is up, and says nothing of one that is not meant to run" do
    stub_tools(apps: [
      { "name" => "minio", "state" => "running", "desiredState" => "running", "currentRev" => 1 },
      { "name" => "syncthing", "state" => "running", "desiredState" => "running", "healthy" => false, "currentRev" => 1 },
      { "name" => "paperless", "state" => "exited", "desiredState" => "running", "currentRev" => 1 },
      { "name" => "bazarr", "state" => "exited", "desiredState" => "stopped", "currentRev" => 1 },
      { "name" => "lidarr", "state" => "new", "desiredState" => "running", "currentRev" => 0 }
    ])
    described_class.call(household: household, client: client, now: now)

    up = Telemetry::MetricSeries.where(name: "fog.container.up").to_h do |series|
      [ series.tags["app"], Telemetry::MetricPoint.where(series_id: series.id).pick(:last) ]
    end
    expect(up).to eq("minio" => 1.0, "syncthing" => 0.0, "paperless" => 0.0)
  end

  it "leaves an app a person removed from Glass alone, until it is followed or added again" do
    AppSetting.current.ignore_fog_app!("minio")
    stub_tools(apps: [ { "name" => "minio", "state" => "running", "cpuPercent" => 1.0, "currentRev" => 1 }, { "name" => "hook", "state" => "running", "currentRev" => 1 } ])
    result = described_class.call(household: household, client: client, now: now)
    expect(result).to have_attributes(apps: 2, created: 1)
    expect(App.unscoped.where(household_id: household.id).pluck(:slug)).to eq([ "hook" ])
    expect(Telemetry::MetricSeries.where("tags->>'app' = ?", "minio")).to be_empty

    # Added again by hand under that name: fog's readings are its own again.
    added = create_app(household: household, slug: "minio")
    described_class.call(household: household, client: client, now: now + 60)
    expect(added.reload.fog_name).to eq("minio")
    added.destroy!

    AppSetting.current.follow_fog_apps!([ "minio" ])
    again = described_class.call(household: household, client: client, now: now + 120)
    expect(again.created).to eq(1)
  end

  it "matches an existing app by slug and surfaces fog's errors" do
    existing = create_app(household: household, slug: "hub")
    stub_tools(apps: [ { "name" => "hub", "currentRev" => 1 } ], detail: { "deploys" => [] })
    described_class.call(household: household, client: client, now: now)
    expect(existing.reload.fog_name).to eq("hub")

    stub_request(:post, "http://fog.test:8080/mcp").to_return(status: 401, body: "unrecognized token")
    expect { described_class.call(household: household, client: client, now: now) }.to raise_error(UpstreamHttpClient::Error, /credentials/)
  end
end
