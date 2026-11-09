# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
  include GlassTestSupport

  def with_env(values)
    old = values.to_h { |k, _| [k, ENV[k]] }
    values.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def test_inert_without_both_values
    with_env("GLASS_URL" => nil, "GLASS_API_KEY" => nil) do
      Glass.reset!
      refute Glass.enabled?
      threads_before = Thread.list.size
      # Every public entry point is a no-op that starts nothing.
      assert_nil Glass.increment("x")
      assert_nil Glass.gauge("x", 1)
      assert_nil Glass.histogram("x", 1)
      assert_nil Glass.timing("x", 1)
      assert_nil Glass.set("x", 1)
      assert_nil Glass.event("x")
      assert_nil Glass.tag(a: 1)
      assert_equal 42, Glass.time("x") { 42 }
      assert_equal 43, Glass.span("x") { 43 }
      assert_nil Glass.trace_id
      assert_nil Glass.current_transaction
      assert_nil Glass.start
      assert_equal threads_before, Thread.list.size, "inert Glass must start no thread"
      assert_equal [200, {}, ["ok"]], Glass::Middleware.new(->(_) { [200, {}, ["ok"]] }).call({ "PATH_INFO" => "/" })
    end
    with_env("GLASS_URL" => "http://glass", "GLASS_API_KEY" => nil) do
      Glass.reset!
      refute Glass.enabled?, "a URL without a key is not configured"
    end
    with_env("GLASS_URL" => "http://glass", "GLASS_API_KEY" => "glass_ing_x") do
      Glass.reset!
      assert Glass.enabled?
      assert_equal "http://glass/ingest/v1/batch", Glass.config.endpoint
    end
  end

  def test_configure_after_env_check_takes_effect
    with_env("GLASS_URL" => nil, "GLASS_API_KEY" => nil) do
      Glass.reset!
      refute Glass.enabled?
      Glass.configure { |c| c.url = "http://glass/"; c.api_key = "k" }
      assert Glass.enabled?
      assert_equal "http://glass/ingest/v1/batch", Glass.config.endpoint
    end
  end

  def test_directives_override_runtime_settings_and_ignore_unknown
    c = Glass::Config.new
    request = c.apply_directives(
      "trace_sample_rate" => 0.5, "profiling" => false, "profile_hz" => 250, "log_level" => "warn",
      "browser" => true, "identity" => "named", "profile_now" => { "id" => "abc", "seconds" => 5, "hz" => 500 },
      "something_new" => 1
    )
    assert_in_delta 0.5, c.trace_sample_rate
    assert_equal false, c.profiling
    assert_equal 250, c.profile_hz
    assert_equal "warn", c.log_level
    assert_equal 2, c.log_threshold
    assert_equal true, c.browser
    assert_equal "named", c.identity
    assert_equal({ "id" => "abc", "seconds" => 5, "hz" => 500 }, request)
    # Junk values keep the previous setting; clamps apply.
    c.apply_directives("trace_sample_rate" => "lots", "profile_hz" => 99_999, "identity" => "everyone", "log_level" => "loud")
    assert_in_delta 0.5, c.trace_sample_rate
    assert_equal 1_000, c.profile_hz
    assert_equal "named", c.identity
    assert_equal "warn", c.log_level
    assert_nil c.apply_directives(nil)
    assert_nil c.apply_directives("profile_now" => nil)
  end

  def test_local_feature_switch_wins_over_profiling_directive
    c = Glass::Config.new
    c.apply_directives("profiling" => true)
    assert c.profiling_active?
    c.enabled[:profiling] = false
    refute c.profiling_active?
  end

  def test_process_kind_env_program_name_and_default
    with_env("GLASS_PROCESS" => "cron") do
      assert_equal "cron", Glass::Config.new.process_kind
    end
    with_env("GLASS_PROCESS" => nil) do
      c = Glass::Config.new
      assert_equal "web", c.process_kind
      old = $PROGRAM_NAME
      begin
        $PROGRAM_NAME = "solid-queue-worker(1.6.0): waiting"
        assert_equal "worker", c.process_kind
        $PROGRAM_NAME = "/app/bin/jobs"
        assert_equal "worker", c.process_kind
      ensure
        $PROGRAM_NAME = old
      end
      c.process_kind = "web"
      assert_equal "web", c.process_kind
    end
  end

  def test_ignore_paths_prefix_match_with_defaults
    c = Glass::Config.new
    assert c.ignore_path?("/up")
    assert c.ignore_path?("/ingest/v1/batch")
    refute c.ignore_path?("/api/v1/wants")
    c.ignore_paths = ["/assets"]
    assert c.ignore_path?("/assets/app.js")
    refute c.ignore_path?("/up")
  end

  def test_release_prefers_env_then_revision_file
    with_env("GIT_SHA" => "abc123", "GIT_REV" => nil) do
      assert_equal "abc123", Glass::Config.new.release
    end
    with_env("GIT_SHA" => nil, "GIT_REV" => "def456") do
      assert_equal "def456", Glass::Config.new.release
    end
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "REVISION"), "  fromfile \n")
      with_env("GIT_SHA" => nil, "GIT_REV" => nil) do
        c = Glass::Config.new
        c.app_root = dir
        assert_equal "fromfile", c.release
      end
    end
  end

  def test_scrub_filters_sensitive_keys_deeply_and_honors_rails_filters
    c = Glass::Config.new
    c.rails_filters = [:ssn, /card/]
    scrubbed = c.scrub({
      "password" => "hunter2", "user" => { api_key: "k", name: "dave" },
      "list" => [{ "session_token" => "x" }], "ssn" => "1", "card_number" => "4", "fine" => "keep"
    })
    assert_equal Glass::Config::FILTERED, scrubbed["password"]
    assert_equal Glass::Config::FILTERED, scrubbed["user"][:api_key]
    assert_equal "dave", scrubbed["user"][:name]
    assert_equal Glass::Config::FILTERED, scrubbed["list"][0]["session_token"]
    assert_equal Glass::Config::FILTERED, scrubbed["ssn"]
    assert_equal Glass::Config::FILTERED, scrubbed["card_number"]
    assert_equal "keep", scrubbed["fine"]
  end

  def test_vpn_networks_include_cgnat_and_configured_ranges_skipping_junk
    c = Glass::Config.new
    c.vpn_ranges = ["10.8.0.0/24", "not a range"]
    nets = c.vpn_networks
    assert_equal 2, nets.size
    assert nets.any? { |n| n.include?(IPAddr.new("100.100.1.1")) }
    assert nets.any? { |n| n.include?(IPAddr.new("10.8.0.7")) }
  end

  # The conformance kit every client shares: a key is filtered by every
  # client or by none (the Node client reads the same file).
  FILTER_KIT = File.expand_path("../../../spec/fixtures/ingest/filter.json", __dir__)

  def test_filter_keys_match_the_conformance_kit
    skip "no conformance kit beside this copy of the gem" unless File.exist?(FILTER_KIT)

    kit = JSON.parse(File.read(FILTER_KIT))
    c = Glass::Config.new
    kit["filtered"].each { |key| assert_equal({ key => Glass::Config::FILTERED }, c.scrub(key => "value"), key) }
    kit["kept"].each { |key| assert_equal({ key => "value" }, c.scrub(key => "value"), key) }
  end
end
