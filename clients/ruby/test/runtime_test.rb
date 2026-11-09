# frozen_string_literal: true

require_relative "test_helper"

class RuntimeTest < Minitest::Test
  # Thirteen Stream processes once wrote one untagged RSS series: a 970 MB
  # transcoder averaged with 70 MB forks. Each process's vitals carry its
  # kind, so the console can tell them apart.
  def test_a_process_s_vitals_carry_its_kind
    agg = Glass::Aggregator.new
    runtime = Glass::Runtime.new(Glass::Config.new, agg)
    runtime.sample("transcoder")
    runtime.sample("transcoder")
    records = agg.drain(force: true)

    rss = records.find { |r| r[:name] == "ruby.memory.rss_bytes" }
    assert rss, "RSS is sampled"
    assert_equal({ "process" => "transcoder" }, rss[:tags])
    %w[ruby.gc.count ruby.heap.live_slots ruby.threads ruby.yjit.enabled].each do |name|
      assert_equal({ "process" => "transcoder" }, records.find { |r| r[:name] == name }&.dig(:tags), name)
    end
  end

  def test_the_kind_is_read_at_each_sample
    agg = Glass::Aggregator.new
    runtime = Glass::Runtime.new(Glass::Config.new, agg)
    runtime.sample("web")
    runtime.sample("worker") # a Solid Queue fork renames itself after the fork
    kinds = agg.drain(force: true).select { |r| r[:name] == "ruby.threads" }.map { |r| r[:tags]["process"] }
    assert_equal %w[web worker], kinds.sort
  end
end
