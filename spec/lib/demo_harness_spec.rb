# typed: false
# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("lib/demo/generator")

# The demo is part of the product: the console is built
# against it, so the stories it tells have to be there to be seen.
RSpec.describe Demo::Harness do
  let(:household) { create_household }
  let(:context) { Query::Context.new(household) }
  let(:generator) { Demo::Generator.new(days: 2, output: nil) }

  before do
    Current.household = household
    create_app(household: household, slug: "hook")
    generator.send(:ensure_partitions)
    generator.send(:write_harness, household)
  end

  def rows(from:, to: generator.now, **params)
    request = Query::Request.from_params({ "from" => from.to_f, "to" => to.to_f, "shape" => "table" }.transform_keys(&:to_s)
      .merge(params.transform_keys(&:to_s)))
    Query::Runner.run(request, context)[:rows]
  end

  it "reports runs whose phases account for nearly all of their time" do
    row = rows(from: generator.from, source: "transactions", filter: "app:aio kind:run trigger:message",
      compute: [ "count", "avg(untracked)", "avg(duration)", "sum(cost)" ]).first
    expect(row["count"]).to be > 40
    expect(row["avg(untracked)"] / row["avg(duration)"]).to be < 0.02
    expect(row["sum(cost)"]).to be > 0
  end

  it "tells the story of prompt caching that stopped working between two releases" do
    cached = ->(from, to) do
      rows(from: from, to: to, source: "model_calls", filter: "app:aio provider:anthropic-api",
        compute: [ "ratio(cache_read, input_total)" ]).first["ratio(cache_read, input_total)"]
    end
    expect(cached.call(generator.now - 29.hours, generator.now - 9.hours)).to eq(0.0)
    expect(cached.call(generator.now - 7.hours, generator.now)).to be > 0.8
    deploys = Telemetry::Marker.where(kind: "deploy").where("title LIKE 'Rebuilt%'").pluck(:ts)
    expect(deploys).to include(be_within(1).of(generator.now - 30.hours), be_within(1).of(generator.now - 8.hours))
  end

  it "tells the story of a cold container on a conversation's first shell" do
    cold = rows(from: generator.from, source: "spans", filter: "app:aio kind:sandbox @cold:true", compute: [ "count", "p50(duration)" ]).first
    expect(cold["count"]).to be > 5
    expect(cold["p50(duration)"]).to be > 2_500
  end

  it "tells the story of an approval nobody answered" do
    stalled = rows(from: generator.now - 4.hours, source: "transactions", filter: "app:aio wait:>590s", shape: "list")
    expect(stalled.size).to eq(1)
    expect(stalled.first).to include("wait" => 600_000.0, "channel" => "telegram", "tool_errors" => 1)
    # The person stalled, not the harness: the silence it is charged with leaves the wait out.
    expect(stalled.first["stall"]).to be < 120_000
    expect(Telemetry::Span.where(kind: "wait").where("attrs->>'status' = 'expired'").count).to eq(1)
  end

  it "continues a tool call into hook as hook's own request in the same trace" do
    request = Telemetry::Transaction.where(name: "McpController#handle").order(:ts).first
    expect(request).to be_present
    outbound = Telemetry::Span.find_by(trace_id: request.trace_id, span_id: request.parent_span_id)
    expect(outbound).to have_attributes(kind: "http", name: "POST hook")
    expect(Telemetry::Transaction.where(trace_id: request.trace_id, kind: "run")).to exist
  end

  it "derives the long history of spend as metrics" do
    names = Telemetry::MetricSeries.pluck(:name).uniq
    expect(names).to include("ai.cost", "ai.tokens", "ai.calls", "ai.ttft", "node.eventloop.delay_ms")
  end
end
