# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Traces::Lookup do
  let(:household) { create_household }
  let(:hook) { create_app(household: household, slug: "hook") }
  let(:context) { Query::Context.new(household) }
  let(:now) { Time.now.utc }
  let(:trace) { SecureRandom.hex(16) }

  before do
    write_batch(hook, [
      wire_txn(at: now - 30.minutes, trace: trace, dur: 2_000.0),
      wire_span(trace: trace, at: now - 30.minutes + 1, name: "inside"),
      # Under the margin past the transaction's end: a host's clock ahead.
      wire_span(trace: trace, at: now - 30.minutes + 2 + 50, name: "skewed"),
      # Long after anything in the trace ended.
      wire_span(trace: trace, at: now - 10.minutes, name: "stray")
    ])
  end

  it "reads spans only around the trace's transactions, under the statement timeout" do
    found = nil
    queries = count_queries { found = described_class.call(id: trace, context: context) }

    expect(found.spans.map(&:name)).to eq(%w[inside skewed])
    timeout = queries.index { |sql| sql.include?("SET LOCAL statement_timeout = #{Query::Runner::TIMEOUT_MS}") }
    expect(timeout).to be < queries.index { |sql| sql.include?('FROM "transactions"') }
    expect(queries.grep(/FROM "(spans|model_calls)"/).size).to eq(2)
    expect(queries.grep(/FROM "(spans|model_calls)"/)).to all(match(/"ts" BETWEEN/))
  end

  it "keeps only the lower bound when the transactions were cut short" do
    stub_const("#{described_class}::MAX_TRANSACTIONS", 1)
    queries = count_queries { expect(described_class.call(id: trace, context: context).spans.size).to eq(3) }
    expect(queries.grep(/FROM "spans"/)).to all(match(/"ts" >=/))
  end
end
