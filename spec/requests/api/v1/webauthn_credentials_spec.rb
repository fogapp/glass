# typed: false
# frozen_string_literal: true

require "rails_helper"
require "webauthn"
require "webauthn/fake_client"

RSpec.describe "Passkeys", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household, role: "guest") }
  let(:origin) { "http://www.example.com" }

  it_behaves_like "a signed-in endpoint", :get, "/api/v1/webauthn_credentials"
  it_behaves_like "a signed-in endpoint", :post, "/api/v1/webauthn_credentials/register/begin"

  def credential(owner, nickname: nil)
    owner.webauthn_credentials.create!(external_id: SecureRandom.hex(8), public_key: "pk", sign_count: 0, nickname: nickname)
  end

  it "enrols a passkey from a signed challenge — a guest too — and lists it" do
    post "/api/v1/webauthn_credentials/register/begin", headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    expect(json["options"]).to include("challenge" => be_present, "rp" => a_hash_including("id" => "www.example.com"))
    expect(json["options"]["user"]).to include("name" => user.email)
    token = json["challenge_token"]

    attestation = WebAuthn::FakeClient.new(origin).create(challenge: json["options"]["challenge"], rp_id: "www.example.com")
    post "/api/v1/webauthn_credentials/register/finish", params: { credential: attestation, challenge_token: token, nickname: " Phone " },
      headers: auth_headers(user), as: :json
    expect(response).to have_http_status(:created)
    expect(json).to include("nickname" => "Phone", "last_used_at" => nil)

    get "/api/v1/webauthn_credentials", headers: auth_headers(user)
    expect(json.map { |row| row["nickname"] }).to eq([ "Phone" ])
    expect(ActivityEntry.where(event: "passkey.enrolled").count).to eq(1)
  end

  it "422s a challenge that was tampered with or answered wrongly, and 403s one issued to someone else" do
    post "/api/v1/webauthn_credentials/register/finish", params: { credential: {}, challenge_token: "forged" }, headers: auth_headers(user), as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"].first).to start_with("Passkey verification failed")

    post "/api/v1/webauthn_credentials/register/begin", headers: auth_headers(user)
    attestation = WebAuthn::FakeClient.new(origin).create(challenge: Base64.urlsafe_encode64(SecureRandom.random_bytes(32), padding: false), rp_id: "www.example.com")
    post "/api/v1/webauthn_credentials/register/finish", params: { credential: attestation, challenge_token: json["challenge_token"] },
      headers: auth_headers(user), as: :json
    expect(response).to have_http_status(:unprocessable_content)

    other = create_user(household: household)
    post "/api/v1/webauthn_credentials/register/begin", headers: auth_headers(other)
    post "/api/v1/webauthn_credentials/register/finish", params: { credential: {}, challenge_token: json["challenge_token"] },
      headers: auth_headers(user), as: :json
    expect(response).to have_http_status(:forbidden)
    expect(user.webauthn_credentials.count).to eq(0)
  end

  it "removes only the signed-in user's own passkeys" do
    mine = credential(user, nickname: "Laptop")
    theirs = credential(create_user(household: household))

    get "/api/v1/webauthn_credentials", headers: auth_headers(user)
    expect(json).to match([ a_hash_including("id" => mine.id, "nickname" => "Laptop") ])

    delete "/api/v1/webauthn_credentials/#{theirs.id}", headers: auth_headers(user)
    expect(response).to have_http_status(:not_found)
    expect(theirs.reload).to be_persisted

    delete "/api/v1/webauthn_credentials/#{mine.id}", headers: auth_headers(user)
    expect(response).to have_http_status(:no_content)
    expect(WebauthnCredential.where(id: mine.id)).to be_empty
    expect(ActivityEntry.where(event: "passkey.removed").pluck(:summary)).to eq([ "Test User removed a passkey (Laptop)" ])
  end

  describe "signing in with one (Auth::PasskeysController)" do
    let(:client) { WebAuthn::FakeClient.new(origin) }

    before do
      post "/api/v1/webauthn_credentials/register/begin", headers: auth_headers(user)
      attestation = client.create(challenge: json["options"]["challenge"], rp_id: "www.example.com")
      post "/api/v1/webauthn_credentials/register/finish", params: { credential: attestation, challenge_token: json["challenge_token"], nickname: "Phone" },
        headers: auth_headers(user), as: :json
      expect(response).to have_http_status(:created)
    end

    it "answers a challenge naming the account's passkeys, and a session for the passkey that answers it" do
      post "/api/v1/auth/passkey/login/begin", params: { email: " #{user.email.upcase} " }
      expect(response).to have_http_status(:ok)
      expect(json["options"]["allowCredentials"].size).to eq(1)

      assertion = client.get(challenge: json["options"]["challenge"], rp_id: "www.example.com")
      post "/api/v1/auth/passkey/login/finish", params: { credential: assertion, challenge_token: json["challenge_token"] }, as: :json
      expect(response).to have_http_status(:created)
      expect(json["user"]).to include("id" => user.id)
      expect(ApiSession.live(json["token"]).device).to eq("passkey (Phone)")
      expect(user.webauthn_credentials.first.last_used_at).to be_present
    end

    it "401s an expired challenge, a passkey it does not know, and a wrong answer" do
      post "/api/v1/auth/passkey/login/finish", params: { credential: {}, challenge_token: "forged" }, as: :json
      expect(response).to have_http_status(:unauthorized)
      expect(json["errors"]).to eq([ "The sign-in challenge expired — try again" ])

      post "/api/v1/auth/passkey/login/begin"
      expect(json["options"]["allowCredentials"]).to be_blank
      token = json["challenge_token"]
      stranger = WebAuthn::FakeClient.new(origin)
      stranger.create(challenge: json["options"]["challenge"], rp_id: "www.example.com")
      post "/api/v1/auth/passkey/login/finish", params: { credential: stranger.get(challenge: json["options"]["challenge"], rp_id: "www.example.com"),
                                                         challenge_token: token }, as: :json
      expect(response).to have_http_status(:unauthorized)
      expect(json["errors"]).to eq([ "That passkey isn't registered here" ])

      post "/api/v1/auth/passkey/login/begin"
      wrong = Base64.urlsafe_encode64(SecureRandom.random_bytes(32), padding: false)
      post "/api/v1/auth/passkey/login/finish", params: { credential: client.get(challenge: wrong, rp_id: "www.example.com"),
                                                         challenge_token: json["challenge_token"] }, as: :json
      expect(response).to have_http_status(:unauthorized)
      expect(json["errors"].first).to start_with("Passkey verification failed")
    end
  end
end
