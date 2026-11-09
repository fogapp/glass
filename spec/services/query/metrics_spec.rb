# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Query::Metrics do
  let(:household) { create_household }
  let(:hook) { create_app(household: household, slug: "hook") }
  let(:now) { Time.now.utc.change(min: 0, sec: 0) }
  let(:context) { Query::Context.new(household) }

  def point(name, kind, at, tags: {}, n: 1, sum: 1.0, min: nil, max: nil, last: nil, sk: nil)
    { t: "metric", ts: at.to_i, name: name, kind: kind, tags: tags, n: n, sum: sum, min: min || sum, max: max || sum, last: last || sum, sk: sk }.compact
  end

  def run(params)
    Query::Runner.run(Query::Request.from_params({ "source" => "metrics", "from" => (now - 30.minutes).to_f, "to" => now.to_f, "step" => 600 }.merge(params)), context)
  end

  before do
    write_batch(hook, [
      point("reqs", "counter", now - 25.minutes, tags: { c: "a" }, n: 5, sum: 5),
      point("reqs", "counter", now - 15.minutes, tags: { c: "a" }, n: 3, sum: 3),
      point("reqs", "counter", now - 15.minutes, tags: { c: "b" }, n: 2, sum: 2),
      point("rss", "gauge", now - 25.minutes, tags: { process: "web" }, sum: 100, last: 100),
      point("rss", "gauge", now - 25.minutes, tags: { process: "worker" }, sum: 40, last: 40),
      point("lat", "dist", now - 5.minutes, n: 3, sum: 90, min: 20, max: 40, sk: [ 152, 1, 172, 1, 187, 1 ])
    ])
  end

  it "sums a counter over time, by tag, defaulting to sum" do
    result = run("metric" => "reqs", "shape" => "timeseries", "group_by" => [ "c" ])
    expect(result[:series].map { |s| [ s[:group], s[:values] ] }).to eq([
      [ { "c" => "a" }, [ 5.0, 3.0, 0.0 ] ], [ { "c" => "b" }, [ 0.0, 2.0, 0.0 ] ]
    ])
    expect(run("metric" => "reqs", "shape" => "timeseries", "compute" => [ "rate" ])[:series].first[:values].first).to be_within(0.001).of(5.0 / 600)
    expect(run("metric" => "reqs", "shape" => "timeseries")).not_to have_key(:apps)
    expect(run("metric" => "reqs", "shape" => "timeseries", "filter" => "app:hook")[:apps]).to eq([ "hook" ])
  end

  it "adds gauges across series but averages within them" do
    result = run("metric" => "rss", "shape" => "table", "compute" => [ "sum", "avg", "max" ])
    expect(result[:rows]).to eq([ { "sum" => 140.0, "avg" => 70.0, "max" => 100.0 } ])
  end

  it "ranks a gauge's groups by their level, not by how often they were sampled" do
    write_batch(hook, [
      point("conns", "gauge", now - 25.minutes, tags: { db: "big" }, n: 1, sum: 100),
      point("conns", "gauge", now - 25.minutes, tags: { db: "chatty" }, n: 60, sum: 600)
    ])
    result = run("metric" => "conns", "shape" => "timeseries", "group_by" => [ "db" ], "limit" => 1)
    expect(result[:series].map { |s| s[:group] }).to eq([ { "db" => "big" } ])
  end

  it "reads percentiles from merged sketches and refuses them elsewhere" do
    result = run("metric" => "lat", "shape" => "table", "compute" => [ "p50", "count", "avg" ])
    expect(result[:rows].first["p50"]).to be_within(1).of(30)
    expect(result[:rows].first["count"]).to eq(3.0)
    expect(result[:rows].first["avg"]).to eq(30.0)
    expect { run("metric" => "reqs", "shape" => "table", "compute" => [ "p95" ]) }.to raise_error(Query::Invalid, /no percentiles/)
  end

  it "filters by tag and app" do
    expect(run("metric" => "reqs", "shape" => "table", "filter" => "c:b")[:rows]).to eq([ { "sum" => 2.0 } ])
    expect(run("metric" => "reqs", "shape" => "table", "filter" => "app:hub")[:rows]).to eq([])
    expect { run("metric" => "reqs", "shape" => "table", "filter" => "c:>1") }.to raise_error(Query::Invalid, /Tags are text/)
  end

  it "keeps reading the raw tier past a rollup checkpoint" do
    Telemetry::Rollup.run!(now: now)
    Telemetry::Cursor.advance!("rollup:5m", now - 20.minutes)
    result = run("metric" => "reqs", "shape" => "table", "from" => (now - 2.days).to_f)
    expect(result[:rows]).to eq([ { "sum" => 10.0 } ])
  end
end
