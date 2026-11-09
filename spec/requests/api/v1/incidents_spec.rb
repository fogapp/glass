# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Incidents", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household, role: "guest") }

  it_behaves_like "a signed-in endpoint", :get, "/api/v1/incidents"

  def monitor(owner, name)
    owner.monitors.create!(name: name, kind: "threshold", query: { "source" => "transactions", "compute" => "p95(duration)" },
      comparison: "gt", threshold: 100, window_seconds: 300, for_seconds: 0, notify: false)
  end

  it "lists open incidents first, then the newest closed, with their monitor's words — and none of another household's" do
    slow = monitor(household, "slow")
    closed = household.incidents.create!(monitor: slow, opened_at: 1.hour.ago, closed_at: 30.minutes.ago, app_slug: "hook", peak_value: 400)
    open = household.incidents.create!(monitor: slow, opened_at: 2.hours.ago, app_slug: "hook", peak_value: 900)
    other = create_household(name: "Other")
    other.incidents.create!(monitor: monitor(other, "theirs"), opened_at: 1.minute.ago)

    get "/api/v1/incidents", headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    expect(json.map { |incident| incident["id"] }).to eq([ open.id, closed.id ])
    expect(json.first).to include("monitor_id" => slow.id, "monitor" => "slow", "condition" => "p95(duration) > 100.0 over 5 min",
      "app" => "hook", "peak_value" => 900.0, "closed_at" => nil)
    expect(response.headers["X-Total-Count"]).to eq("2")
  end
end
