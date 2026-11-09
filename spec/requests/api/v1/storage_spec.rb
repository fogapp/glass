# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Storage", type: :request do
  let(:user) { create_user(household: create_household, role: "guest") }

  it_behaves_like "a signed-in endpoint", :get, "/api/v1/storage"

  it "reports every telemetry table by day against the budget" do
    get "/api/v1/storage", headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    expect(json["tables"].map { |table| table["table"] }).to eq(Telemetry::Tables::ALL.map(&:name))
    transactions = json["tables"].find { |table| table["table"] == "transactions" }
    expect(transactions).to include("label" => be_present, "retention_days" => be_positive)
    expect(transactions["days"]).to include(a_hash_including("day" => Time.now.utc.to_date.iso8601, "bytes" => be_a(Integer)))
    expect(json["used_bytes"]).to eq(json["tables"].sum { |table| table["bytes"] } + json["dictionary_bytes"])
    expect(json["budget_bytes"]).to eq(AppSetting.current.disk_budget_mb.megabytes)
  end
end
