# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Invites", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }

  it_behaves_like "a signed-in endpoint", :post, "/api/v1/invites"

  def accept(code, **fields)
    post "/api/v1/invites/accept", params: { code: code, name: "New", email: "new@example.com", password: "passwordpassword" }.merge(fields)
  end

  it "lets an admin invite at a role, and the invited person join the household signed in" do
    post "/api/v1/invites", params: { role: "guest" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:created)
    expect(json).to include("role" => "guest", "code" => be_present, "expires_at" => be_present)

    accept(json["code"])
    expect(response).to have_http_status(:created)
    expect(json["user"]).to include("email" => "new@example.com", "role" => "guest", "household_id" => household.id)
    get "/api/v1/me", headers: bearer(json["token"])
    expect(json["email"]).to eq("new@example.com")
  end

  it "invites a member when no role (or an unknown one) is named" do
    post "/api/v1/invites", params: { role: "owner" }, headers: auth_headers(admin)
    expect(json["role"]).to eq("member")
  end

  it "is for admins only" do
    post "/api/v1/invites", headers: auth_headers(create_user(household: household, role: "member"))
    expect(response).to have_http_status(:forbidden)
    expect(json["errors"]).to eq([ "Admin access required" ])
    expect(InviteCode.count).to eq(0)
  end

  it "422s a used, expired or unknown code, and an invalid person without spending the code" do
    invite = InviteCode.generate!(household: household, created_by: admin)

    accept(invite.code, password: "short")
    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"]).to include(a_string_matching(/Password/))
    expect(invite.reload).to be_usable

    accept(invite.code)
    expect(response).to have_http_status(:created)

    accept(invite.code, email: "again@example.com")
    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"]).to eq([ "Invite is invalid or expired" ])

    expired = InviteCode.generate!(household: household, created_by: admin)
    expired.update!(expires_at: 1.minute.ago)
    accept(expired.code, email: "late@example.com")
    expect(response).to have_http_status(:unprocessable_content)

    accept("nope", email: "who@example.com")
    expect(response).to have_http_status(:unprocessable_content)

    post "/api/v1/invites/accept", params: { code: InviteCode.generate!(household: household, created_by: admin).code }
    expect(response).to have_http_status(:bad_request)
    expect(json["errors"]).to eq([ "Missing parameter: email" ])
  end
end
