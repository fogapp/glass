# typed: false
# frozen_string_literal: true

require "rails_helper"
require "zlib"
require "glass/logs"

# The gem and the server, actually meeting: a batch built by clients/ruby
# through its public API and its real transport is read by the real builders
# and written to the real tables. The conformance kit tests each side on its
# own; this is what would catch the two agreeing with the kit and not with
# each other. (The Node client's twin is node_client_spec.rb.)
RSpec.describe "The Ruby client's batches" do
  let(:household) { create_household }
  let(:reporting_app) { create_app(household: household, slug: "aio") }
  let(:bodies) { [] }

  before do
    sink = bodies
    Glass.reset!
    Glass.configure do |c|
      c.url = "http://glass.test"
      c.api_key = "glass_ing_spec"
      c.release = "5cec02a"
      c.trace_sample_rate = 1.0
      c.enabled[:profiling] = false
      c.enabled[:runtime] = false
      c.sender = lambda do |body|
        sink << body
        Glass::Transport::Response.new(202, '{"accepted":1,"directives":{}}', nil)
      end
    end
  end

  after { Glass.reset! }

  it "are read whole by the server, with nothing skipped" do
    job = Struct.new(:queue_name, :executions).new("default", 1)
    def job.class = Struct.new(:name).new("ReconcileJob")

    txn = Glass::Tracer.start_job(job)
    Glass.span("reconcile", resource: "bookorbit") do
      Glass::Logs.record(2, "Reconciled 3 wants")
      Glass.model_call(provider: "anthropic-api", model: "claude-sonnet-4-6", duration_ms: 812.0, purpose: "title",
        input_tokens: 400, output_tokens: 12, cost_usd: 0.0014, cost_source: "estimated", stop: "end_turn",
        attrs: { model_version: "mv_3a" })
    end
    Glass::Tracer.finish_job(txn, job)
    Glass.increment("wants.reconciled", 3, tags: { library: "books" })
    Glass.flush(timeout: 5)

    expect(bodies).not_to be_empty
    text = bodies.map { |body| Zlib.gunzip(body) }.find { |t| t.lines.size > 1 }
    result = Ingest::Receiver.call(key: ingest_key_for(reporting_app).record, text: text)
    expect(result).to have_attributes(skipped: 0, skewed: 0)
    id = reporting_app.telemetry_id

    row = Telemetry::Transaction.find_by(app_id: id)
    expect(row).to have_attributes(kind: "job", name: "ReconcileJob", release: "5cec02a", status: "ok", kept: true, queue: "default")

    span = Telemetry::Span.find_by(app_id: id)
    expect(span).to have_attributes(kind: "custom", name: "reconcile", trace_id: row.trace_id, parent_id: row.span_id)

    log = Telemetry::LogLine.find_by(app_id: id)
    expect(log).to have_attributes(level: "warn", source: "rails", trace_id: row.trace_id)

    call = Telemetry::ModelCall.find_by(app_id: id)
    expect(call).to have_attributes(trace_id: row.trace_id, provider: "anthropic-api", model: "claude-sonnet-4-6", purpose: "title",
      origin: "production", duration_ms: 812.0, tokens_in: 400, tokens_out: 12, cost_source: "estimated", stop: "end_turn",
      attrs: { "model_version" => "mv_3a" })
    expect(call.cost_usd).to be_within(1e-9).of(0.0014)

    names = Telemetry::MetricSeries.where(app_id: id).pluck(:name).uniq
    expect(names).to include("wants.reconciled", "rails.job.count", "rails.job.duration", "ai.calls", "ai.cost", "ai.tokens", "ai.duration")
    expect(Telemetry::AgentProcess.find_by(app_id: id).runtime).to include("client" => "glass-ruby", "agent" => Glass::VERSION,
      "ruby" => RUBY_VERSION)
  end
end
