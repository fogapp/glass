# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ingest::Receiver do
  let(:household) { create_household }
  let(:reporting_app) { create_app(household: household) }
  let(:now) { Time.now.utc }
  let(:trace) { SecureRandom.hex(16) }
  let(:span) { SecureRandom.hex(8) }

  def txn(**overrides)
    wire_txn(at: now - 5, **{ name: "WantsController#index", trace: trace, span: span, dur: 42.5, method: "GET", route: "/wants",
                             path: "/wants", http: 200, db_ms: 10.0, db_n: 3, kept: true, user: "u_1", origin: "lan",
                             attrs: { want_id: "w1", nested: { a: 1 } } }.merge(overrides))
  end

  it "writes every record type and answers what it accepted" do
    records = [
      txn,
      wire_span(trace: trace, at: now - 4.9, parent: span, name: "Want Load", res: "SELECT 1", dur: 1.5),
      { t: "metric", ts: now.to_i - 10, name: "rails.request.duration", kind: "dist", unit: "ms", tags: { controller: "wants" },
        n: 3, sum: 90.0, min: 20.0, max: 40.0, last: 30.0, sk: [ 152, 1, 172, 2 ] },
      wire_metric("ruby.threads", at: now - 10, sum: 9, last: 9),
      { t: "marker", ts: now.to_f - 60, kind: "event", title: "Reconciled" },
      wire_log("slow", at: now - 4.8, lvl: "warn", src: "rails", trace: trace, span: span),
      { t: "profile", ts: now.to_f - 60, dur: 60.0, hz: 100, funcs: [ [ "main", "app.rb", 1, "app" ], [ "IO#read", "<cfunc>", 0, "native" ] ],
        stacks: [ [ 0, 1 ], [ 0 ] ], samples: [ [ 0, "WantsController#index", "idle", 40 ], [ 1, nil, "running", 5 ] ] },
      { t: "mystery" }
    ]

    result = write_batch(reporting_app, records)

    expect(result).to have_attributes(accepted: 7, skipped: 1, skewed: 0)
    row = Telemetry::Transaction.find_by(app_id: reporting_app.telemetry_id)
    expect(row).to have_attributes(name: "WantsController#index", duration_ms: 42.5, db_count: 3, kept: true, user_ref: "u_1",
      origin: "lan", process: "web", release: "abc1234", http_status: 200)
    expect(row.attrs).to eq("want_id" => "w1", "nested" => '{"a":1}')
    expect(Telemetry.span_hex(row.span_id)).to eq(span)
    expect(row.trace_id.delete("-")).to eq(trace)

    expect(Telemetry::Span.where(trace_id: row.trace_id).count).to eq(1)
    series = Telemetry::MetricSeries.where(app_id: reporting_app.telemetry_id).order(:name)
    expect(series.map(&:name)).to eq(%w[rails.request.duration ruby.threads])
    expect(Telemetry::MetricPoint.find_by(series_id: series.first.id).sketch).to eq([ 152, 1, 172, 2 ])
    expect(Telemetry::Marker.where(app_id: reporting_app.telemetry_id).pluck(:title)).to eq([ "Reconciled" ])
    expect(Telemetry::LogLine.where(app_id: reporting_app.telemetry_id).pluck(:level, :message)).to eq([ [ "warn", "slow" ] ])

    samples = Telemetry::ProfileSample.where(app_id: reporting_app.telemetry_id).order(:samples)
    expect(samples.map { |s| [ s.txn, s.state, s.samples, s.ms ] }).to eq([ [ nil, "running", 5, 50.0 ], [ "WantsController#index", "idle", 40, 400.0 ] ])
    expect(Telemetry::ProfileFunction.where(app_id: reporting_app.telemetry_id).count).to eq(2)
    expect(Telemetry::ProfileStack.where(app_id: reporting_app.telemetry_id).count).to eq(2)

    process = Telemetry::AgentProcess.find_by(app_id: reporting_app.telemetry_id)
    expect(process).to have_attributes(kind: "web", host: "spec-host", pid: 1, batches: 1, records: 7)
    expect(reporting_app.reload.last_seen_at).to be_present
  end

  it "skips a record missing what its table needs, and stamps a skewed timestamp on arrival" do
    result = write_batch(reporting_app, [ txn(dur: nil), txn(trace: "nope"), txn(ts: now.to_f - 10 * 86_400) ])
    expect(result).to have_attributes(accepted: 1, skipped: 2, skewed: 1)
    expect(Telemetry::Transaction.find_by(app_id: reporting_app.telemetry_id).ts).to be_within(5).of(now)
  end

  it "refuses a batch that is not one" do
    key = ingest_key_for(reporting_app).record
    expect { described_class.call(key: key, text: "") }.to raise_error(Ingest::Batch::Invalid, /Empty/)
    expect { described_class.call(key: key, text: "not json\n") }.to raise_error(Ingest::Batch::Invalid, /not valid JSON/)
    expect { described_class.call(key: key, text: '{"v":2,"process":{}}') }.to raise_error(Ingest::Batch::Invalid, /version/)
  end

  it "reuses series and dictionaries across batches" do
    metric = wire_metric("x", at: now - 10, kind: "counter", tags: { a: "1" })
    write_batch(reporting_app, [ metric ])
    write_batch(reporting_app, [ metric.merge(ts: now.to_i) ])
    expect(Telemetry::MetricSeries.where(app_id: reporting_app.telemetry_id, name: "x").count).to eq(1)
    expect(Telemetry::MetricPoint.count).to eq(2)
  end

  it "folds tag sets past the cardinality limit into one overflow series" do
    stub_const("Ingest::SeriesResolver::MAX_SERIES_PER_METRIC", 2)
    records = (1..4).map { |i| wire_metric("x", at: now, kind: "counter", tags: { id: i.to_s }) }
    write_batch(reporting_app, records)
    tags = Telemetry::MetricSeries.where(app_id: reporting_app.telemetry_id, name: "x").pluck(:tags)
    expect(tags).to contain_exactly({ "id" => "1" }, { "id" => "2" }, { "glass_overflow" => "true" })
  end

  it "remembers where an over-limit tag set went, so the next batch asks nothing" do
    stub_const("Ingest::SeriesResolver::MAX_SERIES_PER_METRIC", 2)
    records = (1..4).map { |i| wire_metric("x", at: now, kind: "counter", tags: { id: i.to_s }) }
    write_batch(reporting_app, records)
    queries = count_queries(matching: /metric_series/) { write_batch(reporting_app, records) }
    expect(queries).to be_empty
    overflow = Telemetry::MetricSeries.find_by(app_id: reporting_app.telemetry_id, name: "x", tags: { "glass_overflow" => "true" })
    expect(Telemetry::MetricPoint.where(series_id: overflow.id).count).to eq(4)
  end

  it "marks a deploy when a process reports a release the app has not reported before" do
    write_batch(reporting_app, [ txn ], release: "aaa", pid: 1)
    write_batch(reporting_app, [ txn ], release: "aaa", pid: 2)
    expect(Telemetry::Marker.where(app_id: reporting_app.telemetry_id, kind: "deploy")).not_to exist
    write_batch(reporting_app, [ txn ], release: "bbb", pid: 3)
    expect(Telemetry::Marker.where(app_id: reporting_app.telemetry_id, kind: "deploy").pluck(:release)).to eq([ "bbb" ])
  end
end
