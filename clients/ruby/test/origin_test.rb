# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/glass/net_http"

class OriginTest < Minitest::Test
  include GlassTestSupport

  # The conformance kit every client shares (spec/fixtures/ingest): the
  # Node client reads the same cases, so a visitor is the same class and the
  # same hash whichever agent relayed them.
  KIT = File.expand_path("../../../spec/fixtures/ingest/origin.json", __dir__)

  def setup
    Glass::Origin.reset!
  end

  def test_the_conformance_kit
    skip "no conformance kit beside this copy of the gem" unless File.exist?(KIT)

    JSON.parse(File.read(KIT))["cases"].each do |kase|
      env = {
        "REMOTE_ADDR" => kase["remote"], "HTTP_X_FORWARDED_FOR" => kase["forwarded"],
        "HTTP_CF_CONNECTING_IP" => kase["cf_connecting_ip"], "HTTP_CF_RAY" => kase["cf_ray"]
      }.compact
      address, origin = Glass::Origin.classify_with_address(env, Glass::Config.new.vpn_networks)
      assert_equal [kase["address"], kase["origin"]], [address, origin], kase.inspect
    end
  end

  # Where `traceparent` goes: the same hosts from every client.
  def test_the_propagation_kit
    skip "no conformance kit beside this copy of the gem" unless File.exist?(KIT)

    kit = JSON.parse(File.read(KIT))
    configure_glass(propagate_to: kit["propagate_to"])
    kit["propagate"].each do |kase|
      assert_equal kase["propagate"], Glass::NetHttp.propagate?(kase["host"]), kase.inspect
    end
  end

  def test_configured_vpn_ranges_are_ours_too
    configure_glass
    refute Glass::NetHttp.propagate?("203.0.113.9")
    configure_glass(vpn_ranges: ["203.0.113.0/24"])
    assert Glass::NetHttp.propagate?("203.0.113.9")
  end

  def test_a_client_cannot_pick_its_own_class_with_its_own_header
    nets = Glass::Config.new.vpn_networks
    assert_equal "public", Glass::Origin.classify({ "REMOTE_ADDR" => "10.0.0.2", "HTTP_X_FORWARDED_FOR" => "192.168.1.5, 203.0.113.9" }, nets)
  end
end

class BoundedCacheTest < Minitest::Test
  def test_remembers_any_answer_and_clears_when_full
    cache = Glass::BoundedCache.new(3)
    calls = 0
    2.times { assert_equal false, cache.fetch(:a) { calls += 1; false } }
    assert_nil cache.fetch(:b) { nil }
    assert_nil cache.fetch(:b) { raise "remembered" }
    assert_equal 1, calls, "false and nil are answers too"
    cache.fetch(:c) { 3 }
    assert_equal 3, cache.size
    cache.fetch(:d) { 4 }
    assert_equal 1, cache.size, "full: cleared, not evicted"
  end
end
