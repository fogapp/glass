# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Profiles::Flamegraph do
  let(:household) { create_household }
  let(:hook) { create_app(household: household, slug: "hook") }
  let(:now) { Time.now.utc }
  let(:context) { Query::Context.new(household) }

  def window(at, samples)
    { t: "profile", ts: at.to_f, dur: 60.0, hz: 100,
      funcs: [ [ "main", "app.rb", 1, "app" ], [ "serialize", "app/s.rb", 5, "app" ], [ "IO#read", "<cfunc>", 0, "native" ] ],
      stacks: [ [ 0, 1 ], [ 0, 1, 2 ], [ 0, 2 ] ], samples: samples }
  end

  before do
    write_batch(hook, [
      window(now - 10.minutes, [ [ 0, "A#index", "running", 60 ], [ 1, "A#index", "idle", 30 ], [ 2, nil, "running", 10 ] ]),
      window(now - 2.hours, [ [ 0, "A#index", "running", 20 ], [ 2, nil, "running", 10 ] ])
    ])
  end

  it "merges stacks into one preorder tree with self and total time" do
    graph = described_class.new(context: context, range: described_class::Range.new(from: now - 1.hour, to: now, filter: "app:hook")).build
    expect(graph[:total_ms]).to eq(1000.0)
    expect(graph[:samples]).to eq([ 100 ])
    names = graph[:functions].map { |f| f[:name] }
    root, main, serialize, io = graph[:nodes].first(4)
    expect(names[root[0]]).to eq("all")
    expect(names[main[0]]).to eq("main")
    expect(main[1]).to eq(0)
    expect(main[3]).to eq(1000.0)
    expect(main[2]).to eq(0.0)
    expect(names[serialize[0]]).to eq("serialize")
    expect(serialize[2..3]).to eq([ 600.0, 900.0 ])
    expect(names[io[0]]).to eq("IO#read")
    expect(io[1]).to eq(2)
    expect(io[2..3]).to eq([ 300.0, 300.0 ])
  end

  it "filters by transaction and state" do
    graph = described_class.new(context: context, range: described_class::Range.new(from: now - 1.hour, to: now, filter: 'transaction:"A#index" state:running')).build
    expect(graph[:total_ms]).to eq(600.0)
  end

  it "carries both sides of a diff" do
    graph = described_class.new(
      context: context,
      range: described_class::Range.new(from: now - 1.hour, to: now, filter: "app:hook"),
      baseline: described_class::Range.new(from: now - 3.hours, to: now - 1.hour, filter: "app:hook")
    ).build
    expect(graph[:diff]).to be(true)
    expect(graph[:baseline_total_ms]).to eq(300.0)
    expect(graph[:nodes].first.size).to eq(6)
  end

  it "reads each range's samples once" do
    range = described_class::Range.new(from: now - 1.hour, to: now, filter: "app:hook")
    baseline = described_class::Range.new(from: now - 3.hours, to: now - 1.hour, filter: "app:hook")
    expect(count_queries(matching: /profile_samples/) { described_class.new(context: context, range: range).build }.size).to eq(1)
    expect(count_queries(matching: /profile_samples/) do
      expect(described_class.new(context: context, range: range, baseline: baseline).build[:samples]).to eq([ 100, 30 ])
    end.size).to eq(2)
  end

  it "folds the stacks past the limit into (other) with the rest of the time" do
    stub_const("Profiles::Flamegraph::MAX_STACKS", 1)
    graph = described_class.new(context: context, range: described_class::Range.new(from: now - 1.hour, to: now, filter: "app:hook")).build
    expect(graph[:total_ms]).to eq(1000.0)
    expect(graph[:samples]).to eq([ 100 ])
    other = graph[:functions].index { |f| f[:name] == "(other)" }
    expect(graph[:nodes].find { |node| node[0] == other && node[1].zero? }[2..3]).to eq([ 400.0, 400.0 ])
  end
end
