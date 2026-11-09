# typed: false
# frozen_string_literal: true

# Hand-rolled fixture helpers, no FactoryBot.
module RequestHelpers
  def create_user(household:, email: nil, role: "member", password: "passwordpassword")
    household.users.create!(
      email: email || "user-#{SecureRandom.hex(4)}@example.com",
      name: "Test User",
      password: password,
      role: role
    )
  end

  def auth_headers(user, device: "spec")
    bearer(ApiSession.generate!(user: user, device: device).token)
  end

  # Any credential the bearer stack, /mcp, /ingest or /fog reads.
  def bearer(token)
    { "Authorization" => "Bearer #{token}" }
  end

  def json
    JSON.parse(response.body)
  end
end

RSpec.configure do |config|
  config.include RequestHelpers, type: :request
end

# Every console endpoint is behind the bearer stack:
# `it_behaves_like "a signed-in endpoint", :get, "/api/v1/fleet"`.
RSpec.shared_examples "a signed-in endpoint" do |verb, path|
  it "401s without credentials, and with a credential nobody issued" do
    public_send(verb, path)
    expect(response).to have_http_status(:unauthorized)
    expect(json["errors"]).to eq([ "unauthorized" ])

    public_send(verb, path, headers: bearer("not-a-session"))
    expect(response).to have_http_status(:unauthorized)
  end
end
