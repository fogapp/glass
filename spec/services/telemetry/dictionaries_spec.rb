# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Telemetry::Dictionaries do
  let(:now) { Time.now.utc }
  let(:setting) { AppSetting.current }

  def series(name, last_seen_at:)
    Telemetry::MetricSeries.create!(app_id: 1, name: name, kind: "gauge", tags: {}, tags_hash: name.hash.abs,
      first_seen_at: last_seen_at, last_seen_at: last_seen_at).id
  end

  def function(name)
    Telemetry::ProfileFunction.create!(app_id: 1, digest: Telemetry::ProfileFunction.identity(name, ""), name: name).id
  end

  def stack(frames)
    Telemetry::ProfileStack.create!(app_id: 1, digest: Telemetry::ProfileStack.identity(frames), frames: frames).id
  end

  describe ".prune!" do
    it "removes series silent for longer than any tier of points is kept, unless a raw point still names one" do
      gone = series("gone", last_seen_at: now - 3.years)
      waiting = series("waiting", last_seen_at: now - 3.years)
      Telemetry::MetricPoint.insert_all([ { series_id: waiting, ts: now - 1.minute, n: 1, sum: 1 } ]) # rubocop:disable Rails/SkipsModelValidations
      recent = series("recent", last_seen_at: now - 2.days)
      # Kept for 730 days in the hourly tier, so a year's silence is not enough.
      quiet = series("quiet", last_seen_at: now - 1.year)

      pruned = described_class.prune!(setting: setting, now: now)

      expect(pruned["metric_series"]).to eq(1)
      expect(Telemetry::MetricSeries.where(id: [ gone, waiting, recent, quiet ]).pluck(:id)).to contain_exactly(waiting, recent, quiet)
    end

    it "reads the cutoff from each tier's retention, overrides included" do
      setting.update!(retention_days: { "metric_points_5m" => 10, "metric_points_1h" => 20 })
      expect(described_class.series_cutoff(setting, now)).to eq(now - 21.days)

      old = series("old", last_seen_at: now - 30.days)
      kept = series("kept", last_seen_at: now - 15.days)
      described_class.prune!(setting: setting, now: now)
      expect(Telemetry::MetricSeries.where(id: [ old, kept ]).pluck(:id)).to eq([ kept ])
    end

    it "removes the stacks no sample names, then the functions no remaining stack names" do
      main, shared, orphan, unused = %w[main shared orphan unused].map { |name| function(name) }
      sampled = stack([ main, shared ])
      dropped = stack([ shared, orphan ])
      Telemetry::ProfileSample.insert_all([ # rubocop:disable Rails/SkipsModelValidations
        { ts: now - 1.minute, app_id: 1, stack_id: sampled, samples: 3, ms: 30 }
      ])

      pruned = described_class.prune!(setting: setting, now: now)

      expect(pruned).to include("profile_stacks" => 1, "profile_functions" => 2)
      expect(Telemetry::ProfileStack.where(id: [ sampled, dropped ]).pluck(:id)).to eq([ sampled ])
      expect(Telemetry::ProfileFunction.where(id: [ main, shared, orphan, unused ]).pluck(:id)).to contain_exactly(main, shared)
    end

    it "deletes in batches until nothing is left" do
      stub_const("Telemetry::Dictionaries::BATCH", 2)
      ids = (1..5).map { |i| stack([ function("f#{i}") ]) }
      expect(described_class.prune!(setting: setting, now: now)).to include("profile_stacks" => 5, "profile_functions" => 5)
      expect(Telemetry::ProfileStack.where(id: ids)).to be_empty
    end
  end

  describe ".prune_if_due!" do
    it "prunes at most once a UTC day" do
      day = Time.utc(2026, 11, 8, 0, 7)
      expect(described_class.prune_if_due!(setting: setting, now: day)).to include("profile_stacks" => 0)

      orphan = stack([ function("late") ])
      expect(described_class.prune_if_due!(setting: setting, now: day + 23.hours)).to eq({})
      expect(Telemetry::ProfileStack.where(id: orphan)).to exist

      expect(described_class.prune_if_due!(setting: setting, now: day + 24.hours)).to include("profile_stacks" => 1)
      expect(Telemetry::ProfileStack.where(id: orphan)).not_to exist
      expect(Telemetry::Cursor.position(described_class::CURSOR)).to eq(day + 24.hours)
    end
  end

  describe "the disk budget" do
    it "counts the dictionaries, without ever shedding them" do
      expect(described_class.bytes).to be_positive
      expect(Telemetry::Partitions.total_bytes).to eq(Telemetry::Partitions.list.sum(&:bytes) + described_class.bytes)

      partitions = Telemetry::Partitions.list
      budget = partitions.sum(&:bytes)
      # Just under budget on partitions alone: nothing to shed until the
      # dictionaries are counted.
      expect(Telemetry::Partitions.shed_to_budget!(budget_bytes: budget, partitions: partitions, fixed_bytes: 0)).to be_empty
      shed = Telemetry::Partitions.shed_to_budget!(budget_bytes: budget, partitions: partitions, fixed_bytes: 1)
      expect(shed.size).to eq(1)
      expect(shed.map(&:table)).not_to include(*Telemetry::Tables::DICTIONARIES)
    ensure
      Telemetry::Partitions.ensure!
    end
  end

  describe "ingest's caches" do
    let(:app) { create_app(household: create_household) }
    let(:point) { Ingest::Records::Metric::Point.new(ts: now, name: "q", kind: Telemetry::MetricSeries::Kind::Gauge, unit: nil, tags: {}, n: 1, sum: 1.0, min: 1.0, max: 1.0, last: 1.0, sketch: nil) }

    it "forgets a series id after the TTL, so a pruned one is created again rather than written" do
      first = Ingest::SeriesResolver.resolve(app, [ point ]).first
      Telemetry::MetricSeries.where(id: first).delete_all
      expect(Ingest::SeriesResolver.resolve(app, [ point ]).first).to eq(first) # within the TTL: remembered

      stub_const("Telemetry::Dictionaries::CACHE_TTL", 0.seconds)
      again = Ingest::SeriesResolver.resolve(app, [ point ]).first
      expect(again).not_to eq(first)
      expect(Telemetry::MetricSeries.exists?(again)).to be(true)
    end
  end
end
