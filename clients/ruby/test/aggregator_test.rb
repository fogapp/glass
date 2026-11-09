# frozen_string_literal: true

require_relative "test_helper"

class AggregatorTest < Minitest::Test
  T0 = 1_790_000_120 # a window start (multiple of 10)

  def test_each_kind_becomes_one_record_per_series_per_window
    agg = Glass::Aggregator.new
    agg.counter("wants.created", 1, { kind: "book" }, T0 + 1)
    agg.counter("wants.created", 2, { kind: "book" }, T0 + 9)
    agg.counter("wants.created", 1, { kind: "film" }, T0 + 2)
    agg.gauge("indexers.healthy", 7, {}, T0 + 3)
    agg.gauge("indexers.healthy", 5, {}, T0 + 4)
    agg.dist("nzb.size_bytes", 100.0, {}, "bytes", T0 + 5)
    agg.dist("nzb.size_bytes", 300.0, {}, "bytes", T0 + 6)
    agg.set("readers.active", 1, {}, T0 + 7)
    agg.set("readers.active", 2, {}, T0 + 7)
    agg.set("readers.active", 1, {}, T0 + 8)

    assert_empty agg.drain(T0 + 9), "the window is still open"
    records = agg.drain(T0 + 10)
    assert_equal 5, records.size
    by = records.group_by { |r| [r[:name], r[:tags]] }

    counter = by[["wants.created", { "kind" => "book" }]].first
    assert_equal({ t: "metric", ts: T0, name: "wants.created", kind: "counter", tags: { "kind" => "book" }, n: 2, sum: 3.0 }, counter)
    assert_equal 1.0, by[["wants.created", { "kind" => "film" }]].first[:sum]

    gauge = by[["indexers.healthy", nil]].first
    assert_equal "gauge", gauge[:kind]
    assert_equal [2, 12.0, 5.0, 7.0, 5.0], gauge.values_at(:n, :sum, :min, :max, :last)
    refute gauge.key?(:tags), "absent optional fields are absent"

    dist = by[["nzb.size_bytes", nil]].first
    assert_equal "dist", dist[:kind]
    assert_equal "bytes", dist[:unit]
    assert_equal [2, 400.0, 100.0, 300.0, 300.0], dist.values_at(:n, :sum, :min, :max, :last)
    assert_equal [Glass::Sketch.index_for(100.0), 1, Glass::Sketch.index_for(300.0), 1], dist[:sk]

    set = by[["readers.active", nil]].first
    assert_equal({ t: "metric", ts: T0, name: "readers.active", kind: "set", n: 2 }, set)
    assert_empty agg.drain(T0 + 20), "drained windows are gone"
  end

  def test_windows_align_to_the_wall_clock_and_drain_only_closed_ones
    agg = Glass::Aggregator.new
    agg.counter("a", 1, {}, T0 + 9)
    agg.counter("a", 1, {}, T0 + 10)
    agg.counter("a", 1, {}, T0 + 19)
    records = agg.drain(T0 + 20)
    assert_equal [T0, T0 + 10], records.map { |r| r[:ts] }
    assert_equal [1.0, 2.0], records.map { |r| r[:sum] }
    agg.counter("a", 1, {}, T0 + 25)
    assert_empty agg.drain(T0 + 29)
    assert_equal 1, agg.drain(T0 + 29, force: true).size, "force drains the open window (exit)"
  end

  def test_tags_are_sorted_stringified_and_capped
    agg = Glass::Aggregator.new
    agg.counter("a", 1, { b: 2, a: :x, n: nil }, T0)
    agg.counter("a", 1, { "a" => "x", "b" => "2" }, T0)
    records = agg.drain(T0 + 10)
    assert_equal 1, records.size, "same tags in any order/type are one series"
    assert_equal({ "a" => "x", "b" => "2" }, records.first[:tags])
    agg.counter("many", 1, (1..25).to_h { |i| ["k#{i}", "v" * 300] }, T0)
    rec = agg.drain(T0 + 10).first
    assert_equal Glass::Aggregator::MAX_TAGS, rec[:tags].size
    assert_equal Glass::Aggregator::MAX_TAG_VALUE, rec[:tags].values.first.size
  end

  def test_series_cap_drops_and_counts
    agg = Glass::Aggregator.new(max_series: 3)
    5.times { |i| agg.counter("s#{i}", 1, {}, T0) }
    agg.counter("s0", 1, {}, T0)
    assert_equal 2, agg.take_dropped
    assert_equal 0, agg.take_dropped, "counts are handed over once"
    assert_equal 3, agg.drain(T0 + 10).size
  end

  def test_invalid_names_and_values_are_dropped
    agg = Glass::Aggregator.new
    agg.counter("has space", 1, {}, T0)
    agg.counter("9starts.with.digit", 1, {}, T0)
    agg.gauge("ok", Float::NAN, {}, T0)
    agg.gauge("ok", "3", {}, T0)
    assert_equal 2, agg.take_dropped
    assert_empty agg.drain(T0 + 10)
  end

  def test_concurrent_updates_lose_nothing
    agg = Glass::Aggregator.new
    threads = 8.times.map { Thread.new { 1_000.times { agg.counter("c", 1, { t: "x" }, T0) } } }
    threads.each(&:join)
    assert_equal 8_000.0, agg.drain(T0 + 10).first[:sum]
  end
end
