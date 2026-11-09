# typed: false
# frozen_string_literal: true

# The telemetry database in specs. Its tables are partitioned by day and a
# row with nowhere to go is an error, so the partitions around "now" exist
# before any example runs (DDL, outside the example transaction). Rows
# written inside an example roll back with it, like everything else.
module TelemetryHelpers
  def create_app(household:, slug: "hook", name: nil)
    App.create!(household: household, slug: slug, name: name || slug.capitalize)
  end

  def ingest_key_for(app, name: "spec")
    IngestKey.generate(app: app, name: name)
  end

  # A glass-ingest/1 body: the header, then the records.
  def batch_body(records, kind: "web", host: "spec-host", pid: 1, release: "abc1234", dropped: {})
    header = { v: 1, process: { kind: kind, host: host, pid: pid, release: release, started_at: Time.now.to_f - 60,
                                runtime: { ruby: RUBY_VERSION, agent: "spec" } }, sent_at: Time.now.to_f, dropped: dropped }
    ([ header ] + records).map(&:to_json).join("\n")
  end

  # Wire records as an agent sends them (docs/ingest-protocol.md), each
  # stamped `at:` (a minute ago by default) with whatever a spec overrides
  # merged in — a field overridden to nil is left out, as an agent leaves it.
  def wire_txn(at: Time.now - 60, **fields)
    { t: "txn", ts: at.to_f, kind: "request", name: "A#index", trace: SecureRandom.hex(16), span: SecureRandom.hex(8), dur: 10.0,
      status: "ok" }.merge(fields).compact
  end

  # An agent's run: a txn of kind run with its harness facets.
  def wire_run(at: Time.now - 60, **fields)
    wire_txn(at: at, **{ kind: "run", name: "owner-chat", agent: "owner-chat", session: "ses_1", trigger: "message", channel: "telegram",
                         stop: "ok", kept: true }.merge(fields))
  end

  def wire_llm(at: Time.now - 60, **fields)
    { t: "llm", ts: at.to_f, provider: "anthropic-api", model: "claude-sonnet-4-6", purpose: "turn", dur: 1000.0, ttft: 500.0,
      in: 100, cache_read: 900, out: 200, cost: 0.01, status: "ok" }.merge(fields).compact
  end

  def wire_span(trace:, at: Time.now - 60, **fields)
    { t: "span", ts: at.to_f, trace: trace, span: SecureRandom.hex(8), kind: "sql", name: "Load", res: "SELECT ?", dur: 1.0 }
      .merge(fields).compact
  end

  def wire_log(msg, at: Time.now - 60, lvl: "info", **fields)
    { t: "log", ts: at.to_f, lvl: lvl, msg: msg }.merge(fields).compact
  end

  # A gauge reading by default; a metric's ts is whole seconds.
  def wire_metric(name, at: Time.now - 60, kind: "gauge", **fields)
    { t: "metric", ts: at.to_i, name: name, kind: kind, tags: {}, n: 1, sum: 1 }.merge(fields).compact
  end

  def write_batch(app, records, **header)
    key = ingest_key_for(app)
    Ingest::Receiver.call(key: key.record, text: batch_body(records, **header))
  end
end

RSpec.configure do |config|
  config.include TelemetryHelpers

  # The test database outlives a day, and the days an earlier run created
  # would otherwise pile up behind today — every run starts with exactly
  # the window a fresh database gets.
  config.before(:suite) do
    oldest = Time.now.utc.to_date - Telemetry::Partitions::DAYS_BEHIND
    Telemetry::Partitions.list.select { |partition| partition.day < oldest }.each do |partition|
      TelemetryRecord.connection.execute("DROP TABLE IF EXISTS #{TelemetryRecord.connection.quote_table_name(partition.name)}")
    end
    Telemetry::Partitions.ensure!
  end

  # Process-local caches would otherwise remember ids from rows an earlier
  # example rolled back.
  config.before do
    Ingest::SeriesResolver.reset!
    Ingest::ProfileStore.reset!
    Ingest::RateLimiter.reset!
  end
end
