# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppHealth do
  let(:household) { create_household }
  let(:hook) { create_app(household: household, slug: "hook") }
  let(:feed) { create_app(household: household, slug: "feed") }

  it "keeps the kinds an app reported per app, so a list and one app's page share them" do
    write_batch(hook, [ wire_txn(kind: "request") ])
    expect(described_class.kinds_for([ hook.telemetry_id, feed.telemetry_id ])).to eq(hook.telemetry_id => [ "request" ])

    write_batch(hook, [ wire_txn(kind: "job") ])
    write_batch(feed, [ wire_txn(kind: "job") ])
    # Both remembered from the list, the empty answer too.
    expect(described_class.kinds_for([ feed.telemetry_id ])).to eq({})
    expect(described_class.kinds_for([ hook.telemetry_id ])).to eq(hook.telemetry_id => [ "request" ])

    Rails.cache.clear
    expect(described_class.kinds_for([ feed.telemetry_id, hook.telemetry_id ]))
      .to eq(hook.telemetry_id => %w[job request], feed.telemetry_id => [ "job" ])
  end

  describe ".for" do
    def process(app, pid, release:, seen:)
      Telemetry::AgentProcess.create!(app_id: app.telemetry_id, kind: "web", host: "h", pid: pid, release: release, last_seen_at: seen)
    end

    it "counts each app's processes, live and all, and names the release its newest process runs, in one query" do
      now = Time.current
      process(hook, 1, release: "old", seen: now - 2.hours)
      process(hook, 2, release: "new", seen: now - 5.seconds)
      process(hook, 3, release: "mid", seen: now - 10.seconds)
      process(feed, 4, release: nil, seen: now - 1.day)
      quiet = create_app(household: household, slug: "quiet")

      summaries = nil
      queries = count_queries(matching: /FROM "processes"/) { summaries = described_class.for([ hook, feed, quiet ]) }

      expect(queries.size).to eq(1)
      expect(summaries.keys).to contain_exactly(hook.telemetry_id, feed.telemetry_id)
      expect(summaries.fetch(hook.telemetry_id)).to have_attributes(live_processes: 2, processes: 3, release: "new")
      expect(summaries.fetch(hook.telemetry_id).last_seen_at).to be_within(0.001).of(now - 5.seconds)
      expect(summaries.fetch(feed.telemetry_id)).to have_attributes(live_processes: 0, processes: 1, release: nil)
    end
  end
end
