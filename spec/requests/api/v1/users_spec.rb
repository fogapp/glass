# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Users", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin", email: "admin@example.com") }

  it_behaves_like "a signed-in endpoint", :get, "/api/v1/users"
  it_behaves_like "a signed-in endpoint", :get, "/api/v1/me"

  it "lists the household's people in the order they joined, and nobody else's" do
    admin
    guest = create_user(household: household, role: "guest", email: "guest@example.com")
    create_user(household: create_household(name: "Other"), email: "stranger@example.com")

    get "/api/v1/users", headers: auth_headers(guest)
    expect(response).to have_http_status(:ok)
    expect(json.map { |user| user["email"] }).to eq([ "admin@example.com", "guest@example.com" ])
    expect(json.first).to eq("id" => admin.id, "email" => "admin@example.com", "name" => "Test User", "role" => "admin",
      "household_id" => household.id)
  end

  it "answers who is signed in" do
    get "/api/v1/me", headers: auth_headers(admin)
    expect(json).to include("id" => admin.id, "role" => "admin")
    expect(json).not_to include("password_digest")
  end
end
