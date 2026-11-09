# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Markers", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household, role: "guest") }
  let(:hook) { create_app(household: household, slug: "hook") }
  let(:hub) { create_app(household: household, slug: "hub") }
  let(:theirs) { create_app(household: create_household(name: "Other"), slug: "theirs") }
  let(:now) { Time.now.utc }

  it_behaves_like "a signed-in endpoint", :get, "/api/v1/markers"

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

  def titles(**params)
    get "/api/v1/markers", params: { from: (now - 1.hour).to_f, to: now.to_f }.merge(params), headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    json.map { |row| row["title"] }
  end

  it "lists the range's markers, newest first, the household's and Glass's own only" do
    expect(titles).to eq([ "Glass itself", "hub restarted", "hook deployed" ])
    expect(json.last).to include("app" => "hook", "kind" => "deploy", "source" => "spec", "ts" => be_within(1).of((now - 10.minutes).to_f))
  end

  it "narrows to an app and a kind, and an app it does not have to nothing" do
    expect(titles(app: "hook")).to eq([ "hook deployed" ])
    expect(titles(kind: "restart")).to eq([ "hub restarted" ])
    expect(titles(app: "theirs")).to eq([])
  end
end
