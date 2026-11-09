# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe User do
  let(:household) { create_household }

  it "normalizes email on the way in" do
    user = household.users.create!(email: "  Matt@Example.COM ", name: "M", password: "passwordpassword")
    expect(user.email).to eq("matt@example.com")
  end

  it "requires a password of at least ten characters" do
    user = household.users.build(email: "a@b.co", name: "A", password: "short")
    expect(user).not_to be_valid
    expect(user.errors[:password]).to be_present
  end

  it "knows who is an admin" do
    admin = household.users.create!(email: "a@b.co", name: "A", password: "passwordpassword", role: "admin")
    member = household.users.create!(email: "m@b.co", name: "M", password: "passwordpassword")
    expect(admin).to be_admin
    expect(member).not_to be_admin
  end

  it "takes its sessions and tokens along when destroyed" do
    user = household.users.create!(email: "a@b.co", name: "A", password: "passwordpassword")
    ApiSession.generate!(user: user)
    ApiToken.generate(user: user, name: "t")

    user.destroy!

    expect(ApiSession.where(user_id: user.id)).not_to exist
    expect(ApiToken.where(user_id: user.id)).not_to exist
  end
end
