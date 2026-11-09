# typed: false
# frozen_string_literal: true

require "rails_helper"

# Where each detector draws its line. A finding is something to fix, so each
# case here is one triage listed that nobody could act on — or one it must
# keep, or one it missed — with the numbers it was found with.
RSpec.describe Triage do
  let(:household) { create_household }
  let(:stream) { create_app(household: household, slug: "stream") }
  let(:now) { Time.now.utc }
  let(:window) { Triage::Window.around(from: now - 1.hour, to: now) }

  def job(name, at:, dur:, queue:, wait: 500.0, **fields)
    wire_txn(at: at, kind: "job", name: name, dur: dur, queue: queue, queue_ms: wait, **fields)
  end

  def request(name, at:, dur:, **fields) = wire_txn(at: at, kind: "request", name: name, dur: dur, http: 200, **fields)

  # `count` rows spread over the fifty minutes before `ending`.
  def spread(count, ending:, &row)
    Array.new(count) { |index| row.call(ending - (index + 1) * (50.minutes / count), index) }
  end

  # One minute of profile samples: `functions` maps a function's name to
  # its weight, every sample attributed to `transaction`, at 100 Hz.
  def profile(at:, transaction:, functions:, state: "running")
    names = functions.keys
    { t: "profile", ts: at.to_f, dur: 60.0, hz: 100, mode: "wall",
      funcs: [ [ "main", "app.rb", 1, "app" ] ] + names.map { |name| [ name, "<cfunc>", 0, "native" ] },
      stacks: names.each_index.map { |index| [ 0, index + 1 ] },
      samples: names.each_with_index.map { |name, index| [ index, transaction, state, functions.fetch(name) ] } }
  end

  def found(kind) = described_class.scan(household, window: window).select { |finding| finding.subject.kind == kind }

  def names(kind) = found(kind).map { |finding| finding.subject.name }

  describe "queue wait" do
    it "leaves a narrow queue's burst alone: DownloadVideoJob waits 3.8 min behind runs of 2.1 min" do
      write_batch(stream, spread(23, ending: now - 12.hours) { |at, _| job("DownloadVideoJob", at: at, dur: 125_000.0, queue: "youtube", wait: 96_000.0) } +
        spread(23, ending: now) { |at, i| job("DownloadVideoJob", at: at, dur: i.even? ? 125_000.0 : 300_000.0, queue: "youtube", wait: 228_000.0) })

      expect(names(Triage::Kind::Queue)).to be_empty
    end

    it "keeps a wait far past what its queue's work takes: AnalyzeMediaFileJob waits 717 min behind a 27 s run" do
      write_batch(stream, spread(9, ending: now - 12.hours) { |at, _| job("AnalyzeMediaFileJob", at: at, dur: 27_000.0, queue: "heavy", wait: 1_200_000.0) } +
        spread(9, ending: now) { |at, _| job("AnalyzeMediaFileJob", at: at, dur: 27_000.0, queue: "heavy", wait: 43_020_000.0) } +
        spread(3, ending: now) { |at, _| job("DetectMarkersJob", at: at, dur: 164_000.0, queue: "heavy") })

      queue = found(Triage::Kind::Queue).sole
      expect(queue.title).to eq("stream · AnalyzeMediaFileJob waits 717 min to start")
      expect(queue.figures).to include("queue" => "heavy")
      expect(queue.figures["queue_run_p95"]).to be_within(1_000).of(164_000)
    end

    it "never lists a wait that got better: FetchSponsorSegmentsJob, 47 s against 1.1 min before" do
      write_batch(stream, spread(40, ending: now - 12.hours) { |at, _| job("FetchSponsorSegmentsJob", at: at, dur: 593.0, queue: "default", wait: 66_000.0) } +
        spread(40, ending: now) { |at, _| job("FetchSponsorSegmentsJob", at: at, dur: 593.0, queue: "default", wait: 47_000.0) } +
        # The same improvement an hour long, far past the floor: still not a finding.
        spread(40, ending: now - 12.hours) { |at, _| job("FetchTrailersJob", at: at, dur: 593.0, queue: "trailers", wait: 3_960_000.0) } +
        spread(40, ending: now) { |at, _| job("FetchTrailersJob", at: at, dur: 593.0, queue: "trailers", wait: 2_820_000.0) })

      expect(names(Triage::Kind::Queue)).to be_empty
    end
  end

  describe "shedding" do
    before { write_batch(stream, [ request("HomeController#show", at: now - 5.minutes, dur: 20.0) ], kind: "worker") }

    it "leaves noise alone: 38 records, 0% of what the agents collected" do
      Telemetry::AgentProcess.where(app_id: stream.telemetry_id).update_all(dropped: { "log" => 38 }, records: 250_000)
      expect(names(Triage::Kind::Reporting)).to be_empty
    end

    it "keeps a gap someone could see: 3,624 records, 3.2%" do
      Telemetry::AgentProcess.where(app_id: stream.telemetry_id).update_all(dropped: { "span" => 3_624 }, records: 109_000)
      expect(names(Triage::Kind::Reporting)).to eq([ "shedding" ])
    end
  end

  describe "N+1" do
    # QueueOptimizationsJob walks media_files with find_each and preloads
    # two associations per batch: 15 pages, 16 and 17 preloads.
    def batched(trace, extra = [])
      write_batch(stream, spread(23, ending: now) do |at, i|
        job("QueueOptimizationsJob", at: at, dur: 10_000.0, queue: "default", n1: i < 21, db_n: 88, kept: i.zero?,
          trace: i.zero? ? trace : SecureRandom.hex(16))
      end + Array.new(15) { wire_span(trace: trace, res: 'SELECT "media_files".* FROM "media_files" WHERE "media_files"."household_id" = ? AND "media_files"."state" = ? AND "media_files"."id" > ? ORDER BY "media_files"."id" ASC LIMIT ?') } +
        Array.new(17) { wire_span(trace: trace, res: 'SELECT "optimized_versions".* FROM "optimized_versions" WHERE "optimized_versions"."media_file_id" IN (?)') } +
        Array.new(16) { wire_span(trace: trace, res: 'SELECT "media_streams".* FROM "media_streams" WHERE "media_streams"."media_file_id" IN (?) ORDER BY "media_streams"."index" ASC') } +
        extra)
    end

    it "leaves batched loading alone: a preload per page is one query per batch, not per row" do
      batched(SecureRandom.hex(16))
      expect(names(Triage::Kind::NPlusOne)).to be_empty
    end

    it "names the statement when a scalar key repeats per row" do
      trace = SecureRandom.hex(16)
      batched(trace, Array.new(17) { wire_span(trace: trace, res: 'SELECT "editions".* FROM "editions" WHERE "editions"."media_file_id" = ? LIMIT ?') })

      finding = found(Triage::Kind::NPlusOne).sole
      expect(finding.figures["statement"]).to start_with('SELECT "editions".*')
      expect(finding.summary).to include("The one per row: SELECT")
    end

    it "keeps preloads that far outnumber the pages" do
      trace = SecureRandom.hex(16)
      batched(trace, Array.new(40) { wire_span(trace: trace, res: 'SELECT "artworks".* FROM "artworks" WHERE "artworks"."owner_id" IN (?)') })
      expect(names(Triage::Kind::NPlusOne)).to eq([ "QueueOptimizationsJob" ])
    end
  end

  describe "regression" do
    it "leaves a fast endpoint that got less fast alone: CatalogVersionController#show, 20 ms → 70 ms" do
      write_batch(stream, spread(40, ending: now - 12.hours) { |at, _| request("Api::V1::CatalogVersionController#show", at: at, dur: 20.0) } +
        spread(40, ending: now) { |at, _| request("Api::V1::CatalogVersionController#show", at: at, dur: 70.0) })
      expect(names(Triage::Kind::Regression)).to be_empty
    end

    it "sizes a small slowdown by the time it costs: ProfilesController#current, 182 ms → 300 ms, is a notice" do
      write_batch(stream, spread(66, ending: now - 12.hours) { |at, _| request("Api::V1::ProfilesController#current", at: at, dur: 182.0) } +
        spread(66, ending: now) { |at, _| request("Api::V1::ProfilesController#current", at: at, dur: 300.0) })
      expect(found(Triage::Kind::Regression).sole.severity).to eq(Triage::Severity::Notice)
    end
  end

  describe "endpoints that stall together" do
    # WatchLater, Basketball and Profiles at their habit; at four instants
    # all three (and CatalogVersion) are slow within the same second.
    let(:usual) do
      { "Api::V1::WatchLaterController#show" => 34.0, "Api::V1::BasketballController#show" => 46.0,
        "Api::V1::ProfilesController#current" => 39.0, "Api::V1::CatalogVersionController#show" => 11.0 }
    end
    let(:slow) do
      { "Api::V1::WatchLaterController#show" => 260.0, "Api::V1::BasketballController#show" => 250.0,
        "Api::V1::ProfilesController#current" => 277.0, "Api::V1::CatalogVersionController#show" => 70.0 }
    end

    def traffic(connecting_before:, connecting_now:)
      before = usual.flat_map { |name, dur| spread(40, ending: now - 12.hours) { |at, _| request(name, at: at, dur: dur) } }
      during = usual.flat_map { |name, dur| spread(36, ending: now) { |at, _| request(name, at: at, dur: dur) } } +
        [ 48, 40, 25, 7 ].flat_map do |ago|
          slow.each_with_index.map { |(name, dur), index| request(name, at: now - ago.minutes + index * 0.2, dur: dur) }
        end
      profiles = usual.keys.flat_map do |name|
        [ profile(at: now - 12.hours, transaction: name, functions: connecting_before),
          profile(at: now - 30.minutes, transaction: name, functions: connecting_now) ]
      end
      write_batch(stream, before + during + profiles)
    end

    it "is one finding when the profiler shows them opening connections, and no regression each" do
      traffic(connecting_before: { "PG::Connection#exec_prepared" => 80, "PG::Connection#prepare" => 11, "PG::Connection#connect_poll" => 5 },
        connecting_now: { "PG::Connection#exec_prepared" => 60, "PG::Connection#prepare" => 17, "PG::Connection#connect_poll" => 12 })

      stall = found(Triage::Kind::Stall).sole
      expect(stall.title).to eq("stream's requests wait on new database connections")
      expect(stall.figures).to include("moments" => 4)
      expect(stall.figures["endpoints"]).to include("Api::V1::WatchLaterController#show", "Api::V1::ProfilesController#current")
      expect(names(Triage::Kind::Regression)).to be_empty

      detail = described_class.detail(household, window: window, subject: stall.subject)
      expect(detail.evidence.find { |evidence| evidence.title == "The moments" }.rows.size).to eq(4)
    end

    it "is not a finding without a cause the profiler names — the endpoint that regressed stays its own" do
      same = { "PG::Connection#exec_prepared" => 80, "PG::Connection#prepare" => 11, "PG::Connection#connect_poll" => 5 }
      traffic(connecting_before: same, connecting_now: same)

      expect(found(Triage::Kind::Stall)).to be_empty
      expect(names(Triage::Kind::Regression)).to include("Api::V1::WatchLaterController#show")
    end
  end

  describe "a job that never finished" do
    let(:host) { "1c7b0bc99b76" }
    let(:since) { now - 55.minutes }

    # DetectMarkersJob usually takes 2.8 min; its last run on the host
    # finished 55 minutes ago, and two threads have been sampled in it ever
    # since. AnalyzeMediaFileJob waits behind them on the heavy queue.
    before do
      write_batch(stream, spread(6, ending: now - 12.hours) { |at, _| job("DetectMarkersJob", at: at, dur: 166_000.0, queue: "heavy") }, kind: "worker", host: host)
      write_batch(stream, [ job("DetectMarkersJob", at: since - 166, dur: 166_000.0, queue: "heavy", span: "0ca0d9a8105bba71") ] +
        spread(9, ending: now) { |at, _| job("AnalyzeMediaFileJob", at: at, dur: 27_000.0, queue: "heavy", wait: 43_020_000.0) } +
        [ wire_log("Performing DetectMarkersJob (Job ID: 4936) from SolidQueue(heavy)", at: since + 60,
          trace: "b2e2b94ea5efaa238da3e3ebb16a8d29", span: "3b822cb75c13db23") ], kind: "worker", host: host)
    end

    def sampled(threads:, from: since)
      minutes = ((now - from) / 60).floor
      write_batch(stream, Array.new(minutes) do |minute|
        profile(at: from + minute * 60, transaction: "DetectMarkersJob", functions: { "IO#wait_readable" => 6000 * threads }, state: "idle")
      end, kind: "worker", host: host)
    end

    it "is found, and ranks above the queue wait it causes" do
      sampled(threads: 2)

      findings = described_class.scan(household, window: window)
      stuck = findings.find { |finding| finding.subject.kind == Triage::Kind::Stuck }
      expect(stuck.title).to eq("stream · DetectMarkersJob has run 55 min without finishing")
      expect(stuck.figures).to include("threads" => 2, "hosts" => [ host ])
      expect(findings.index(stuck)).to be < findings.index { |finding| finding.subject.kind == Triage::Kind::Queue }

      detail = described_class.detail(household, window: window, subject: stuck.subject)
      started = detail.evidence.find { |evidence| evidence.title == "Started, never finished" }
      expect(started.rows.pluck("trace")).to eq([ "b2e2b94ea5efaa238da3e3ebb16a8d29" ])
    end

    it "is not found while it is within its habit" do
      sampled(threads: 1, from: now - 10.minutes)
      write_batch(stream, [ job("DetectMarkersJob", at: now - 11.minutes, dur: 60_000.0, queue: "heavy") ], kind: "worker", host: host)

      expect(found(Triage::Kind::Stuck)).to be_empty
    end
  end
end
