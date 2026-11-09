# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Apps and ingest keys", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:member) { create_user(household: household, role: "member") }

  it "creates an app with its first key, shown once, and lists it as silent" do
    post "/api/v1/apps", params: { name: "Hook" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:created)
    expect(json).to include("slug" => "hook", "name" => "Hook", "identity_mode" => "pseudonymous", "reporting" => false)
    expect(json["ingest_key"]).to start_with("glass_ing_")
    expect(json["agent_settings"]).to include("trace_sample_rate" => 0.1)

    get "/api/v1/apps", headers: auth_headers(member)
    expect(json.map { |a| a["slug"] }).to eq([ "hook" ])
    expect(json.first).not_to have_key("ingest_key")
  end

  it "keeps colour slots distinct for the first eight apps" do
    slots = (1..9).map do |i|
      post "/api/v1/apps", params: { name: "App #{i}" }, headers: auth_headers(admin)
      json["color_slot"]
    end
    expect(slots.first(8)).to match_array(1..8)
    expect(slots.last).to eq(1)
  end

  it "refuses a bad slug and a duplicate" do
    post "/api/v1/apps", params: { name: "X", slug: "Not Ok" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_content)
    post "/api/v1/apps", params: { name: "Hook" }, headers: auth_headers(admin)
    post "/api/v1/apps", params: { name: "Hook again", slug: "hook" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "keeps a link into the app's own console, and refuses one that is not an address" do
    app = create_app(household: household, slug: "aio")
    patch "/api/v1/apps/#{app.id}", params: { link_template: " https://assistant.example.net/traces/{run} " }, headers: auth_headers(admin)
    expect(json["link_template"]).to eq("https://assistant.example.net/traces/{run}")
    patch "/api/v1/apps/#{app.id}", params: { link_template: "javascript:alert(1)" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_content)
    patch "/api/v1/apps/#{app.id}", params: { link_template: "" }, headers: auth_headers(admin)
    expect(json["link_template"]).to be_nil
  end

  it "lets only admins change apps, and validates agent settings" do
    app = create_app(household: household)
    patch "/api/v1/apps/#{app.id}", params: { name: "H" }, headers: auth_headers(member)
    expect(response).to have_http_status(:forbidden)

    patch "/api/v1/apps/#{app.id}", params: { identity_mode: "named", agent_settings: { trace_sample_rate: 2, profile_hz: 5, log_level: "loud", profiling: "false" } },
      headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(json["identity_mode"]).to eq("named")
    expect(json["agent_settings"]).to include("trace_sample_rate" => 1.0, "profile_hz" => 10, "log_level" => "info", "profiling" => false)
    expect(app.reload.directives).to include("identity" => "named", "profiling" => false)
  end

  it "mints, lists and revokes keys" do
    app = create_app(household: household)
    post "/api/v1/apps/#{app.id}/ingest_keys", params: { name: "prod" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:created)
    token = json["token"]
    expect(IngestKey.authenticate(token)).to be_present

    get "/api/v1/apps/#{app.id}/ingest_keys", headers: auth_headers(admin)
    expect(json.first).to include("name" => "prod", "revoked" => false)
    expect(json.first).not_to have_key("token")

    delete "/api/v1/apps/#{app.id}/ingest_keys/#{json.first['id']}", headers: auth_headers(admin)
    expect(response).to have_http_status(:no_content)
    expect(IngestKey.authenticate(token)).to be_nil

    post "/api/v1/apps/#{app.id}/ingest_keys", headers: auth_headers(member)
    expect(response).to have_http_status(:forbidden)
  end

  it "remembers a removed fog app so the sync does not make it again, and forgets once it is added back" do
    app = create_app(household: household, slug: "minio")
    app.update!(fog_name: "minio")
    plain = create_app(household: household, slug: "notes")

    delete "/api/v1/apps/#{app.id}", headers: auth_headers(admin)
    expect(response).to have_http_status(:no_content)
    delete "/api/v1/apps/#{plain.id}", headers: auth_headers(admin)
    expect(AppSetting.current.fog_ignored_apps).to eq([ "minio" ])

    post "/api/v1/apps", params: { name: "Minio" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:created)
    expect(AppSetting.current.fog_ignored_apps).to eq([])
  end

  it "does not reach across households" do
    other = create_app(household: create_household(name: "Other"))
    get "/api/v1/apps/#{other.id}", headers: auth_headers(admin)
    expect(response).to have_http_status(:not_found)
  end
end
