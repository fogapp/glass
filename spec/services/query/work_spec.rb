# typed: false
# frozen_string_literal: true

require "rails_helper"

# Units of work as a spine with facets (Telemetry::Work), and the model
# calls made under them, through the one read path.
RSpec.describe "Querying runs and model calls" do
  let(:household) { create_household }
  let(:aio) { create_app(household: household, slug: "aio") }
  let(:hook) { create_app(household: household, slug: "hook") }
  let(:now) { Time.now.utc.change(min: 0, sec: 0) }
  let(:context) { Query::Context.new(household) }

  before do
    write_batch(aio, [
      wire_run(at: now - 30.minutes, dur: 10_000, queue_ms: 500, prep_ms: 500, model_ms: 6000, tool_ms: 2000, deliver_ms: 500,
        tok_in: 100, tok_cache_read: 900, tok_out: 200, cost: 0.02, ttft_ms: 9500),
      wire_run(at: now - 20.minutes, dur: 40_000, model_ms: 5000, tool_ms: 4000, wait_ms: 30_000,
        tok_in: 1000, tok_cache_read: 0, tok_out: 300, cost: 0.08, channel: "console", ttft_ms: 1200, stall_ms: 30_000),
      wire_llm(at: now - 30.minutes),
      wire_llm(at: now - 29.minutes, in: 1000, cache_read: 0, cost: 0.03, dur: 3000.0, ttft: 1500.0),
      wire_llm(at: now - 28.minutes, provider: "local", model: "qwen3:8b", purpose: "reviewer", origin: "internal", cost: 0, cache_read: 0,
        in: 400, out: 10, dur: 600.0, status: "error", error: "timeout")
    ], kind: "gateway")
    write_batch(hook, [
      wire_txn(at: now - 10.minutes, dur: 100, status: nil, db_ms: 30, view_ms: 10, ext_ms: 20, http: 200)
    ])
  end

  def run(params)
    Query::Runner.run(Query::Request.from_params({ "from" => (now - 1.hour).to_f, "to" => now.to_f, "shape" => "table" }.merge(params)), context)
  end

  def one(params) = run(params)[:rows].first

  it "sums what runs spent, and takes a ratio of sums rather than a mean of ratios" do
    row = one("source" => "transactions", "filter" => "kind:run",
      "compute" => [ "count", "sum(cost)", "sum(tokens_in)", "ratio(cache_read, input_total)", "avg(rounds)" ])
    expect(row["count"]).to eq(2.0)
    expect(row["sum(cost)"]).to be_within(1e-9).of(0.10)
    expect(row["sum(tokens_in)"]).to eq(1100.0)
    # 900 cached of 2000 input in all — not the mean of 0.9 and 0.
    expect(row["ratio(cache_read, input_total)"]).to be_within(1e-9).of(0.45)
  end

  it "accounts for a run's time by phase, and names what is left over" do
    rows = run("source" => "transactions", "filter" => "kind:run", "group_by" => [ "channel" ],
      "compute" => [ "avg(untracked)", "avg(active)", "avg(wait)", "p95(ttft)" ], "order" => "channel")[:rows]
    console, telegram = rows
    # 10 s, of which 9.5 s is in phases.
    expect(telegram).to include("channel" => "telegram", "avg(untracked)" => 500.0, "avg(active)" => 10_000.0, "avg(wait)" => 0.0)
    # 40 s, of which 30 s was a person deciding: 10 s active, 1 s untracked.
    expect(console).to include("channel" => "console", "avg(untracked)" => 1000.0, "avg(active)" => 10_000.0, "avg(wait)" => 30_000.0)
  end

  it "keeps a request's remainder what it always was" do
    row = one("source" => "transactions", "filter" => "kind:request", "compute" => [ "avg(app_time)", "avg(untracked)", "avg(active)" ])
    expect(row).to eq("avg(app_time)" => 40.0, "avg(untracked)" => 40.0, "avg(active)" => 100.0)
  end

  it "scores a run by its active time when asked" do
    row = one("source" => "transactions", "filter" => "kind:run", "compute" => [ "apdex(15000)", "apdex(15000, active)" ])
    expect(row).to eq("apdex(15000)" => 0.75, "apdex(15000, active)" => 1.0)
  end

  it "filters and groups runs by their own fields" do
    expect(one("source" => "transactions", "filter" => "agent:owner-chat channel:console stall:>10s")["count"]).to eq(1.0)
    expect(one("source" => "transactions", "filter" => "session:ses_1")["count"]).to eq(2.0)
    expect(one("source" => "transactions", "filter" => "cost:>0.05")["count"]).to eq(1.0)
  end

  it "reads model calls: spend by purpose, latency by model, and a list" do
    spend = run("source" => "model_calls", "group_by" => [ "purpose" ], "compute" => [ "sum(cost)", "count", "error_rate" ])[:rows]
    expect(spend).to eq([
      { "purpose" => "turn", "sum(cost)" => 0.04, "count" => 2.0, "error_rate" => 0.0 },
      { "purpose" => "reviewer", "sum(cost)" => 0.0, "count" => 1.0, "error_rate" => 1.0 }
    ])
    # One failure in three, on a source whose rows all count for one.
    expect(one("source" => "model_calls", "compute" => [ "error_rate" ])["error_rate"]).to be_within(1e-9).of(1 / 3.0)
    by_model = one("source" => "model_calls", "filter" => "model:claude*", "compute" => [ "p95(ttft)", "ratio(cache_read, input_total)", "avg(tokens_per_s)" ])
    expect(by_model["p95(ttft)"]).to be_within(1).of(1450)
    expect(by_model["ratio(cache_read, input_total)"]).to be_within(1e-9).of(0.45)
    # 200 tokens over (1000 − 500) ms and over (3000 − 1500) ms.
    expect(by_model["avg(tokens_per_s)"]).to be_within(0.01).of((400 + 133.333) / 2)

    # A whole-number column over a whole-number count is still a mean.
    expect(one("source" => "model_calls", "compute" => [ "avg(tokens_out)" ])["avg(tokens_out)"]).to be_within(0.01).of(410 / 3.0)

    list = run("source" => "model_calls", "shape" => "list", "filter" => "origin:internal")[:rows]
    expect(list.size).to eq(1)
    expect(list.first).to include("app" => "aio", "model" => "qwen3:8b", "purpose" => "reviewer", "error" => "timeout", "process" => "gateway")
  end

  it "describes kinds and facets in the catalog" do
    catalog = Query::Catalog.describe(context)
    expect(catalog[:kinds].map { |kind| kind[:name] }).to eq(%w[request job run])
    expect(catalog[:kinds].last).to include(noun: "Agent", facets: %w[queue outbound ai experience])
    fields = catalog[:sources].first[:fields].index_by { |field| field[:name] }
    expect(fields["duration"][:facet]).to be_nil
    expect(fields["http_status"][:facet]).to eq("http")
    expect(fields["cost"]).to include(facet: "ai", unit: "usd", measure: true)
    expect(catalog[:functions][:events]).to include("ratio")
  end

  describe "the registry" do
    it "gives every facet a builder and fields, and every kind facets that exist" do
      facets = Telemetry::Work::FACETS
      expect(Ingest::Records::Txn::FACETS.keys).to match_array(facets)
      expect(Query::Sources::TRANSACTIONS.fields.filter_map(&:facet).uniq).to match_array(facets)
      (Telemetry::Work::KINDS + [ Telemetry::Work::GENERIC ]).each do |kind|
        expect(kind.facets - facets).to be_empty
        expect(kind.phases.map { |phase| Query::Sources::TRANSACTIONS.field(phase)&.unit }).to all(eq("ms"))
      end
    end

    it "names the parts of a timed kind's time, its phases among them" do
      parts = Telemetry::Work::PARTS.map(&:name)
      Telemetry::Work::KINDS.select(&:timed).each { |kind| expect(parts).to include(*kind.phases) }
      expect(parts.map { |part| Query::Sources::TRANSACTIONS.field(part)&.unit }).to all(eq("ms"))
      expect(Telemetry::Work::TIMED).to eq(%w[request job])
      expect(Triage::Words.noun("job", 1)).to eq("job run")
      expect(Triage::Words.noun("run", 2)).to eq("agent runs")
      expect(Triage::Words.noun("deploy", 2)).to eq("units of work")
    end

    it "gives every row every column, whatever its kind" do
      columns = Telemetry::Transaction.column_names.map(&:to_sym)
      household = create_household(name: "Columns")
      app = create_app(household: household, slug: "cols")
      header = Ingest::Batch::Header.new(kind: "web", host: "h", pid: 1, release: nil, started_at: nil, runtime: {}, dropped: {})
      %w[request job run deploy].each do |kind|
        context = Ingest::Records::Context.new(app_id: app.telemetry_id, header: header, clock: Ingest::Clock.new)
        row = Ingest::Records::Txn.build(
          { "kind" => kind, "name" => "x", "trace" => "a" * 32, "span" => "b" * 16, "dur" => 1 }, context)
        expect(row.keys).to match_array(columns)
      end
    end
  end
end
