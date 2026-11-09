# frozen_string_literal: true

require_relative "test_helper"

# The agent's sketch must map values exactly as the server's
# Telemetry::Sketch does (app/services/telemetry/sketch.rb): the two are
# merged by adding counts, so a bucket index that differs by one would
# silently skew every percentile. When the server's class can be loaded
# (sorbet-runtime in the bundle), it is used directly as the oracle; the
# pinned table below stands in otherwise.
class SketchTest < Minitest::Test
  SERVER_SKETCH = File.expand_path("../../../app/services/telemetry/sketch.rb", __dir__)

  def server_sketch
    return @server_sketch if defined?(@server_sketch)
    @server_sketch = begin
      require "sorbet-runtime"
      require SERVER_SKETCH
      Telemetry::Sketch
    rescue LoadError, StandardError
      nil
    end
  end

  VALUES = [1e-9, 2e-9, 1e-6, 0.5, 0.99, 1.0, 1.01, 1.02, 1.0201, 1.5, 2.0, 9.1, 31.0, 48.2, 100.0, 148.0,
            612.0, 1_000.0, 12_345.678, 1e6, 1e9].freeze
  # index = ceil(ln(v)/ln(1.02)); nil at or below 1e-9.
  PINNED = { 1e-9 => nil, 2e-9 => -1011, 1e-6 => -697, 0.5 => -35, 1.0 => 0, 1.01 => 1, 1.02 => 1,
             1.0201 => 2, 2.0 => 36, 100.0 => 233, 1_000.0 => 349, 1e6 => 698, 1e9 => 1047 }.freeze

  # The conformance kit every client shares (spec/fixtures/ingest). It is
  # in Glass's checkout, not in a vendored copy of the gem, where the pinned
  # table above stands in.
  KIT = File.expand_path("../../../spec/fixtures/ingest/sketch.json", __dir__)

  def test_the_conformance_kit
    skip "no conformance kit beside this copy of the gem" unless File.exist?(KIT)

    kit = JSON.parse(File.read(KIT))
    kit["indexes"].each do |entry|
      got = Glass::Sketch.index_for(entry["value"].to_f)
      entry["index"].nil? ? assert_nil(got, "index for #{entry['value']}") : assert_equal(entry["index"], got, "index for #{entry['value']}")
    end
    (kit["sketches"] + kit.fetch("folded", [])).each do |entry|
      sketch = Glass::Sketch.new
      entry["values"].each { |value| sketch.add(value.to_f) }
      assert_equal entry["sk"], sketch.to_pairs
    end
  end

  def test_index_mapping_matches_the_server
    oracle = server_sketch ? VALUES.to_h { |v| [v, server_sketch.index_for(v)] } : PINNED
    oracle.each do |v, expected|
      got = Glass::Sketch.index_for(v)
      expected.nil? ? assert_nil(got, "index for #{v}") : assert_equal(expected, got, "index for #{v}")
    end
    PINNED.each do |v, i|
      i.nil? ? assert_nil(Glass::Sketch.index_for(v)) : assert_equal(i, Glass::Sketch.index_for(v), "pinned index for #{v}")
    end
  end

  def test_bucket_value_matches_the_server
    [-35, 0, 1, 36, 233, 1047].each do |i|
      expected = server_sketch ? server_sketch.value_for(i) : 2.0 * (1.02**i) / 2.02
      assert_in_delta expected, Glass::Sketch.value_for(i), 1e-12
    end
  end

  def test_quantiles_within_relative_error_and_equal_to_the_servers
    values = (1..2_000).map { |i| (i**1.7) / 10.0 }
    sketch = Glass::Sketch.new
    values.each { |v| sketch.add(v) }
    sorted = values.sort
    [0.5, 0.9, 0.95, 0.99].each do |q|
      exact = sorted[(q * (sorted.size - 1)).floor]
      got = sketch.quantile(q)
      assert_in_delta exact, got, exact * 0.015, "p#{(q * 100).to_i} within 1.5%"
      if server_sketch
        theirs = server_sketch.from_pairs(sketch.to_pairs).quantile(q, total: sketch.count)
        assert_in_delta theirs, got, 1e-9, "server reads the same p#{(q * 100).to_i} from the wire form"
      end
    end
  end

  def test_unbucketed_values_count_toward_n_but_not_the_pairs
    sketch = Glass::Sketch.new
    sketch.add(0.0).add(-1.0).add(1e-10).add(5.0)
    assert_equal 4, sketch.count
    assert_equal [Glass::Sketch.index_for(5.0), 1], sketch.to_pairs
    assert_equal 0.0, sketch.quantile(0.5), "zeros sort first"
    assert_in_delta 5.0, sketch.quantile(1.0), 0.1
  end

  def test_pairs_are_ascending_by_index
    sketch = Glass::Sketch.new
    [50.0, 1.0, 1000.0, 1.0, 3.0].each { |v| sketch.add(v) }
    pairs = sketch.to_pairs
    indexes = pairs.each_slice(2).map(&:first)
    assert_equal indexes.sort, indexes
    assert_equal 2, pairs.each_slice(2).to_h[0], "two 1.0s in bucket 0"
  end

  def test_folds_lowest_buckets_past_the_servers_maximum
    sketch = Glass::Sketch.new
    (-1_100..1_100).each { |i| sketch.buckets[i] = 1 }
    pairs = sketch.to_pairs
    assert_equal Glass::Sketch::MAX_BUCKETS * 2, pairs.size
    assert_equal 1_100, pairs[-2]
    assert_equal 2_201 - Glass::Sketch::MAX_BUCKETS + 1, pairs[1], "the folded counts land in the lowest kept bucket"
  end
end
