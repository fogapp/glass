# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dashboards and monitors", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let(:headers) { auth_headers(user).merge("Content-Type" => "application/json") }

  it "creates a dashboard, pins widgets into place, moves them and deletes" do
    post "/api/v1/dashboards", params: { name: "Evening", widgets: [] }.to_json, headers: headers
    expect(response).to have_http_status(:created)
    id = json["id"]

    post "/api/v1/dashboards/#{id}/widgets", params: { widget: { title: "Rate", spec: { source: "transactions", shape: "timeseries", compute: [ "rate" ], group_by: [ "app" ] }, span: 2 } }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(json["widgets"].size).to eq(1)
    expect(json["widgets"].first).to include("title" => "Rate", "x" => 0, "y" => 0, "w" => 8, "h" => 6)
    expect(json["widgets"].first["spec"]).to eq("source" => "transactions", "shape" => "timeseries", "compute" => [ "rate" ], "group_by" => [ "app" ])

    post "/api/v1/dashboards/#{id}/widgets", params: { widget: { title: "Logs", spec: { source: "logs" }, w: 4, h: 6 } }.to_json, headers: headers
    expect(json["widgets"].last).to include("x" => 8, "y" => 0, "w" => 4, "h" => 6)

    moved = json["widgets"].map { |widget| widget.merge("y" => widget["title"] == "Rate" ? 6 : 0, "x" => 0) }
    patch "/api/v1/dashboards/#{id}", params: { widgets: moved }.to_json, headers: headers
    expect(json["widgets"].map { |widget| widget.slice("title", "x", "y") }).to eq([ { "title" => "Rate", "x" => 0, "y" => 6 }, { "title" => "Logs", "x" => 0, "y" => 0 } ])

    header = { kind: "header", title: "Traffic", subtitle: "Every app", size: "lg", icon: "globe" }
    patch "/api/v1/dashboards/#{id}", params: { widgets: json["widgets"] + [ header ] }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(json["widgets"].last).to include("kind" => "header", "title" => "Traffic", "subtitle" => "Every app", "size" => "lg", "icon" => "globe", "x" => 0, "y" => 12, "w" => 12, "h" => 3)

    patch "/api/v1/dashboards/#{id}", params: { widgets: [ { spec: { source: "logs" } }, { spec: {} } ] }.to_json, headers: headers
    expect(response).to have_http_status(:unprocessable_content)

    delete "/api/v1/dashboards/#{id}", headers: headers
    expect(response).to have_http_status(:no_content)
  end

  it "creates, evaluates and lists monitors and incidents" do
    post "/api/v1/monitors", params: { name: "silent", kind: "absence", query: { source: "transactions", filter: "app:hook" }, window_seconds: 600 }.to_json, headers: headers
    expect(response).to have_http_status(:created)
    expect(json).to include("state" => "no_data", "condition" => "no transactions for 10 min", "app" => "hook")
    id = json["id"]

    post "/api/v1/monitors/#{id}/evaluate", headers: headers
    expect(json["state"]).to eq("alert")
    expect(json["open_incident"]).to be_present

    get "/api/v1/incidents", headers: headers
    expect(json.first).to include("monitor" => "silent", "closed_at" => nil)

    get "/api/v1/monitors/#{id}", headers: headers
    expect(json["incidents"].size).to eq(1)

    post "/api/v1/monitors", params: { name: "bad", query: {} }.to_json, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
  end
end
