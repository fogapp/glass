# typed: false
# frozen_string_literal: true

require "rails_helper"

# DigestedToken and UseStamped, through the ingest key (ApiToken's own spec
# covers the other includer).
RSpec.describe DigestedToken do
  let(:household) { create_household }
  let(:app) { create_app(household: household) }

  it "mints a prefixed plaintext and keeps only its digest and display prefix" do
    generated = IngestKey.generate(app: app, name: "prod")
    key = generated.record
    expect(generated.token).to start_with(IngestKey::PREFIX)
    expect(generated.token.length).to eq(IngestKey::PREFIX.length + DigestedToken::TOKEN_BYTES * 2)
    expect(key.token_digest).to eq(IngestKey.digest(generated.token))
    expect(key.prefix).to eq(generated.token.first(IngestKey::PREFIX.length + DigestedToken::DISPLAY_CHARS))
  end

  it "authenticates its own kind only, and never a revoked one" do
    generated = IngestKey.generate(app: app, name: "prod")
    expect(IngestKey.authenticate(generated.token)).to eq(generated.record)
    expect(IngestKey.authenticate(generated.token.sub(IngestKey::PREFIX, ApiToken::PREFIX))).to be_nil
    expect(IngestKey.authenticate(nil)).to be_nil

    generated.record.revoke!
    expect(IngestKey.authenticate(generated.token)).to be_nil
  end

  it "stamps a use at most once per interval" do
    key = IngestKey.generate(app: app, name: "prod").record
    key.record_use!
    first = key.reload.last_used_at
    expect(first).to be_present

    key.record_use!
    expect(key.reload.last_used_at).to eq(first)

    key.update_column(:last_used_at, (UseStamped::USE_STAMP_INTERVAL + 1.minute).ago)
    key.record_use!
    expect(key.reload.last_used_at).to be_within(5.seconds).of(Time.current)
  end
end
