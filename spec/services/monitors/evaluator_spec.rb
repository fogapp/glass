# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Monitors::Evaluator do
  let(:household) { create_household }
  let(:hook) { create_app(household: household, slug: "hook") }
  let(:now) { Time.now.utc }

  def txn(dur, at: now - 60) = wire_txn(at: at, dur: dur)

  def monitor(**overrides)
    household.monitors.create!({ name: "slow", kind: "threshold", query: { "source" => "transactions", "filter" => "app:hook", "compute" => "p95(duration)" },
                                comparison: "gt", threshold: 100, window_seconds: 300, for_seconds: 0, notify: false }.merge(overrides))
  end

  before { Current.household = household }

  it "alerts, opens an incident, writes a marker, and recovers" do
    write_batch(hook, [ txn(500), txn(600) ])
    rule = monitor
    described_class.call(rule, now: now)
    expect(rule.reload).to have_attributes(state: "alert", last_value: be_within(1).of(595))
    incident = rule.open_incident
    expect(incident).to have_attributes(app_slug: "hook", peak_value: be_within(1).of(595))
    expect(Telemetry::Marker.where(kind: "incident").pluck(:title)).to eq([ "slow alerting" ])

    write_batch(hook, [ txn(10, at: now + 200), txn(20, at: now + 210) ])
    described_class.call(rule, now: now + 400)
    expect(rule.reload.state).to eq("ok")
    expect(incident.reload.closed_at).to be_present
    expect(Telemetry::Marker.where(kind: "incident").count).to eq(2)
  end

  it "tells fog's event stream when an incident opens and closes, under one key" do
    stub_const("ENV", ENV.to_h.merge("FOG_API_URL" => "http://fog.test", "FOG_API_TOKEN" => "apptok", "GLASS_HOST" => "glass.example.test"))
    posted = []
    stub_request(:post, "http://fog.test/app/v1/events")
      .with(headers: { "Authorization" => "Bearer apptok" })
      .to_return { |request| posted << JSON.parse(request.body) && { status: 202, body: '{"accepted":1,"new":1}' } }

    write_batch(hook, [ txn(500), txn(600) ])
    rule = monitor
    described_class.call(rule, now: now)
    write_batch(hook, [ txn(10, at: now + 200), txn(20, at: now + 210) ])
    described_class.call(rule, now: now + 400)

    expect(posted.pluck("type")).to eq(%w[glass.incident.opened glass.incident.closed])
    opened, closed = posted
    expect(opened["data"]).to include("key" => closed["data"]["key"], "title" => "Glass: slow", "app" => "hook",
      "notify" => false, "link" => "https://glass.example.test/monitors/#{rule.id}")
    expect(opened["id"]).not_to eq(closed["id"])
    expect(closed["data"]["title"]).to eq("Glass: slow recovered")
  end

  it "keeps evaluating when fog's event stream is down" do
    stub_const("ENV", ENV.to_h.merge("FOG_API_URL" => "http://fog.test", "FOG_API_TOKEN" => "apptok"))
    stub_request(:post, "http://fog.test/app/v1/events").to_return(status: 503)
    write_batch(hook, [ txn(500) ])
    rule = monitor
    described_class.call(rule, now: now)
    expect(rule.reload.state).to eq("alert")
    expect(ActivityEntry.where(event: "event.failed")).to exist
  end

  it "holds the alert until the condition has lasted long enough" do
    write_batch(hook, [ txn(500) ])
    rule = monitor(for_seconds: 120)
    described_class.call(rule, now: now)
    expect(rule.reload).to have_attributes(state: "ok", pending_since: be_present)
    described_class.call(rule, now: now + 130)
    expect(rule.reload.state).to eq("alert")
  end

  it "stays quiet inside the deploy grace" do
    write_batch(hook, [ txn(500) ], release: "aaa", pid: 1)
    write_batch(hook, [ txn(500) ], release: "bbb", pid: 2)
    rule = monitor(deploy_grace_seconds: 600)
    described_class.call(rule, now: now)
    expect(rule.reload.state).to eq("ok")
  end

  it "names its app once, from the context it is given, without asking the database" do
    write_batch(hook, [ txn(500), txn(600) ])
    rule = monitor(deploy_grace_seconds: 600)
    context = Query::Context.new(household)
    allow(rule).to receive(:app_slug).and_call_original

    queries = count_queries(matching: /FROM "apps"/) { described_class.call(rule, now: now, context: context) }

    expect(queries).to be_empty
    expect(rule).to have_received(:app_slug).once
    expect(rule.reload.state).to eq("alert")
    expect(rule.open_incident.app_slug).to eq("hook")
    expect(Telemetry::Marker.where(kind: "incident").pluck(:app_id)).to eq([ hook.telemetry_id ])
  end

  it "reports no data, and an absence as an alert" do
    rule = monitor
    described_class.call(rule, now: now)
    expect(rule.reload.state).to eq("no_data")

    absence = monitor(kind: "absence", name: "silent")
    described_class.call(absence, now: now)
    expect(absence.reload.state).to eq("alert")
    write_batch(hook, [ txn(5, at: now + 10) ])
    described_class.call(absence, now: now + 20)
    expect(absence.reload.state).to eq("ok")
  end

  it "records a query it cannot run instead of raising" do
    rule = monitor(query: { "source" => "transactions", "filter" => "nope:1" })
    described_class.call(rule, now: now)
    expect(rule.reload.last_error).to include("no field")
    expect(rule.state).to eq("no_data")
  end

  it "closes the open incident when its query stops compiling, so the next alert opens only one" do
    write_batch(hook, [ txn(500), txn(600) ])
    rule = monitor
    described_class.call(rule, now: now)
    incident = rule.reload.open_incident
    expect(incident).to be_present

    rule.update!(query: rule.query.merge("filter" => "nope:1"))
    described_class.call(rule, now: now + 30)
    expect(rule.reload).to have_attributes(state: "no_data", pending_since: nil)
    expect(incident.reload.closed_at).to be_present

    rule.update!(query: rule.query.merge("filter" => "app:hook"))
    described_class.call(rule, now: now + 60)
    expect(rule.reload.state).to eq("alert")
    expect(Incident.where(monitor: rule, closed_at: nil).count).to eq(1)
  end
end
