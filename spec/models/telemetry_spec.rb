# typed: false
# frozen_string_literal: true

require "rails_helper"

# The dictionaries' identities sit in unique indexes: a changed digest would
# orphan every series, function and stack already stored.
RSpec.describe Telemetry do
  it "digests to the first 63 bits of SHA-256, pinned" do
    expect(described_class.digest63("glass")).to eq(1_380_945_068_341_205_020)
  end

  it "keys series, functions and stacks by it" do
    expect(Telemetry::MetricSeries.tags_hash("k" => "v")).to eq(4_850_850_460_154_889_350)
    expect(Telemetry::ProfileFunction.identity("a", "b")).to eq(6_463_353_407_833_682_387)
    expect(Telemetry::ProfileStack.identity([ 1, 2, -3 ])).to eq(4_393_767_802_567_534_302)
  end
end
