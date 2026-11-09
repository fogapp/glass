# typed: false
# frozen_string_literal: true

require "rails_helper"

# The Activity page reads /api/v1/events (the URL dodges ad blockers).
RSpec.describe "Activity", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household, role: "guest") }
  let(:other) { create_household(name: "Other") }

  it_behaves_like "a signed-in endpoint", :get, "/api/v1/events"

  it "lists the household's entries and Glass's own, newest first, never another household's" do
    hook = create_app(household: household)
    Activity.record(source: "apps", event: "app.created", summary: "Hook added", subject: hook, payload: { slug: "hook" })
    Activity.record(source: "system", event: "boot", summary: "Glass booted", severity: Activity::Severity::Warn)
    Activity.record(source: "apps", event: "app.created", summary: "Theirs", household_id: other.id)

    get "/api/v1/events", headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    expect(json.map { |entry| entry["summary"] }).to eq([ "Glass booted", "Hook added" ])
    expect(json.last).to include("source" => "apps", "event" => "app.created", "severity" => "info", "subject_type" => "App",
      "subject" => { "type" => "App", "id" => hook.id, "label" => "Hook", "path" => "/apps/hook" }, "payload" => { "slug" => "hook" })
    expect(response.headers["X-Total-Count"]).to eq("2")
  end

  it "filters by severity, ignoring one it does not know, and pages" do
    Activity.record(source: "apps", event: "a", summary: "fine", household_id: household.id)
    Activity.record(source: "apps", event: "b", summary: "bad", severity: Activity::Severity::Error, household_id: household.id)

    get "/api/v1/events", params: { severity: "error" }, headers: auth_headers(user)
    expect(json.map { |entry| entry["summary"] }).to eq([ "bad" ])

    get "/api/v1/events", params: { severity: "loud", per: 1, page: 2 }, headers: auth_headers(user)
    expect(json.size).to eq(1)
    expect(response.headers).to include("X-Total-Count" => "2", "X-Page" => "2", "X-Per-Page" => "1")
  end
end
