# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe UpstreamCircuitBreaker do
  let(:key) { "rss:example.test" }

  # A single reset connection is the most ordinary thing on the internet and
  # says nothing about whether a host is up. Opening on the first one meant
  # one dropped packet blacklisted the host for every source under it,
  # including the ones that would have worked.
  it "stays closed for a failure that hasn't repeated" do
    described_class.trip!(key)

    expect(described_class.open?(key)).to be(false)
  end

  it "stays closed below the threshold" do
    (described_class::THRESHOLD - 1).times { described_class.trip!(key) }

    expect(described_class.open?(key)).to be(false)
  end

  it "opens once the failures add up" do
    described_class::THRESHOLD.times { described_class.trip!(key) }

    expect(described_class.open?(key)).to be(true)
  end

  it "says which request was the one that opened it" do
    results = Array.new(described_class::THRESHOLD) { described_class.trip!(key) }

    expect(results.count(true)).to eq(1)
    expect(results.last).to be(true)
  end

  # Without this, three failures scattered across an afternoon of otherwise
  # healthy fetches would eventually open a breaker on a host that is plainly
  # working.
  it "forgets earlier failures once a request succeeds" do
    (described_class::THRESHOLD - 1).times { described_class.trip!(key) }
    described_class.reset!(key)
    described_class.trip!(key)

    expect(described_class.open?(key)).to be(false)
  end

  it "closes a breaker that had opened" do
    described_class::THRESHOLD.times { described_class.trip!(key) }
    described_class.reset!(key)

    expect(described_class.open?(key)).to be(false)
  end

  it "keeps hosts apart" do
    described_class::THRESHOLD.times { described_class.trip!(key) }

    expect(described_class.open?("rss:other.test")).to be(false)
  end
end
