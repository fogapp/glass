# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "About", type: :request do
  let(:user) { create_user(household: create_household, role: "guest") }

  it_behaves_like "a signed-in endpoint", :get, "/api/v1/about"

  it "describes the instance" do
    get "/api/v1/about", headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    expect(json).to include("environment" => "test", "ruby_version" => RUBY_VERSION, "rails_version" => Rails.version)
    expect(json["postgres_version"]).to match(/\A\d+/)
    expect(json["storage"]).to include("state_dir" => Rails.root.join("storage").to_s)
    expect(json.keys).to include("git_sha", "git_sha_short", "time_zone", "booted_at", "machine")
  end
end
