# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Telemetry::Sketch do
  # The mapping every agent must reproduce (docs/ingest-protocol.md). These
  # numbers are the contract: an agent whose sketch gives a different index
  # for one of them reports percentiles the server will read wrongly.
  it "maps values to the documented bucket indexes" do
    expect(described_class.index_for(1.0)).to eq(0)
    expect(described_class.index_for(1.02)).to eq(1)
    expect(described_class.index_for(10.0)).to eq(117)
    expect(described_class.index_for(250.0)).to eq(279)
    expect(described_class.index_for(1000.0)).to eq(349)
    expect(described_class.index_for(0.5)).to eq(-35)
    expect(described_class.index_for(0.0)).to be_nil
    expect(described_class.index_for(-3.0)).to be_nil
  end

  it "answers quantiles within the relative accuracy" do
    sketch = described_class.new
    values = (1..1000).map { |i| i * 3.7 }
    values.each { |value| sketch.add(value) }
    expect(sketch.count).to eq(1000)

    [ 0.5, 0.9, 0.95, 0.99 ].each do |quantile|
      exact = values.sort[(quantile * 999).floor]
      expect(sketch.quantile(quantile)).to be_within(exact * 0.011).of(exact)
    end
  end

  it "counts unbucketed zeros as the smallest values" do
    sketch = described_class.new
    sketch.add(100.0, 2)
    # Two zeros and two hundreds: the median sits at the boundary.
    expect(sketch.quantile(0.25, total: 4)).to eq(0.0)
    expect(sketch.quantile(0.9, total: 4)).to be_within(1.5).of(100.0)
  end

  it "merges by adding buckets, in either form" do
    a = described_class.new
    b = described_class.new
    (1..100).each { |i| a.add(i.to_f) }
    (101..200).each { |i| b.add(i.to_f) }
    merged = described_class.from_pairs(a.to_pairs)
    merged.merge!(b)
    expect(merged.count).to eq(200)
    expect(merged.quantile(0.5)).to be_within(2).of(100)
    expect(merged.to_pairs.each_slice(2).map(&:first)).to eq(merged.to_pairs.each_slice(2).map(&:first).sort)
  end

  it "ignores malformed pairs" do
    sketch = described_class.from_pairs([ 5, 1, 7 ]) # a trailing index without a count
    expect(sketch.count).to eq(1)
    expect(described_class.from_pairs([ 5, 0, 6, -2 ])).to be_empty
  end
end
