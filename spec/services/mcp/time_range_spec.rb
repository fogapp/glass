# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Mcp::TimeRange do
  let(:now) { Time.utc(2026, 9, 30, 12, 0, 0) }

  def resolve(from: nil, to: nil, **rest) = described_class.resolve(from: from, to: to, now: now, **rest)

  it "defaults to the hour before now, or the span a tool asks for" do
    expect(resolve).to eq([ now - 3600, now ])
    expect(resolve(default: 15.minutes)).to eq([ now - 900, now ])
    expect(resolve(to: "-1h")).to eq([ now - 7200, now - 3600 ])
  end

  it "reads relative times in every unit" do
    expect(resolve(from: "-90s").first).to eq(now - 90)
    expect(resolve(from: "-15m").first).to eq(now - 900)
    expect(resolve(from: "now-2h", to: "now")).to eq([ now - 7200, now ])
    expect(resolve(from: "-7d").first).to eq(now - 7.days)
    expect(resolve(from: "-1.5h").first).to eq(now - 5400)
    expect(resolve(from: " -2W ").first).to eq(now - 14.days)
  end

  it "reads ISO 8601 — UTC unless it says otherwise — and Unix seconds" do
    expect(resolve(from: "2026-09-30T03:00:00Z").first).to eq(Time.utc(2026, 9, 30, 3))
    expect(resolve(from: "2026-09-30T03:00:00").first).to eq(Time.utc(2026, 9, 30, 3))
    expect(resolve(from: "2026-09-30T03:00:00-07:00").first).to eq(Time.utc(2026, 9, 30, 10))
    expect(resolve(from: "2026-09-29").first).to eq(Time.utc(2026, 9, 29))
    expect(resolve(from: now.to_i - 60).first).to eq(now - 60)
    expect(resolve(from: (now.to_f - 60).to_s).first).to eq(now - 60)
  end

  it "refuses what is not a time, and a range that ends before it starts" do
    expect { resolve(from: "yesterday") }.to raise_error(Query::Invalid, /“from” is not a time: "yesterday"/)
    expect { resolve(to: "15m") }.to raise_error(Query::Invalid, /“to” is not a time/)
    expect { resolve(from: true) }.to raise_error(Query::Invalid, /“from” is not a time/)
    expect { resolve(from: "-1h", to: "-2h") }.to raise_error(Query::Invalid, /ends before it starts/)
  end

  it "refuses a range wider than the most a tool allows" do
    expect(resolve(from: "-2d", max: 2.days)).to eq([ now - 2.days, now ])
    expect { resolve(from: "-3d", max: 2.days) }.to raise_error(Query::Invalid, /wider than 2 days/)
  end
end
