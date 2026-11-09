# typed: false
# frozen_string_literal: true

require "rails_helper"

# The conformance kit (spec/fixtures/ingest): whole batch bodies as clients
# send them, read by the real builders. A client in any language is tested
# against the same files, so what the server does with each is the contract.
RSpec.describe "glass-ingest/1 conformance" do
  fixtures = Rails.root.join("spec/fixtures/ingest")
  expected = JSON.parse(fixtures.join("expected.json").read)

  let(:household) { create_household }
  let(:reporting_app) { create_app(household: household, slug: "aio") }

  def parse(path)
    text = path.read
    sent_at = JSON.parse(text.lines.first).fetch("sent_at")
    Ingest::Batch.parse(app: reporting_app, text: text, now: Time.at(sent_at).utc)
  end

  expected.each do |name, outcome|
    it "reads #{name} as the kit says" do
      batch = parse(fixtures.join(name))
      expect(batch).to have_attributes(accepted: outcome["accepted"], skipped: outcome["skipped"])
      expect(batch.clock.skewed).to eq(0)
      rows = outcome["rows"].keys.to_h { |table| [ table, batch.public_send(table).size ] }
      expect(rows).to eq(outcome["rows"])
    end
  end

  it "names every fixture in expected.json" do
    expect(fixtures.glob("*.ndjson").map { |path| path.basename.to_s }).to match_array(expected.keys)
  end

  describe "an agent harness" do
    let(:batch) { parse(fixtures.join("harness.ndjson")) }

    it "keeps a run as a transaction with its ai and experience facets, and no other kind's" do
      run = batch.transactions.first
      expect(run).to include(kind: "run", name: "owner-chat", process: "gateway", host: "studio", release: "5cec02a",
        agent: "owner-chat", session: "ses_81c4", trigger: "message", channel: "telegram", stop: "ok",
        model: "claude-sonnet-4-6", rounds: 2, model_calls: 3, tool_calls: 1, tool_errors: 0,
        tokens_in: 3680, tokens_out: 1024, tokens_cache_read: 42_800, tokens_cache_write: 0, cost_usd: 0.0412,
        queue_ms: 820.0, prep_ms: 310.0, model_ms: 9150.0, tool_ms: 5400.0, wait_ms: 24_800.0, deliver_ms: 410.0,
        lag_ms: 1200.0, ttft_ms: 40_840.0, stall_ms: 24_800.0, ext_ms: 9900.0, ext_count: 5)
      expect(run).to include(http_status: nil, route: nil, db_ms: 0.0, n_plus_one: false)
      expect(run[:attrs]).to eq("run" => "run_01j9", "turn" => "trn_01j9")
    end

    it "keeps the work a run left behind as a child transaction of the same trace" do
      run, after = batch.transactions
      expect(after).to include(kind: "run", name: "compaction", trace_id: run[:trace_id], parent_span_id: run[:span_id])
    end

    it "keeps the steps of a run under their own span kinds" do
      expect(batch.spans.pluck(:kind)).to eq(%w[queue memory context model tool wait sandbox model channel])
    end

    it "keeps every model call, with what it spent and how long it took" do
      first, second, reviewer = batch.model_calls
      expect(first).to include(provider: "anthropic-api", model: "claude-sonnet-4-6", served: "claude-sonnet-4-6",
        purpose: "turn", origin: "production", round: 0, duration_ms: 4180.0, ttft_ms: 612.0, first_text_ms: 1900.0,
        tokens_in: 1840, tokens_cache_read: 21_400, tokens_out: 512, tokens_reasoning: 96, cost_usd: 0.0193,
        cost_source: "estimated", stop: "tool_use", stream: true, tool_calls: 1, tool_calls_valid: 1, process: "gateway")
      expect(Telemetry.span_hex(first[:span_id])).to eq("2222222222222204")
      expect(Telemetry.span_hex(second[:retry_of])).to eq("2222222222222204")
      expect(reviewer).to include(purpose: "reviewer", origin: "internal", estimated: true, cost_source: "free", cost_usd: 0.0,
        prompt_ms: 220.0, decode_ms: 400.0, tool_calls_valid: nil)
    end
  end

  it "keeps what the browser saw of a run in the run's trace" do
    batch = parse(fixtures.join("harness.ndjson"))
    painted = batch.pages.first
    expect(painted).to include(kind: "custom", name: "answer.painted", trace_id: batch.transactions.first[:trace_id])
    expect(painted[:props]).to eq("run" => "run_01j9", "ms" => 41_300)
  end

  describe "what a server must survive" do
    let(:batch) { parse(fixtures.join("tolerance.ndjson")) }

    it "keeps a kind it has never heard of, read generously" do
      deploy = batch.transactions.first
      expect(deploy).to include(kind: "deploy", name: "hook", duration_ms: 61_000.0, queue_ms: 12.0, http_status: 200)
      expect(deploy[:attrs]).to eq("rev" => 14, "strategy" => "swap")
    end

    it "drops the fields of a facet the kind does not carry" do
      run = batch.transactions.last
      expect(run).to include(kind: "run", agent: "owner-chat", http_status: nil, route: nil, db_ms: 0.0)
    end

    it "stores a span kind it does not know as custom, and cleans what a model call claims" do
      expect(batch.spans.first).to include(kind: "custom", name: "docker build")
      expect(batch.model_calls.first).to include(origin: "production", cost_usd: 0.0, cost_source: nil)
    end
  end

  it "writes a harness batch into the tables" do
    text = fixtures.join("harness.ndjson").read
    shift = Time.now.to_f - 300 - 1_790_000_120.0
    body = text.lines.map do |line|
      record = JSON.parse(line)
      record["ts"] += shift if record.key?("ts")
      record.to_json
    end.join("\n")

    result = Ingest::Receiver.call(key: ingest_key_for(reporting_app).record, text: body)
    expect(result).to have_attributes(accepted: 17, skipped: 0, skewed: 0)
    expect(Telemetry::Transaction.where(app_id: reporting_app.telemetry_id, kind: "run").sum(:cost_usd)).to be_within(1e-9).of(0.0412)
    expect(Telemetry::ModelCall.where(app_id: reporting_app.telemetry_id).order(:ts).pluck(:purpose)).to eq(%w[turn reviewer turn])
    expect(Telemetry::Span.where(app_id: reporting_app.telemetry_id, kind: "wait").pick(:duration_ms)).to eq(24_800.0)
  end

  describe "the sketch" do
    kit = JSON.parse(fixtures.join("sketch.json").read)

    it "maps every pinned value to its index" do
      kit["indexes"].each do |entry|
        expect(Telemetry::Sketch.index_for(entry["value"].to_f)).to eq(entry["index"]), "index for #{entry['value']}"
      end
    end

    it "folds values into the pinned wire arrays" do
      kit["sketches"].each do |entry|
        sketch = Telemetry::Sketch.new
        entry["values"].each { |value| sketch.add(value.to_f) }
        expect(sketch.to_pairs).to eq(entry["sk"])
      end
    end
  end
end
