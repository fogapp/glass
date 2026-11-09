# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Triage do
  let(:household) { create_household }
  let(:hook) { create_app(household: household, slug: "hook") }
  let(:hub) { create_app(household: household, slug: "hub") }
  let(:now) { Time.now.utc }
  let(:window) { Triage::Window.around(from: now - 1.hour, to: now) }

  def txn(name, at:, dur:, kind: "request", error: nil, **fields)
    wire_txn(at: at, kind: kind, name: name, dur: dur, status: error ? "error" : "ok", http: kind == "request" ? (error ? 500 : 200) : nil,
      error: error, db_ms: dur / 4.0, queue: kind == "job" ? "default" : nil, **{ db_n: 2, n1: false, kept: false }.merge(fields))
  end

  # `count` rows spread over the hour before `ending`.
  def spread(count, ending:, &row)
    Array.new(count) { |index| row.call(ending - (index + 1) * (50.minutes / count)) }
  end

  def kinds(findings) = findings.map { |finding| [ finding.subject.kind.serialize, finding.subject.name ] }

  before do
    # The comparison window: half a day ago, everything healthy and fast.
    write_batch(hook, spread(40, ending: now - 12.hours) { |at| txn("SearchController#index", at: at, dur: 100.0) } +
      spread(40, ending: now - 12.hours) { |at| txn("WantsController#create", at: at, dur: 40.0) })
    # The range: search got slower, wants started failing, show repeats a
    # query per row, and the logs keep saying the same thing.
    write_batch(hook, spread(40, ending: now) { |at| txn("SearchController#index", at: at, dur: 900.0) } +
      spread(40, ending: now) { |at| txn("WantsController#create", at: at, dur: 40.0, error: at.min.even? ? "Faraday::TimeoutError" : nil) } +
      spread(30, ending: now) { |at| txn("WantsController#show", at: at, dur: 30.0, n1: true, db_n: 40, kept: true) } +
      spread(6, ending: now) { |at| wire_log("Upstream answered 503", at: at, lvl: "error") })
    write_batch(hub, spread(30, ending: now) { |at| txn("TodayController#show", at: at, dur: 20.0) })
  end

  it "ranks what crossed a line, worst first, across apps" do
    findings = described_class.scan(household, window: window)
    expect(kinds(findings)).to include(
      [ "regression", "SearchController#index" ], [ "failing", "WantsController#create" ],
      [ "n_plus_one", "WantsController#show" ], [ "log_errors", "Upstream answered 503" ]
    )
    expect(findings.map(&:score)).to eq(findings.map(&:score).sort.reverse)
    expect(findings.map { |finding| finding.subject.app }.uniq).to eq([ "hook" ])

    regression = findings.find { |finding| finding.subject.kind == Triage::Kind::Regression }
    expect(regression.title).to eq("hook · SearchController#index got 9× slower")
    expect(regression.figures["p95_before"]).to be_within(1).of(100)
    expect(regression.severity).to eq(Triage::Severity::Critical)

    failing = findings.find { |finding| finding.subject.kind == Triage::Kind::Failing }
    expect(failing.summary).to include("where it never failed before", "Faraday::TimeoutError")
  end

  it "keeps to one app when asked, and to nothing a household does not have" do
    expect(described_class.scan(household, window: window, app: "hub")).to be_empty
    expect(described_class.scan(create_household(name: "Other"), window: window)).to be_empty
  end

  it "says a hotspot once when it is also a regression" do
    write_batch(hook, spread(30, ending: now) { |at| txn("HomeController#index", at: at, dur: 5.0) } +
      spread(30, ending: now) { |at| txn("PingController#show", at: at, dur: 5.0) })
    found = kinds(described_class.scan(household, window: window))
    expect(found).to include([ "regression", "SearchController#index" ])
    expect(found).not_to include([ "hotspot", "SearchController#index" ])
  end

  it "works one finding up into facts, evidence, steps and a brief" do
    finding = described_class.scan(household, window: window).find { |candidate| candidate.subject.kind == Triage::Kind::Failing }
    subject = Triage::Subject.parse(finding.subject.id)
    detail = described_class.detail(household, window: window, subject: subject)

    expect(detail.finding.title).to eq(finding.title)
    expect(detail.filter).to eq(%(app:hook kind:request name:"WantsController#create"))
    expect(detail.facts.map(&:label)).to include("App", "Name", "Count in range")
    types = detail.evidence.map { |evidence| evidence.type.serialize }
    expect(types).to include("chart", "table", "traces")
    expect(detail.evidence.find { |evidence| evidence.title == "Error classes" }.rows).to eq([ { "error" => "Faraday::TimeoutError", "count" => 20.0 } ])
    chart = detail.evidence.find { |evidence| evidence.type == Triage::Evidence::Type::Chart }
    expect(chart.query).to include("source" => "transactions", "shape" => "timeseries", "from" => window.baseline_from.to_f)

    brief = Triage::Brief.render(detail, window: window)
    expect(brief).to start_with("# hook · WantsController#create is failing")
    expect(brief).to include("## Evidence", "| Faraday::TimeoutError | 20 |", "`get_trace`", "## Suggested steps", detail.filter)
  end

  it "finds the statement an N+1 repeats in its kept traces" do
    trace = SecureRandom.hex(16)
    write_batch(hook, [ txn("WantsController#show", at: now - 5.minutes, dur: 30.0, n1: true, db_n: 40, kept: true, trace: trace) ] +
      Array.new(6) { wire_span(trace: trace, at: now - 5.minutes, name: "Want Load", res: "SELECT * FROM wants WHERE id = ?", dur: 1.0) } +
      Array.new(6) { wire_span(trace: trace, at: now - 5.minutes, name: "SQL", res: "SET LOCAL statement_timeout = ?", dur: 0.1) } +
      Array.new(6) { wire_span(trace: trace, at: now - 5.minutes, name: "SolidQueue::Semaphore Load", res: 'SELECT "solid_queue_semaphores".* FROM "solid_queue_semaphores" WHERE "solid_queue_semaphores"."key" = ? LIMIT ? FOR UPDATE', dur: 0.1) } +
      Array.new(6) { wire_span(trace: trace, at: now - 5.minutes, name: "SolidQueue::ReadyExecution Create", res: 'INSERT INTO "solid_queue_ready_executions" ("job_id") VALUES (?)', dur: 0.1) } +
      Array.new(2) { wire_span(trace: trace, at: now - 5.minutes, name: "SolidQueue::Job Create", res: 'INSERT INTO "solid_queue_jobs" ("class_name") VALUES (?)', dur: 0.1) })
    subject = Triage::Subject.new(kind: Triage::Kind::NPlusOne, app: "hook", work: "request", name: "WantsController#show")
    detail = described_class.detail(household, window: window, subject: subject)
    repeated = detail.evidence.find { |evidence| evidence.title == "The statements that repeat" }
    expect(repeated.rows.first).to include("resource" => "SELECT * FROM wants WHERE id = ?", "count" => 6.0)
    expect(repeated.rows.pluck("resource")).not_to include("SET LOCAL statement_timeout = ?")
    expect(repeated.rows.pluck("resource").grep(/solid_queue_(semaphores|ready_executions)/)).to be_empty
    expect(repeated.rows.pluck("resource")).to include('INSERT INTO "solid_queue_jobs" ("class_name") VALUES (?)'),
      "the enqueue itself stays: perform_later in a loop is an N+1 worth naming"
  end

  it "compares a log message with its own count before, however far down the baseline ranks it" do
    # A hundred and one louder messages before; the one in question was said once.
    write_batch(hook, (0..100).flat_map { |index| Array.new(2) { wire_log("Noise #{index}", at: now - 12.hours, lvl: "error") } } +
      [ wire_log("Upstream answered 503", at: now - 12.hours, lvl: "error") ])
    finding = described_class.scan(household, window: window).find { |candidate| candidate.subject.kind == Triage::Kind::LogErrors }

    expect(finding.figures).to include("count_before" => 1.0, "new" => false)
    expect(finding.summary).to include("(1 in the longer window before)")
  end

  it "compares an endpoint with its own runs before, however far down the baseline ranks it" do
    # Five hundred and one busier endpoints before; the one in question ran once, and failed.
    write_batch(hook, (0..500).flat_map { |index| spread(2, ending: now - 12.hours) { |at| txn("Busy#{index}Controller#show", at: at, dur: 5.0) } } +
      [ txn("OrdersController#create", at: now - 13.hours, dur: 40.0, error: "Faraday::TimeoutError") ])
    write_batch(hook, spread(10, ending: now) { |at| txn("OrdersController#create", at: at, dur: 40.0, error: at.min.even? ? "Faraday::TimeoutError" : nil) })
    finding = described_class.scan(household, window: window)
      .find { |candidate| candidate.subject.kind == Triage::Kind::Failing && candidate.subject.name == "OrdersController#create" }

    expect(finding.figures).to include("new" => false, "error_rate_before" => 1.0, "count_before" => 1.0)
    expect(finding.summary).not_to include("nothing ran before")
  end

  it "reads every N+1's kept traces in a constant number of statements" do
    flagged = lambda do |app, name, statement|
      trace = SecureRandom.hex(16)
      write_batch(app, spread(6, ending: now - 2.minutes) { |at| txn(name, at: at, dur: 30.0, n1: true, db_n: 40, kept: true) } +
        [ txn(name, at: now - 1.minute, dur: 30.0, n1: true, db_n: 40, kept: true, trace: trace) ] +
        Array.new(statement ? 7 : 0) { wire_span(trace: trace, at: now - 1.minute, name: "Load", res: statement, dur: 1.0) })
    end
    flagged.call(hook, "OrdersController#index", "SELECT * FROM orders WHERE id = ?")
    flagged.call(hub, "ItemsController#index", "SELECT * FROM items WHERE id = ?")
    flagged.call(hub, "UsersController#index", nil)

    detector = Triage::Detectors::NPlusOne.new(Triage::Scan.new(household: household, window: window))
    findings = nil
    queries = count_queries(matching: /FROM (transactions|spans)\b/) { findings = detector.findings }

    statements = findings.to_h { |finding| [ finding.subject.name, finding.figures["statement"] ] }
    expect(statements).to include("OrdersController#index" => "SELECT * FROM orders WHERE id = ?",
      "ItemsController#index" => "SELECT * FROM items WHERE id = ?", "UsersController#index" => nil)
    # The work, the flags, the newest kept runs, their traces' runs and
    # their statements — however many units of work were flagged.
    expect(queries.size).to eq(5)
  end

  it "asks each question once while working a finding up" do
    finding = described_class.scan(household, window: window).find { |candidate| candidate.subject.kind == Triage::Kind::Failing }
    subject = Triage::Subject.parse(finding.subject.id)
    queries = count_queries { described_class.detail(household, window: window, subject: subject) }

    questions = queries.grep_v(/\ASET LOCAL/)
    expect(questions.tally.select { |_, times| times > 1 }).to be_empty
    expect(questions.size).to be < 20
  end

  it "answers nil for a subject that no longer stands out, or never did" do
    calm = Triage::Subject.new(kind: Triage::Kind::Failing, app: "hub", work: "request", name: "TodayController#show")
    expect(described_class.detail(household, window: window, subject: calm)).to be_nil
    expect(Triage::Subject.parse("not-base64!")).to be_nil
    expect(Triage::Subject.parse(Base64.urlsafe_encode64(JSON.generate([ "nope", "hook", nil, "x" ])))).to be_nil
    forged = Base64.urlsafe_encode64(JSON.generate([ Triage::Kind.values.first.serialize, "hook status:ok", nil, "x" ]))
    expect(Triage::Subject.parse(forged)).to be_nil
  end

  it "reports an agent that stopped, and one that sheds" do
    Telemetry::AgentProcess.where(app_id: hub.telemetry_id).update_all(last_seen_at: 2.hours.ago)
    Telemetry::AgentProcess.where(app_id: hook.telemetry_id).update_all(dropped: { "log" => 400 }, records: 600)
    found = kinds(described_class.scan(household, window: window))
    expect(found).to include([ "reporting", "stopped" ], [ "reporting", "shedding" ])

    old = Triage::Window.around(from: now - 3.hours, to: now - 2.hours)
    expect(kinds(described_class.scan(household, window: old)).map(&:first)).not_to include("reporting")
  end

  it "compares with four times the range before it, a day at least, a fortnight at most" do
    expect(window.baseline_from).to be_within(0.001).of(window.from - 1.day)
    week = Triage::Window.around(from: now - 7.days, to: now)
    expect(week.baseline_from).to be_within(0.001).of(week.from - 14.days)
    expect { Triage::Window.around(from: now, to: now - 1.hour) }.to raise_error(Query::Invalid, /ends before/)
    expect { Triage::Window.around(from: now - 30.days, to: now) }.to raise_error(Query::Invalid, /at most 14 days/)
  end
end
