# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApiToken do
  let(:household) { create_household }
  let(:user) { household.users.create!(email: "a@b.co", name: "A", password: "passwordpassword") }

  describe ".generate" do
    it "mints a prefixed token, stores only its digest, and returns the plaintext once" do
      generated = described_class.generate(user: user, name: "Claude")

      expect(generated.record).to be_persisted
      expect(generated.token).to start_with(ApiToken::PREFIX)
      expect(generated.token.length).to eq(ApiToken::PREFIX.length + ApiToken::TOKEN_BYTES * 2)
      expect(generated.record.token_digest).to eq(Digest::SHA256.hexdigest(generated.token))
      expect(generated.record.prefix).to eq(generated.token.first(ApiToken.display_prefix_length))
      expect(generated.record.attributes.values).not_to include(generated.token)
      expect(generated.record.scope).to eq("full")
    end

    it "returns an unpersisted record with errors instead of raising on a bad name" do
      generated = described_class.generate(user: user, name: "")
      expect(generated.record).not_to be_persisted
      expect(generated.record.errors[:name]).to be_present
    end

    it "takes a scope and an expiry" do
      generated = described_class.generate(user: user, name: "agent", scope: ApiToken::Scope::Read, expires_at: 1.day.from_now)
      expect(generated.record).to be_read_only
      expect(generated.record.expires_at).to be_within(1.second).of(1.day.from_now)
    end
  end

  describe ".authenticate" do
    it "finds a live token by its plaintext" do
      generated = described_class.generate(user: user, name: "Claude")
      expect(described_class.authenticate(generated.token)).to eq(generated.record)
    end

    it "ignores expired tokens" do
      generated = described_class.generate(user: user, name: "old", expires_at: 1.minute.ago)
      expect(described_class.authenticate(generated.token)).to be_nil
      expect(generated.record).to be_expired
    end

    it "answers nil without a query for anything that is not an API token" do
      expect(described_class.authenticate(nil)).to be_nil
      expect(described_class.authenticate("session-token")).to be_nil
      expect(described_class.authenticate("glass_definitelynotminted")).to be_nil
    end
  end

  describe "#record_use!" do
    it "stamps at most once an hour" do
      token = described_class.generate(user: user, name: "x").record
      token.record_use!
      first = token.reload.last_used_at
      expect(first).to be_present

      token.record_use!
      expect(token.reload.last_used_at).to eq(first)

      token.update_column(:last_used_at, 2.hours.ago)
      token.record_use!
      expect(token.reload.last_used_at).to be > first
    end
  end

  it "goes with its user" do
    described_class.generate(user: user, name: "x")
    user.destroy!
    expect(described_class.count).to eq(0)
  end
end
