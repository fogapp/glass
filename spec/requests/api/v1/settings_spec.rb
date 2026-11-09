# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Settings", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }

  it "shows retention with defaults and saves overrides and the budget, never the token" do
    get "/api/v1/app_setting", headers: auth_headers(admin)
    expect(json["retention"].find { |r| r["table"] == "spans" }).to include("days" => 7, "overridden" => false)
    expect(json["disk_budget_mb"]).to eq(6144)

    patch "/api/v1/app_setting", params: { ntfy_url: "http://ntfy", ntfy_token: "tk_secret", disk_budget_mb: 1024, retention_days: { spans: 3 } },
      headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(json).to include("ntfy_url" => "http://ntfy", "ntfy_token_set" => true, "disk_budget_mb" => 1024)
    expect(json.to_s).not_to include("tk_secret")
    expect(json["retention"].find { |r| r["table"] == "spans" }).to include("days" => 3, "overridden" => true)

    patch "/api/v1/app_setting", params: { disk_budget_mb: 10 }, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "lists the fog apps removed from Glass and follows one again" do
    AppSetting.current.update!(fog_ignored_apps: %w[syncthing minio])
    get "/api/v1/app_setting", headers: auth_headers(admin)
    expect(json["fog"]["ignored_apps"]).to eq(%w[minio syncthing])

    expect {
      patch "/api/v1/app_setting", params: { fog_ignored_apps: [ "syncthing", "Not A Name" ] }, headers: auth_headers(admin), as: :json
    }.to have_enqueued_job(FogSyncJob)
    expect(json["fog"]["ignored_apps"]).to eq([ "syncthing" ])

    # Saving anything else leaves the list as it is.
    expect { patch "/api/v1/app_setting", params: { disk_budget_mb: 2048 }, headers: auth_headers(admin) }.not_to have_enqueued_job(FogSyncJob)
    expect(AppSetting.current.fog_ignored_apps).to eq([ "syncthing" ])

    patch "/api/v1/app_setting", params: { fog_ignored_apps: [] }, headers: auth_headers(admin), as: :json
    expect(json["fog"]["ignored_apps"]).to eq([])
  end

  it "reports storage by signal" do
    get "/api/v1/storage", headers: auth_headers(admin)
    expect(json["tables"].map { |t| t["table"] }).to include("transactions", "logs")
    expect(json["budget_bytes"]).to eq(6144.megabytes)
  end
end
