# frozen_string_literal: true

require_relative "test_helper"

class TracerTest < Minitest::Test
  include GlassTestSupport

  # --- tail sampling ---------------------------------------------------------

  def test_first_sight_error_slow_and_draw_keep_spans
    s = Glass::Sampler.new
    assert s.keep?("A#x", 10.0, false, 0.0), "first sight of a name keeps"
    refute s.keep?("A#x", 10.0, false, 0.0), "second ordinary one does not"
    assert s.keep?("A#x", 10.0, true, 0.0), "errors always keep"
    assert s.keep?("A#x", 10.0, false, 0.5, 0.2), "a winning draw keeps"
    refute s.keep?("A#x", 10.0, false, 0.5, 0.9), "a losing draw does not"
    # Below MIN_OBSERVATIONS a fast endpoint's outlier is not yet "slow".
    refute s.keep?("A#x", 500.0, false, 0.0)
    30.times { s.keep?("B#y", 10.0, false, 0.0) }
    assert s.keep?("B#y", 11.0, false, 0.0), "slower than the running p95 keeps"
    refute s.keep?("B#y", 9.0, false, 0.0)
  end

  def test_sampler_caps_tracked_names
    s = Glass::Sampler.new
    Glass::Sampler::MAX_NAMES.times { |i| s.keep?("N#{i}", 1.0, false, 0.0) }
    refute s.keep?("overflow", 1.0, false, 0.0), "past the cap a new name is not 'first'"
    assert s.keep?("overflow", 1.0, true, 0.0)
  end

  def test_transaction_row_always_sent_spans_only_when_kept
    sender = configure_glass(trace_sample_rate: 0.0)
    app = lambda do |_env|
      txn = Glass::Tracer.current
      txn.name = "Wants#index"
      txn.sql("Want Load", "SELECT ?", Process.clock_gettime(Process::CLOCK_MONOTONIC), 1.0, false)
      [200, {}, ["ok"]]
    end
    mw = Glass::Middleware.new(app)
    env = { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/w", "REMOTE_ADDR" => "127.0.0.1" }
    3.times { mw.call(env) }
    Glass.flush(timeout: 2)
    txns = sender.records("txn")
    spans = sender.records("span")
    assert_equal 3, txns.size
    assert_equal [true, false, false], txns.map { |t| t["kept"] }
    assert_equal 1, spans.size
    assert_equal txns.first["trace"], spans.first["trace"]
    assert_equal txns.first["span"], spans.first["parent"]
    assert_equal "SELECT ?", spans.first["res"]
  end

  def test_red_metrics_come_from_every_transaction
    sender = configure_glass(trace_sample_rate: 0.0)
    app = lambda do |env|
      txn = Glass::Tracer.current
      txn.name = "Wants#index"
      txn.sql("Q", "SELECT ?", Process.clock_gettime(Process::CLOCK_MONOTONIC), 0.1, false)
      [env["fail"] ? 500 : 200, {}, []]
    end
    mw = Glass::Middleware.new(app)
    2.times { mw.call({ "REQUEST_METHOD" => "GET", "PATH_INFO" => "/w" }) }
    mw.call({ "REQUEST_METHOD" => "GET", "PATH_INFO" => "/w", "fail" => true })
    Glass.flush(timeout: 2) # final: drains the open window too
    metrics = sender.records("metric").group_by { |m| m["name"] }
    counts = metrics["rails.request.count"]
    assert_equal 2.0, counts.find { |m| m["tags"] == { "name" => "Wants#index", "status" => "2xx" } }["sum"]
    assert_equal 1.0, counts.find { |m| m["tags"] == { "name" => "Wants#index", "status" => "5xx" } }["sum"]
    assert_equal 1.0, metrics["rails.request.errors"].first["sum"]
    dur = metrics["rails.request.duration"].first
    assert_equal 3, dur["n"]
    assert_equal "ms", dur["unit"]
    assert_kind_of Array, dur["sk"]
    errored = sender.records("txn").find { |t| t["http"] == 500 }
    assert_equal "error", errored["status"], "a 5xx is an error even without an exception"
    assert_equal true, errored["kept"], "and errors keep their spans"
  end

  # --- identity ---------------------------------------------------------------

  def test_identity_modes
    configure_glass(api_key: "secret-key", user: -> { 42 }, user_name: -> { "Dave" })
    c = Glass.config
    c.identity = "anonymous"
    assert_nil Glass::Tracer.resolve_user
    c.identity = "pseudonymous"
    pseudo = Glass::Tracer.resolve_user
    assert_match(/\Au_[0-9a-f]{16}\z/, pseudo)
    require "openssl"
    assert_equal "u_" + OpenSSL::HMAC.hexdigest("SHA256", "secret-key", "42")[0, 16], pseudo
    c.identity = "named"
    assert_equal "Dave", Glass::Tracer.resolve_user
    c.user_name = -> { nil }
    assert_equal pseudo, Glass::Tracer.resolve_user, "named falls back to the pseudonymous form"
    c.user = -> { nil }
    assert_nil Glass::Tracer.resolve_user, "no user id, no user"
    c.user = -> { raise "boom" }
    assert_nil Glass::Tracer.resolve_user, "a broken resolver is counted, never raised"
  end

  def test_hmac_matches_openssl_for_long_keys
    require "openssl"
    key = "k" * 100
    assert_equal OpenSSL::HMAC.hexdigest("SHA256", key, "msg"), Glass::Tracer.hmac_sha256_hex(key, "msg")
  end

  # --- origin -------------------------------------------------------------------

  def test_origin_classification
    nets = Glass::Config.new.vpn_networks
    lan = { "REMOTE_ADDR" => "192.168.1.20" }
    assert_equal "lan", Glass::Origin.classify(lan, nets)
    assert_equal "lan", Glass::Origin.classify({ "REMOTE_ADDR" => "127.0.0.1" }, nets)
    assert_equal "lan", Glass::Origin.classify({ "REMOTE_ADDR" => "::1" }, nets)
    assert_equal "lan", Glass::Origin.classify({ "REMOTE_ADDR" => "fd12::1" }, nets)
    assert_equal "lan", Glass::Origin.classify({ "REMOTE_ADDR" => "::ffff:10.1.2.3" }, nets)
    assert_equal "vpn", Glass::Origin.classify({ "REMOTE_ADDR" => "172.18.0.5", "HTTP_X_FORWARDED_FOR" => "100.88.7.21" }, nets)
    assert_equal "public", Glass::Origin.classify({ "REMOTE_ADDR" => "172.18.0.5", "HTTP_X_FORWARDED_FOR" => "203.0.113.9" }, nets)
    assert_equal "public", Glass::Origin.classify({ "REMOTE_ADDR" => "172.18.0.5", "HTTP_X_FORWARDED_FOR" => "192.168.1.5, 203.0.113.9" }, nets),
      "a spoofed private hop before the real public address does not make it LAN"
    assert_equal "tunnel", Glass::Origin.classify({ "REMOTE_ADDR" => "172.18.0.5", "HTTP_CF_CONNECTING_IP" => "203.0.113.9" }, nets)
    assert_equal "tunnel", Glass::Origin.classify({ "REMOTE_ADDR" => "172.18.0.5", "HTTP_CF_RAY" => "abc" }, nets)
    assert_nil Glass::Origin.classify({}, nets)
    assert_equal "lan", Glass::Origin.classify({ "REMOTE_ADDR" => "unix:", "HTTP_X_FORWARDED_FOR" => "10.0.0.9" }, nets)
    custom = Glass::Config.new
    custom.vpn_ranges = ["10.8.0.0/24"]
    assert_equal "vpn", Glass::Origin.classify({ "REMOTE_ADDR" => "10.8.0.3" }, custom.vpn_networks)
  end

  # --- request naming and headers -----------------------------------------------

  def test_requests_without_a_controller_are_named_by_status
    sender = configure_glass
    mw = Glass::Middleware.new(->(env) { [env["status"], {}, []] })
    mw.call({ "REQUEST_METHOD" => "GET", "PATH_INFO" => "/missing", "status" => 404 })
    mw.call({ "REQUEST_METHOD" => "GET", "PATH_INFO" => "/app.js", "status" => 200 })
    mw.call({ "REQUEST_METHOD" => "POST", "PATH_INFO" => "/x", "status" => 200 })
    Glass.flush(timeout: 2)
    assert_equal ["(404)", "(static)", "(200)"], sender.records("txn").map { |t| t["name"] }
  end

  def test_ignored_paths_produce_nothing_not_even_logs
    require_relative "../lib/glass/logs"
    sender = configure_glass
    calls = 0
    mw = Glass::Middleware.new(->(_) { calls += 1; Glass::Logs.record(1, "during #{calls}"); [200, {}, []] })
    mw.call({ "REQUEST_METHOD" => "GET", "PATH_INFO" => "/up" })
    mw.call({ "REQUEST_METHOD" => "POST", "PATH_INFO" => "/ingest/v1/batch" })
    mw.call({ "REQUEST_METHOD" => "GET", "PATH_INFO" => "/traced" })
    Glass.flush(timeout: 2)
    assert_equal 3, calls
    assert_equal 1, sender.records("txn").size
    assert_equal ["during 3"], sender.records("log").map { |l| l["msg"] }, "an ignored request's log lines stay home"
    assert_nil Thread.current[:glass_muted]
  end

  def test_visit_queue_time_and_inbound_traceparent
    sender = configure_glass
    mw = Glass::Middleware.new(->(_) { [200, {}, []] })
    start = ((Time.now.to_f - 0.250) * 1000).to_i
    mw.call({
      "REQUEST_METHOD" => "GET", "PATH_INFO" => "/w", "QUERY_STRING" => "a=1",
      "HTTP_X_GLASS_VISIT" => "v_51aa", "HTTP_X_REQUEST_START" => "t=#{start}",
      "HTTP_TRACEPARENT" => "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    })
    Glass.flush(timeout: 2)
    txn = sender.records("txn").first
    assert_equal "v_51aa", txn["visit"]
    assert_equal "/w", txn["path"], "no query string"
    assert_equal "4bf92f3577b34da6a3ce929d0e0e4736", txn["trace"]
    assert_equal "00f067aa0ba902b7", txn["parent"]
    assert_in_delta 250.0, txn["queue_ms"], 100.0 if txn["queue_ms"]
  end

  # An app whose URLs name what it must not send keeps the template and
  # drops the concrete path.
  def test_record_paths_off_sends_no_path
    sender = configure_glass(record_paths: false)
    mw = Glass::Middleware.new(->(_) { [200, {}, []] })
    mw.call({ "REQUEST_METHOD" => "GET", "PATH_INFO" => "/ingredients/magnesium-glycinate" })
    Glass.flush(timeout: 2)
    txn = sender.records("txn").first
    refute txn.key?("path"), "no concrete path"
    refute_includes sender.bodies.map { |b| Zlib.gunzip(b) }.join, "magnesium"
  end

  def test_queue_time_units
    now = 1_790_000_000.0
    assert_in_delta 250.0, Glass::Tracer.queue_ms("t=1789999999.75", now), 0.001
    assert_in_delta 250.0, Glass::Tracer.queue_ms("1789999999750", now), 0.001
    assert_in_delta 250.0, Glass::Tracer.queue_ms("1789999999750000", now), 0.001
    assert_in_delta 250.0, Glass::Tracer.queue_ms("1789999999750000000", now), 0.001
    assert_nil Glass::Tracer.queue_ms("junk", now)
    assert_nil Glass::Tracer.queue_ms("t=1790000001", now), "a start in the future is not a queue time"
  end

  def test_exception_in_the_app_marks_the_transaction_and_re_raises
    sender = configure_glass
    mw = Glass::Middleware.new(->(_) { raise ArgumentError, "boom" })
    assert_raises(ArgumentError) { mw.call({ "REQUEST_METHOD" => "GET", "PATH_INFO" => "/w" }) }
    assert_nil Glass::Tracer.current, "the fiber-local transaction is cleared"
    Glass.flush(timeout: 2)
    txn = sender.records("txn").first
    assert_equal "error", txn["status"]
    assert_equal "ArgumentError", txn["error"]
    assert_equal 500, txn["http"]
  end

  def test_public_api_inside_a_transaction
    sender = configure_glass
    app = lambda do |_env|
      Glass::Tracer.current.name = "X#y"
      Glass.tag(want_id: 7, password: "no")
      Glass.span("verify", resource: "import") { Glass.time("inner") { :ok } }
      assert_equal Glass::Tracer.current.trace_id, Glass.trace_id
      assert_match(/\A00-#{Glass.trace_id}-[0-9a-f]{16}-01\z/, Glass.traceparent)
      [200, {}, []]
    end
    Glass::Middleware.new(app).call({ "REQUEST_METHOD" => "GET", "PATH_INFO" => "/w" })
    Glass.flush(timeout: 2)
    txn = sender.records("txn").first
    assert_equal({ "want_id" => 7, "password" => "[FILTERED]" }, txn["attrs"])
    spans = sender.records("span")
    assert_equal %w[verify inner], spans.map { |s| s["name"] }
    assert_equal "import", spans[0]["res"]
    assert_equal spans[0]["span"], spans[1]["parent"]
  end
end
