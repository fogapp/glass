# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Markers do
  let(:household) { create_household }
  let(:hook) { create_app(household: household, slug: "hook") }
  let(:hub) { create_app(household: household, slug: "hub") }
  let(:theirs) { create_app(household: create_household(name: "Other"), slug: "theirs") }
  let(:context) { Query::Context.new(household) }
  let(:now) { Time.now.utc }

  def marker(app, title, at:, kind: "event")
    { app_id: app&.telemetry_id, ts: at, kind: kind, title: title, source: "spec", attrs: {} }
  end

  before do
    Telemetry::Marker.insert_all!([
      marker(hook, "hook deployed", at: now - 10.minutes, kind: "deploy"),
      marker(hub, "hub restarted", at: now - 5.minutes, kind: "restart"),
      marker(nil, "Glass itself", at: now - 2.minutes),
      marker(hook, "yesterday", at: now - 1.day),
      marker(theirs, "theirs", at: now - 1.minute)
    ])
  end

  def titles(**options) = described_class.within(context, from: now - 1.hour, to: now, limit: 50, **options).map(&:title)

  it "reads the household's markers and the fleet's own in the range, newest first" do
    expect(titles).to eq([ "Glass itself", "hub restarted", "hook deployed" ])
    expect(described_class.within(context, from: now - 1.hour, to: now, limit: 1).map(&:title)).to eq([ "Glass itself" ])
  end

  it "narrows to one app — without the fleet's — and to kinds; an app it does not have reads nothing" do
    expect(titles(app: "hook")).to eq([ "hook deployed" ])
    expect(titles(app: "HUB", kinds: %w[deploy restart])).to eq([ "hub restarted" ])
    expect(titles(kinds: %w[deploy])).to eq([ "hook deployed" ])
    expect(titles(app: "theirs")).to eq([])
    expect(titles(app: "nope")).to eq([])
  end
end
