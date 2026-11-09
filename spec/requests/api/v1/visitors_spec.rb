# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Visitor journeys", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household, role: "guest") }
  let(:hook) { create_app(household: household, slug: "hook") }
  let(:theirs) { create_app(household: create_household(name: "Other"), slug: "theirs") }
  let(:now) { Time.now.utc }

  it_behaves_like "a signed-in endpoint", :get, "/api/v1/visitors/journeys"

  def pageviews(visit, *routes)
    routes.each_with_index.map do |route, index|
      { t: "page", ts: (now - 10.minutes + index).to_f, kind: "pageview", visit: visit, route: route, path: route }
    end
  end

  before do
    write_batch(hook, pageviews("v1", "/", "/wants", "/wants/:id") + pageviews("v2", "/", "/wants", "/wants") +
      [ { t: "page", ts: (now - 9.minutes).to_f, kind: "click", visit: "v2", route: "/settings" } ])
    write_batch(theirs, pageviews("v3", "/", "/wants"))
  end

  def edges(**params)
    get "/api/v1/visitors/journeys", params: { from: "-1h", to: now.iso8601 }.merge(params), headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    json["edges"]
  end

  it "counts page-to-page steps, busiest first, skipping reloads, clicks and other households" do
    expect(edges).to eq([ { "from" => "/", "to" => "/wants", "count" => 2 }, { "from" => "/wants", "to" => "/wants/:id", "count" => 1 } ])
  end

  it "takes a filter, and says what is wrong with one it cannot read" do
    expect(edges(filter: "app:theirs")).to eq([])
    expect(edges(filter: "app:hook")).to include({ "from" => "/", "to" => "/wants", "count" => 2 })

    get "/api/v1/visitors/journeys", params: { from: "-1h", filter: "nonsense:1" }, headers: auth_headers(user)
    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"].first).to be_present
  end
end
