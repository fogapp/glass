# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Query::Compute do
  let(:source) { Query::Sources::TRANSACTIONS }

  it "parses a function with and without a field" do
    expect(described_class.parse("count")).to have_attributes(fn: "count", arg: nil, key: "count")
    expect(described_class.parse("P95(Duration)")).to have_attributes(fn: "p95", arg: "duration", key: "p95(duration)")
    expect(described_class.parse("apdex(250)")).to have_attributes(fn: "apdex", arg: "250")
  end

  it "compiles each function to SQL over the source's columns" do
    expect(described_class.parse("count").sql(source, seconds: 60.0)).to eq("coalesce(sum(weight), 0)::float8")
    expect(described_class.parse("rate").sql(source, seconds: 60.0)).to include("/ 60.0")
    expect(described_class.parse("p95(duration)").sql(source, seconds: 1.0)).to include("percentile_cont(0.95) WITHIN GROUP (ORDER BY duration_ms)")
    expect(described_class.parse("avg(db)").sql(source, seconds: 1.0)).to include("sum(db_ms * weight)")
    expect(described_class.parse("uniq(user)").sql(source, seconds: 1.0)).to eq("count(DISTINCT user_ref)::float8")
    expect(described_class.parse("error_rate").sql(source, seconds: 1.0)).to include("status = 'error'")
    expect(described_class.parse("apdex").sql(source, seconds: 1.0)).to include("duration_ms <= 500.0")
    expect(described_class.parse("apdex(2000, active)").sql(source, seconds: 1.0)).to include("greatest(duration_ms - wait_ms, 0) <= 2000.0")
    expect(described_class.parse("ratio(cache_read, input_total)").sql(source, seconds: 1.0)).to eq(
      "(sum(tokens_cache_read * weight)::float8 / nullif(sum((tokens_in + tokens_cache_read + tokens_cache_write) * weight)::float8, 0))"
    )
  end

  it "says what unit an answer is in" do
    expect(described_class.parse("sum(cost)").unit(source)).to eq("usd")
    expect(described_class.parse("avg(tokens_in)").unit(source)).to eq("tokens")
    expect(described_class.parse("ratio(cache_read, input_total)").unit(source)).to eq("ratio")
  end

  it "refuses what the source cannot answer, in words" do
    expect { described_class.parse("p95(name)").sql(source, seconds: 1.0) }.to raise_error(Query::Invalid, /not a number/)
    expect { described_class.parse("sum").sql(source, seconds: 1.0) }.to raise_error(Query::Invalid, /needs a field/)
    expect { described_class.parse("median(duration)").sql(source, seconds: 1.0) }.to raise_error(Query::Invalid, /Unknown function/)
    expect { described_class.parse("apdex(-1)").sql(source, seconds: 1.0) }.to raise_error(Query::Invalid, /threshold/)
    expect { described_class.parse("ratio(cost)").sql(source, seconds: 1.0) }.to raise_error(Query::Invalid, /two numbers/)
    expect { described_class.parse("ratio(cost, name)").sql(source, seconds: 1.0) }.to raise_error(Query::Invalid, /not a number/)
    expect { described_class.parse("error_rate").sql(Query::Sources::PROFILES, seconds: 1.0) }.to raise_error(Query::Invalid, /status/)
    expect { described_class.parse("weird!") }.to raise_error(Query::Invalid, /Cannot read/)
  end

  it "knows which answers are zero when nothing happened" do
    expect(described_class.parse("count")).to be_zero_when_empty
    expect(described_class.parse("p95(duration)")).not_to be_zero_when_empty
  end
end
