# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Query::Bounds do
  let(:now) { Time.utc(2026, 9, 30, 12, 0, 0) }

  def parse(value, name = "from") = described_class.parse(value, name, now)

  it "reads Unix seconds, as a number or as the console's query string, ISO 8601, relative times and now" do
    expect(parse(1_790_737_200)).to eq(Time.at(1_790_737_200).utc)
    expect(parse("1790737200.5")).to eq(Time.at(1_790_737_200.5).utc)
    expect(parse("2026-09-30T03:00:00Z")).to eq(Time.utc(2026, 9, 30, 3))
    expect(parse("2026-09-30T03:00:00")).to eq(Time.utc(2026, 9, 30, 3))
    expect(parse("-15m")).to eq(now - 900)
    expect(parse("NOW")).to eq(now)
  end

  it "names the parameter it cannot read, and the one that is missing" do
    expect { parse("yesterday", "to") }.to raise_error(Query::Invalid, /“to” is not a time: "yesterday"/)
    expect { parse("0") }.to raise_error(Query::Invalid, /“from” is not a time/)
    expect { parse([]) }.to raise_error(Query::Invalid, /“from” is not a time/)
    expect { parse(nil, "before") }.to raise_error(Query::Invalid, /“before” is required/)
  end

  it "resolves a range from a default, or requires both bounds without one" do
    expect(described_class.resolve(from: nil, to: nil, default: 1.day, now: now)).to eq([ now - 1.day, now ])
    expect(described_class.resolve(from: "-2h", to: nil, default: 1.day, now: now)).to eq([ now - 2.hours, now ])
    expect { described_class.resolve(from: "-2h", to: nil, now: now) }.to raise_error(Query::Invalid, /“to” is required/)
  end

  it "refuses a range that ends before it starts or is wider than the most allowed" do
    expect { described_class.check!(now, now) }.to raise_error(Query::Invalid, /ends before it starts/)
    expect { described_class.check!(now - 3.days, now, max: 2.days) }.to raise_error(Query::Invalid, /wider than 2 days/)
    expect { described_class.check!(now - 2.days, now, max: 2.days) }.not_to raise_error
  end
end
