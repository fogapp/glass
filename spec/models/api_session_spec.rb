# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApiSession do
  let(:user) { create_household.users.create!(email: "kim@example.com", name: "Kim", password: "passwordpassword") }

  it "keeps only the digest of its bearer token, and finds the session by the plaintext" do
    session = described_class.generate!(user: user, device: "laptop")
    token = session.token
    expect(token).to match(/\A\h{64}\z/)

    row = described_class.connection.select_one(
      described_class.sanitize_sql([ "SELECT * FROM api_sessions WHERE id = ?", session.id ])
    )
    expect(row).not_to have_key("token")
    expect(row.values.compact.map(&:to_s)).not_to include(token)
    expect(row["token_digest"]).to eq(DigestedToken.digest(token))

    expect(described_class.live(token)).to eq(session)
    expect(described_class.find(session.id).token).to be_nil
    expect(described_class.live(row["token_digest"])).to be_nil
    expect(described_class.live("nope")).to be_nil
  end

  it "reads an expired session as none and removes it" do
    session = described_class.generate!(user: user, expires_at: 1.minute.ago)
    expect(described_class.live(session.token)).to be_nil
    expect(described_class.exists?(session.id)).to be(false)
  end

  it "spends a handoff code once, handing over a fresh token that replaces the minted one" do
    minted = described_class.generate!(user: user, device: "fog")
    code = minted.issue_handoff!

    redeemed = described_class.redeem_handoff(code)
    expect(redeemed).to eq(minted)
    expect(redeemed.token).to be_present
    expect(redeemed.token).not_to eq(minted.token)
    expect(described_class.live(redeemed.token)).to eq(minted)
    expect(described_class.live(minted.token)).to be_nil
    expect(described_class.redeem_handoff(code)).to be_nil
  end
end
