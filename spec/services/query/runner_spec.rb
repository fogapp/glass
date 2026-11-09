# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Query::Runner do
  let(:household) { create_household }
  let(:hook) { create_app(household: household, slug: "hook") }
  let(:hub) { create_app(household: household, slug: "hub") }
  let(:now) { Time.now.utc.change(min: 0, sec: 0) }
  let(:context) { Query::Context.new(household) }

  def txn(name:, dur:, at:, status: "ok", **fields)
    wire_txn(at: at, name: name, dur: dur, status: status, http: status == "ok" ? 200 : 500, error: status == "ok" ? nil : "Boom",
      db_ms: dur / 4.0, db_n: 2, **{ attrs: {}, kept: true }.merge(fields))
  end

  before do
    write_batch(hook, [
      txn(name: "A#index", dur: 100, at: now - 30.minutes, user: "u1"),
      txn(name: "A#index", dur: 300, at: now - 20.minutes, user: "u2", attrs: { want_id: "w1" }),
      txn(name: "A#index", dur: 500, at: now - 10.minutes, status: "error", user: "u1"),
      txn(name: "B#show", dur: 20, at: now - 9.minutes),
      txn(name: "SyncJob", dur: 2000, at: now - 5.minutes, kind: "job")
    ])
    write_batch(hub, [ txn(name: "C#index", dur: 50, at: now - 15.minutes) ])
  end

  def run(params)
    described_class.run(Query::Request.from_params({ "from" => (now - 1.hour).to_f, "to" => now.to_f }.merge(params)), context)
  end

  it "answers a table grouped by a field, ranked by the first compute" do
    result = run("source" => "transactions", "shape" => "table", "compute" => [ "count", "p95(duration)", "error_rate", "uniq(user)" ], "group_by" => [ "name" ])
    expect(result[:columns].map { |c| c[:key] }).to eq(%w[name count p95(duration) error_rate uniq(user)])
    first = result[:rows].first
    expect(first["name"]).to eq("A#index")
    expect(first["count"]).to eq(3.0)
    expect(first["p95(duration)"]).to be_within(1).of(480)
    expect(first["error_rate"]).to be_within(0.01).of(1 / 3.0)
    expect(first["uniq(user)"]).to eq(2.0)
    expect(result[:rows].map { |r| r["name"] }).to eq([ "A#index", "B#show", "C#index", "SyncJob" ])
    expect(run("source" => "transactions", "shape" => "table", "compute" => [ "sum(duration)" ], "filter" => "app:nope")[:rows]).to eq([ { "sum(duration)" => 0.0 } ])
  end

  it "groups by app as slugs and filters by app" do
    result = run("source" => "transactions", "shape" => "table", "compute" => [ "count" ], "group_by" => [ "app" ])
    expect(result[:rows]).to eq([ { "app" => "hook", "count" => 5.0 }, { "app" => "hub", "count" => 1.0 } ])
    expect(run("source" => "transactions", "shape" => "table", "filter" => "app:hub")[:rows]).to eq([ { "count" => 1.0 } ])
    expect(run("source" => "transactions", "shape" => "table", "filter" => "app:nope")[:rows]).to eq([ { "count" => 0.0 } ])
  end

  it "applies every kind of filter term" do
    count = ->(filter) { run("source" => "transactions", "shape" => "table", "filter" => filter)[:rows].first["count"] }
    expect(count.call("status:error")).to eq(1.0)
    expect(count.call("-status:error")).to eq(5.0)
    expect(count.call("duration:>250ms")).to eq(3.0)
    expect(count.call("duration:100..300")).to eq(2.0)
    expect(count.call("http_status:5xx")).to eq(1.0)
    expect(count.call("name:A*")).to eq(3.0)
    expect(count.call("name:A#index,B#show")).to eq(4.0)
    expect(count.call("kind:job")).to eq(1.0)
    expect(count.call("error:*")).to eq(1.0)
    expect(count.call("-error:*")).to eq(5.0)
    expect(count.call("@want_id:w1")).to eq(1.0)
    expect(count.call("@want_id:*")).to eq(1.0)
    expect(count.call("kept:true")).to eq(6.0)
    expect(count.call('"A#in"')).to eq(3.0)
  end

  it "says which apps it read when its filter confined it, so its chart draws only their markers" do
    create_app(household: household, slug: "feed")
    timeseries = ->(filter) { run("source" => "transactions", "shape" => "timeseries", "filter" => filter) }
    expect(timeseries.call("")).not_to have_key(:apps)
    expect(timeseries.call("status:error")).not_to have_key(:apps)
    expect(timeseries.call("app:hook")[:apps]).to eq([ "hook" ])
    expect(timeseries.call("app:hook,hub -app:hub")[:apps]).to eq([ "hook" ])
    expect(timeseries.call("-app:hook")[:apps]).to eq(%w[feed hub])
    expect(timeseries.call("app:gone")[:apps]).to eq([])
    expect(run("source" => "transactions", "shape" => "table", "filter" => "app:hub")[:apps]).to eq([ "hub" ])
  end

  it "draws a timeseries with zero-filled counts, nulls for percentiles, and only the top groups" do
    result = run("source" => "transactions", "shape" => "timeseries", "compute" => [ "count", "p95(duration)" ], "group_by" => [ "name" ], "limit" => 1, "step" => 600)
    expect(result[:step]).to eq(600)
    expect(result[:times].size).to eq(6)
    expect(result[:series].map { |s| s[:key] }).to eq([ "count", "p95(duration)" ])
    expect(result[:series].first[:group]).to eq("name" => "A#index")
    expect(result[:series].first[:values]).to eq([ 0.0, 0.0, 0.0, 1.0, 1.0, 1.0 ])
    expect(result[:series].last[:values].first(3)).to eq([ nil, nil, nil ])
  end

  it "lists rows newest first, with a cursor, and ranked when asked" do
    result = run("source" => "transactions", "shape" => "list", "filter" => "app:hook", "limit" => 2)
    expect(result[:rows].map { |r| r["name"] }).to eq([ "SyncJob", "B#show" ])
    expect(result[:next_before]).to be_a(Float)
    older = run("source" => "transactions", "shape" => "list", "filter" => "app:hook", "limit" => 10, "before" => result[:next_before])
    expect(older[:rows].size).to eq(3)
    expect(older[:rows].first["trace"]).to match(/\A[0-9a-f]{32}\z/)
    expect(older[:rows].first["app"]).to eq("hook")

    slowest = run("source" => "transactions", "shape" => "list", "order" => "-duration", "limit" => 1)
    expect(slowest[:rows].first["name"]).to eq("SyncJob")
    expect(slowest[:next_before]).to be_nil
  end

  it "lists rows from every source" do
    Query::Sources::ALL.each do |source|
      expect(run("source" => source.name, "shape" => "list", "limit" => 1)).to include(shape: "list"), source.name
    end
  end

  it "reads a visitor event's props as its attributes" do
    write_batch(hook, [ { t: "page", ts: (now - 5.minutes).to_f, kind: "custom", visit: "v1", name: "Signed up", props: { plan: "pro" } } ])
    rows = run("source" => "page_events", "shape" => "list", "filter" => "@plan:pro")[:rows]
    expect(rows.map { |r| [ r["name"], r["attrs"] ] }).to eq([ [ "Signed up", { "plan" => "pro" } ] ])
  end

  it "buckets a heatmap and a histogram on a log scale" do
    heat = run("source" => "transactions", "shape" => "heatmap", "step" => 600)
    expect(heat[:edges].size).to eq(Query::Runner::HEATMAP_BUCKETS + 1)
    expect(heat[:cells].sum { |(_, _, n)| n }).to eq(6.0)
    hist = run("source" => "transactions", "shape" => "histogram", "field" => "db")
    expect(hist[:counts].sum).to eq(6.0)
    expect(hist[:edges].first).to be < hist[:edges].last
  end

  it "reads a heatmap or a histogram in one statement, counting by the edges it answers" do
    statements = ->(params) { count_queries(matching: /FROM transactions/) { run(params) }.grep_v(/\ASET LOCAL/) }
    expect(statements.call("source" => "transactions", "shape" => "heatmap", "step" => 600).size).to eq(1)
    expect(statements.call("source" => "transactions", "shape" => "histogram").size).to eq(1)

    hist = run("source" => "transactions", "shape" => "histogram")
    edges = hist[:edges]
    expect(edges.first).to be_within(1e-9).of(20.0)
    expect(edges.last).to be_within(1e-9).of(2000.0)
    expected = Array.new(Query::Runner::HISTOGRAM_BUCKETS, 0.0)
    [ 100, 300, 500, 20, 2000, 50 ].each do |value|
      slot = (edges.rindex { |edge| edge <= value } || 0).clamp(0, Query::Runner::HISTOGRAM_BUCKETS - 1)
      expected[slot] += 1
    end
    expect(hist[:counts]).to eq(expected)
  end

  it "answers no edges when there is nothing positive to scale" do
    hist = run("source" => "transactions", "shape" => "histogram", "filter" => "name:Nothing")
    expect(hist).to include(edges: [], counts: [])
    heat = run("source" => "transactions", "shape" => "heatmap", "filter" => "name:Nothing")
    expect(heat).to include(edges: [], cells: [])
  end

  it "explains what it cannot do" do
    expect { run("source" => "transactions", "shape" => "table", "filter" => "nme:x") }.to raise_error(Query::Invalid, /did you mean “name”/)
    expect { run("source" => "transactions", "shape" => "table", "filter" => "duration:fast") }.to raise_error(Query::Invalid, /is a number/)
    expect { run("source" => "transactions", "shape" => "table", "order" => "-nothing") }.to raise_error(Query::Invalid, /Cannot order/)
    expect { run("source" => "profiles", "shape" => "table", "filter" => "@x:1") }.to raise_error(Query::Invalid, /no attributes/)
    expect { run("source" => "nope", "shape" => "table") }.to raise_error(Query::Invalid, /Unknown source/)
    expect { run("source" => "transactions", "shape" => "pie") }.to raise_error(Query::Invalid, /Unknown shape/)
    expect { run("source" => "transactions", "shape" => "table", "from" => now.to_f, "to" => (now - 1).to_f) }.to raise_error(Query::Invalid, /ends before/)
  end

  it "never sees another household's apps" do
    other = Query::Context.new(create_household(name: "Other"))
    result = described_class.run(Query::Request.from_params("source" => "transactions", "shape" => "table", "from" => (now - 1.hour).to_f, "to" => now.to_f), other)
    expect(result[:rows]).to eq([ { "count" => 0.0 } ])
  end
end
