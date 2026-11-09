# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "fog-integration/1 surface", type: :request do
  include_context "with fog token"

  def connect(consumer = "newtab")
    post "/fog/integrations", params: { consumer: consumer, offer: "monitoring" }, headers: fog_headers
  end

  it "rejects a wrong bearer" do
    post "/fog/integrations", params: { consumer: "newtab", offer: "monitoring" },
      headers: bearer("nope")
    expect(response).to have_http_status(:unauthorized)
  end

  context "with a household and its admin" do
    let!(:household) { create_household }
    let!(:admin) { create_user(household: household, role: "admin") }

    it "mints an ingest key and a read-only token for a new app, in one connection" do
      connect

      expect(response).to have_http_status(:created)
      key = IngestKey.authenticate(json["secrets"]["GLASS_API_KEY"])
      expect(key.app.fog_name).to eq("newtab")
      expect(key.app.household).to eq(household)
      read = ApiToken.authenticate(json["secrets"]["GLASS_READ_TOKEN"])
      expect(read).to be_read_only
      expect(read.user).to eq(admin)
      expect(read.name).to eq("fog: newtab")
    end

    it "reuses the app fog's sync made, and follows one a person removed" do
      existing = App.create!(household: household, slug: "newtab", name: "Newtab")
      AppSetting.current.ignore_fog_app!("newtab")

      connect

      expect(IngestKey.authenticate(json["secrets"]["GLASS_API_KEY"]).app).to eq(existing)
      expect(existing.reload.fog_name).to eq("newtab")
      expect(AppSetting.current.fog_ignores?("newtab")).to be(false)
    end

    it "refuses an offer it does not make" do
      post "/fog/integrations", params: { consumer: "newtab", offer: "telemetry" }, headers: fog_headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(json["errors"].first).to include("monitoring")
    end

    it "reports and revokes both credentials together" do
      connect
      id = json["id"]
      ingest = json["secrets"]["GLASS_API_KEY"]
      read = json["secrets"]["GLASS_READ_TOKEN"]

      get "/fog/integrations/#{id}", headers: fog_headers
      expect(response).to have_http_status(:ok)
      expect(json).to include("id" => id, "active" => true, "last_activity_at" => nil)

      ApiToken.authenticate(read).update!(last_used_at: 1.minute.ago)
      get "/fog/integrations/#{id}", headers: fog_headers
      expect(json["last_activity_at"]).to be_present

      delete "/fog/integrations/#{id}", headers: fog_headers
      expect(response).to have_http_status(:no_content)
      expect(IngestKey.authenticate(ingest)).to be_nil
      expect(ApiToken.authenticate(read)).to be_nil

      get "/fog/integrations/#{id}", headers: fog_headers
      expect(json["active"]).to be(false)
      delete "/fog/integrations/#{id}", headers: fog_headers
      expect(response).to have_http_status(:no_content)
    end

    it "answers 404 for an integration it never made" do
      delete "/fog/integrations/#{SecureRandom.uuid}", headers: fog_headers
      expect(response).to have_http_status(:not_found)
      get "/fog/integrations/garbage", headers: fog_headers
      expect(response).to have_http_status(:not_found)
    end
  end

  it "says to sign in once before there is an admin to hold the read token" do
    create_household
    connect
    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"].first).to include("sign in")
    expect(IngestKey.count).to eq(0)
  end

  it "says to finish setup before there is a household" do
    connect
    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"].first).to include("setup")
  end
end
