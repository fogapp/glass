# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe BatchedDelete do
  it "runs until a batch comes back short, handing each the limit, and sums the counts" do
    counts = [ 3, 3, 1, 3 ]
    limits = []
    total = described_class.run(batch: 3, max_batches: 10) { |limit| limits << limit; counts.shift }
    expect(total).to eq(7)
    expect(limits).to eq([ 3, 3, 3 ])
  end

  it "stops at the cap however much is left" do
    calls = 0
    total = described_class.run(batch: 2, max_batches: 4) { calls += 1; 2 }
    expect([ calls, total ]).to eq([ 4, 8 ])
  end
end
