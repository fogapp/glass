# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Query::Filter do
  def term(text) = described_class.parse(text).first

  it "reads key:value terms, lists, negation and comparators" do
    expect(term("status:error")).to have_attributes(key: "status", op: "eq", values: [ "error" ], negated: false)
    expect(term("-status:ok,error")).to have_attributes(key: "status", op: "eq", values: %w[ok error], negated: true)
    expect(term("duration:>250ms")).to have_attributes(key: "duration", op: "gt", values: [ "250ms" ])
    expect(term("http_status:>=500")).to have_attributes(op: "gte", values: [ "500" ])
    expect(term("duration:10..20")).to have_attributes(op: "range", values: %w[10 20])
    expect(term("duration:1.5s..2s")).to have_attributes(op: "range", values: %w[1.5s 2s])
    expect(term("error:*")).to have_attributes(op: "present", values: [])
    expect(term("@want_id:abc")).to have_attributes(key: "@want_id", values: [ "abc" ])
  end

  it "keeps quoted values whole, with escapes" do
    terms = described_class.parse('name:"Api::V1::WantsController#index" "connection timed out" -"noise here" status:"a,b"')
    expect(terms.map(&:values)).to eq([ [ "Api::V1::WantsController#index" ], [ "connection timed out" ], [ "noise here" ], [ "a,b" ] ])
    expect(terms[1]).to have_attributes(key: nil, negated: false)
    expect(terms[2]).to have_attributes(key: nil, negated: true)
    expect(described_class.parse('msg:"say \\"hi\\""').first.values).to eq([ 'say "hi"' ])
  end

  it "reads a list of quoted values whose quotes and commas are escaped" do
    values = [ 'said "no", twice', "a,b", 'odd " quote', "back\\slash", "plain" ]
    expect(term(Query::Filter.quote_any("message", values)).values).to eq(values)
    expect(term(Query::Filter.quote("message", 'odd " quote, and a comma')).values).to eq([ 'odd " quote, and a comma' ])
  end

  it "quotes a value so parsing reads it back whole" do
    values = [ 'said "no", twice', "a,b", 'odd " quote', "back\\slash", "trailing\\", "two words", "key:value" ]
    values.each do |value|
      expect(described_class.parse(described_class.quote("message", value)).map(&:values)).to eq([ [ value ] ])
    end
    expect(term(described_class.quote_any("name", values.first(5))).values).to eq(values.first(5))
    expect(term(described_class.quote("@want_id", "a b"))).to have_attributes(key: "@want_id", op: "eq", values: [ "a b" ])
  end

  it "refuses what it cannot read" do
    expect { described_class.parse('name:"unclosed') }.to raise_error(Query::Invalid, /Unclosed quote/)
    expect { described_class.parse("status:") }.to raise_error(Query::Invalid, /needs a value/)
    expect { described_class.parse((1..41).map { |i| "k#{i}:v" }.join(" ")) }.to raise_error(Query::Invalid, /at most 40/)
  end

  it "answers nothing for blank text" do
    expect(described_class.parse(nil)).to eq([])
    expect(described_class.parse("   ")).to eq([])
  end
end
