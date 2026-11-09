# typed: false
# frozen_string_literal: true

require "rails_helper"
require "open3"

# The Node client and the server, actually meeting: a batch built by
# clients/node (test/emit.ts) is read by the real builders and written to the
# real tables. Everything else tests one side against the conformance kit;
# this is what would catch the two sides agreeing with the kit and not with
# each other.
RSpec.describe "The Node client's batches" do
  node = %w[node /opt/homebrew/bin/node /usr/local/bin/node].find { |bin| system("#{bin} --version >/dev/null 2>&1") }
  # Type stripping without a flag arrived in Node 22.18; the client asks for 24.
  recent = node && `#{node} --version`[/\d+/].to_i >= 24

  let(:household) { create_household }
  let(:reporting_app) { create_app(household: household, slug: "aio") }

  it "are read whole by the server, with nothing skipped", skip: (recent ? false : "needs Node 24") do
    body, error, status = Open3.capture3(node, Rails.root.join("clients/node/test/emit.ts").to_s)
    expect(status).to be_success, error

    result = Ingest::Receiver.call(key: ingest_key_for(reporting_app).record, text: body)
    expect(result).to have_attributes(skipped: 0, skewed: 0)
    id = reporting_app.telemetry_id

    run = Telemetry::Transaction.find_by(app_id: id)
    expect(run).to have_attributes(
      kind: "run", name: "owner-chat", process: "gateway", host: "studio", release: "5cec02a", status: "ok", kept: true,
      agent: "owner-chat", session: "ses_81c4", trigger: "message", channel: "telegram", stop: "ok", user_ref: "u_9c1f",
      model: "claude-sonnet-4-6", rounds: 1, model_calls: 2, tool_calls: 1, tool_errors: 0,
      tokens_in: 3680, tokens_out: 1024, tokens_cache_read: 42_800, tokens_cache_write: 0,
      duration_ms: 41_000.0, queue_ms: 800.0, prep_ms: 200.0, model_ms: 9000.0, tool_ms: 6000.0, wait_ms: 24_000.0,
      deliver_ms: 400.0, lag_ms: 900.0, ttft_ms: 40_800.0, http_status: nil
    )
    expect(run.cost_usd).to be_within(1e-9).of(0.0392)
    expect(run.attrs).to eq("run" => "run_01j9")

    spans = Telemetry::Span.where(app_id: id).order(:ts)
    expect(spans.pluck(:kind)).to eq(%w[queue memory model tool wait sandbox model channel])
    expect(spans.where(kind: "wait").pick(:parent_id)).to eq(spans.where(kind: "tool").pick(:span_id))
    expect(spans.where(kind: "queue").pick(:parent_id)).to eq(run.span_id)

    calls = Telemetry::ModelCall.where(app_id: id).order(:ts).to_a
    expect(calls.map(&:purpose)).to eq(%w[turn turn title])
    expect(calls.first).to have_attributes(trace_id: run.trace_id, provider: "anthropic-api", tier: "frontier", round: 0,
      ttft_ms: 600.0, first_text_ms: 1900.0, tokens_cache_read: 21_400, tokens_reasoning: 96, cost_source: "estimated",
      stop: "tool_use", stream: true, tool_calls: 1, tool_calls_valid: 1, agent: "owner-chat", session: "ses_81c4")
    expect(calls.first.span_id).to eq(spans.where(kind: "model").order(:ts).pick(:span_id))
    expect(calls.second.retry_of).to eq(calls.first.span_id)
    expect(calls.last).to have_attributes(origin: "internal", estimated: true, cost_source: "free", trace_id: nil, decode_ms: 400.0)

    expect(Telemetry::Marker.where(app_id: id).pluck(:title)).to eq([ "Model version changed: qwen3:8b" ])
    expect(Telemetry::LogLine.where(app_id: id).pluck(:level, :source)).to eq([ [ "warn", "gateway" ] ])
    names = Telemetry::MetricSeries.where(app_id: id).pluck(:name).uniq
    expect(names).to include("ai.calls", "ai.cost", "ai.tokens", "ai.duration", "ai.ttft", "ai.runs", "ai.run.active", "ai.tool.calls",
      "node.eventloop.delay_ms")
    expect(Telemetry::AgentProcess.find_by(app_id: id).runtime).to include("client" => "glass-node", "node" => be_present)

    # A profile of the process: app code named relative to the app's root,
    # the runtime's own as `node`, nothing by an absolute path.
    functions = Telemetry::ProfileFunction.where(app_id: id)
    expect(functions.find_by(name: "burn")).to have_attributes(file: "test/emit.ts", category: "app")
    expect(functions.pluck(:category).uniq - %w[app gem node native]).to be_empty
    expect(functions.pluck(:file)).to all(satisfy { |file| !file.start_with?("/") })
    expect(Telemetry::ProfileSample.where(app_id: id, process: "gateway", txn: nil).sum(:ms)).to be > 50

    # The phases add up to all but what no span covered.
    context = Query::Context.new(household)
    request = Query::Request.from_params("source" => "transactions", "shape" => "table", "from" => 1.hour.ago.to_f, "to" => Time.now.to_f,
      "compute" => [ "avg(untracked)", "avg(active)" ])
    expect(Query::Runner.run(request, context)[:rows].first).to eq("avg(untracked)" => 600.0, "avg(active)" => 17_000.0)
  end
end
