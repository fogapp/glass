# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Profiles::TopFunctions do
  # all → a → b → a → c: `a` recurses, so its total is counted once.
  let(:graph) do
    {
      total_ms: 100.0,
      functions: [
        { name: "all", file: "", line: 0, category: "root" }, { name: "a", file: "a.rb", line: 1, category: "app" },
        { name: "b", file: "b.rb", line: 2, category: "gem" }, { name: "c", file: "c.rb", line: 3, category: "native" },
        { name: "(other)", file: "", line: 0, category: "other" }
      ],
      nodes: [
        [ 0, -1, 0.0, 100.0 ],
        [ 1, 0, 10.0, 90.0 ], [ 2, 1, 20.0, 80.0 ], [ 1, 2, 5.0, 60.0 ], [ 3, 3, 55.0, 55.0 ],
        [ 3, 0, 8.0, 8.0 ],
        [ 4, 0, 2.0, 2.0 ]
      ]
    }
  end

  it "sums self time per function and counts a recursing function's total once" do
    rows = described_class.rank(graph, limit: 10)
    expect(rows.map { |row| row[:name] }).to eq(%w[c b a])
    expect(rows.first).to include(self_ms: 63.0, total_ms: 63.0, self_share: 0.63, file: "c.rb", line: 3, category: "native")
    expect(rows.last).to include(self_ms: 15.0, total_ms: 90.0, total_share: 0.9)
  end

  it "ranks by total and cuts at the limit" do
    rows = described_class.rank(graph, limit: 2, order: described_class::Order::Total)
    expect(rows.map { |row| row[:name] }).to eq(%w[a b])
  end

  it "answers nothing for an empty profile" do
    empty = { total_ms: 0.0, functions: graph[:functions].values_at(0, 4), nodes: [ [ 0, -1, 0.0, 0.0 ] ] }
    expect(described_class.rank(empty, limit: 10)).to eq([])
  end
end
