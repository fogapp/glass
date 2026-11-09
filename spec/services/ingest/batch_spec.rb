# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ingest::Batch do
  let(:household) { create_household }
  let(:reporting_app) { create_app(household: household) }
  let(:marker) { { t: "marker", ts: Time.now.to_f, kind: "deploy", title: "x" } }

  it "refuses an empty body" do
    expect { described_class.parse(app: reporting_app, text: "") }.to raise_error(Ingest::Batch::Invalid, "Empty body")
    expect { described_class.parse(app: reporting_app, text: "\n#{marker.to_json}") }.to raise_error(Ingest::Batch::Invalid, "Empty body")
  end

  it "takes up to the record limit and refuses a body past it" do
    stub_const("Ingest::Batch::MAX_RECORDS", 2)
    expect(described_class.parse(app: reporting_app, text: batch_body([ marker, marker ])).markers.size).to eq(2)
    expect { described_class.parse(app: reporting_app, text: batch_body([ marker, marker, marker ])) }
      .to raise_error(Ingest::Batch::Invalid, "More than 2 records in one batch")
  end

  it "does not count blank lines toward the record limit" do
    stub_const("Ingest::Batch::MAX_RECORDS", 2)
    text = batch_body([ marker ]) + "\n\n\n#{marker.to_json}\n\n"
    expect(described_class.parse(app: reporting_app, text: text).markers.size).to eq(2)
  end

  it "keeps the first twenty kinds of what the agent says it dropped" do
    dropped = (1..30).to_h { |i| [ "type#{i}", i ] }
    header = described_class.parse(app: reporting_app, text: batch_body([ marker ], dropped: dropped)).header
    expect(header.dropped).to eq((1..20).to_h { |i| [ "type#{i}", i ] })
  end
end
