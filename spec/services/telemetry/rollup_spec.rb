# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Telemetry::Rollup do
  let(:household) { create_household }
  let(:hook) { create_app(household: household, slug: "hook") }
  let(:now) { Time.now.utc.change(min: 0, sec: 0) }

  it "folds closed windows into the 5-minute tier, merging sketches, and advances only then" do
    records = (0...12).map do |i|
      { t: "metric", ts: (now - 20.minutes + i * 10).to_i, name: "lat", kind: "dist", tags: {}, n: 2, sum: 60.0, min: 20.0, max: 40.0, last: 40.0,
        sk: [ 152, 1, 187, 1 ] }
    end
    write_batch(hook, records)
    written = described_class.run!(now: now)
    expect(written["5m"]).to eq(1)

    row = Telemetry::MetricPoint5m.order(:ts).first
    expect(row).to have_attributes(n: 24, sum: 720.0, min: 20.0, max: 40.0, last: 40.0)
    expect(row.sketch).to eq([ 152, 12, 187, 12 ])
    expect(Telemetry::Cursor.position("rollup:5m")).to eq(now - 5.minutes)

    # Idempotent: rolling the same window again rewrites, never duplicates.
    Telemetry::Cursor.advance!("rollup:5m", now - 20.minutes)
    described_class.run!(now: now)
    expect(Telemetry::MetricPoint5m.count).to eq(1)
  end

  it "rolls nothing when nothing has closed" do
    expect(described_class.run!(now: now)).to eq("5m" => 0, "1h" => 0)
  end
end
