# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API tokens", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household, role: "guest") }

  it_behaves_like "a signed-in endpoint", :get, "/api/v1/api_tokens"
  it_behaves_like "a signed-in endpoint", :post, "/api/v1/api_tokens"

  it "mints a token shown once, lists it without its secret, and revokes it — a guest's own included" do
    post "/api/v1/api_tokens", params: { name: " Claude ", scope: "read", expires_in_days: 30 }, headers: auth_headers(user)
    expect(response).to have_http_status(:created)
    expect(json).to include("name" => "Claude", "scope" => "read", "expired" => false)
    expect(json["token"]).to start_with(ApiToken::PREFIX)
    expect(Time.zone.parse(json["expires_at"])).to be_within(1.minute).of(30.days.from_now)
    id = json["id"]

    get "/api/v1/api_tokens", headers: auth_headers(user)
    expect(json).to match([ a_hash_including("id" => id, "name" => "Claude", "prefix" => be_present) ])
    expect(json.first).not_to include("token")

    delete "/api/v1/api_tokens/#{id}", headers: auth_headers(user)
    expect(response).to have_http_status(:no_content)
    expect(ApiToken.where(id: id)).to be_empty
  end

  it "defaults to a full token that never expires" do
    post "/api/v1/api_tokens", params: { name: "script", scope: "everything" }, headers: auth_headers(user)
    expect(json).to include("scope" => "full", "expires_at" => nil)
  end

  it "422s a blank name or an expiry out of range" do
    post "/api/v1/api_tokens", params: { name: "" }, headers: auth_headers(user)
    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"]).to include(a_string_matching(/Name/))

    post "/api/v1/api_tokens", params: { name: "x", expires_in_days: ApiToken::MAX_EXPIRES_IN_DAYS + 1 }, headers: auth_headers(user)
    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"].first).to include("between 1 and")
    expect(ApiToken.count).to eq(0)
  end

  it "never lists or revokes someone else's token, even in the same household" do
    theirs = ApiToken.generate(user: create_user(household: household), name: "theirs").record

    get "/api/v1/api_tokens", headers: auth_headers(user)
    expect(json).to eq([])

    delete "/api/v1/api_tokens/#{theirs.id}", headers: auth_headers(user)
    expect(response).to have_http_status(:not_found)
    expect(theirs.reload).to be_persisted
  end
end
