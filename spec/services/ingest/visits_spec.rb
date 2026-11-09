# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ingest::Visits do
  let(:household) { create_household }
  let(:reporting_app) { create_app(household: household) }
  let(:now) { Time.now.utc.change(usec: 0) }

  def event(visit_id, ts, kind = "pageview", **fields)
    { ts: ts, app_id: reporting_app.telemetry_id, kind: kind, visit_id: visit_id, visitor_id: "vis-#{visit_id}", user_ref: nil,
      path: nil, route: nil, referrer: nil, browser: "Firefox", os: "Linux", device: "desktop", origin: "lan" }.merge(fields)
  end

  def visit(visit_id)
    Telemetry::Visit.where(app_id: reporting_app.telemetry_id, visit_id: visit_id).order(:ts).to_a
  end

  it "folds several visits in one batch into their own rows, continuing the ones already begun" do
    # One begun an hour ago, one begun too long ago to continue, one new.
    described_class.fold!(reporting_app, [
      event("a", now - 1.hour, path: "/a1", route: "/a/:id", referrer: "portal.example.net"),
      event("a", now - 50.minutes, "click"),
      event("old", (now.to_date - 2).to_time(:utc) + 60, path: "/old")
    ])

    described_class.fold!(reporting_app, [
      event("b", now - 2.minutes, path: "/b1", route: "/b", browser: "Safari"),
      event("a", now - 1.minute, path: "/a2", user_ref: "u_1"),
      event("b", now - 1.minute, "error"),
      event("old", now, path: "/new"),
      event("b", now - 30.seconds, path: "/b2", referrer: "reader.example.net"),
      event("a", now - 30.seconds, "custom")
    ])

    a = visit("a")
    expect(a.size).to eq(1)
    expect(a.first).to have_attributes(ts: now - 1.hour, last_seen_at: now - 30.seconds, user_ref: "u_1",
      entry_path: "/a1", entry_route: "/a/:id", exit_path: "/a2", referrer: "portal.example.net", pageviews: 2, interactions: 2, error_count: 0)

    b = visit("b")
    expect(b.size).to eq(1)
    expect(b.first).to have_attributes(ts: now - 2.minutes, last_seen_at: now - 30.seconds, entry_path: "/b1", entry_route: "/b",
      exit_path: "/b2", referrer: "reader.example.net", browser: "Safari", pageviews: 2, interactions: 0, error_count: 1)

    old = visit("old")
    expect(old.map(&:entry_path)).to eq(%w[/old /new])
    expect(old.last).to have_attributes(ts: now, pageviews: 1)
  end

  it "reads and writes visits once per batch, however many it mentions" do
    described_class.fold!(reporting_app, (1..5).map { |i| event("v#{i}", now - 10.minutes, path: "/") })
    queries = count_queries(matching: /visits/) do
      described_class.fold!(reporting_app, (1..10).map { |i| event("v#{i}", now - 1.minute, path: "/x") })
    end
    expect(queries.size).to eq(2)
    expect(Telemetry::Visit.where(app_id: reporting_app.telemetry_id).sum(:pageviews)).to eq(15)
  end
end
