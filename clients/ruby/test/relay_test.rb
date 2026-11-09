# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class RelayTest < Minitest::Test
  include GlassTestSupport

  VISIT = "v_3f9a1c2d8b7e"
  UA_IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

  def setup
    @sender = configure_glass
    Glass.config.browser = true
    @app_calls = 0
    @mw = Glass::Middleware.new(->(_env) { @app_calls += 1; [200, { "content-type" => "text/plain" }, ["app"]] })
  end

  def env(method, path, body: nil, headers: {}, remote: "192.168.1.9")
    e = { "REQUEST_METHOD" => method, "PATH_INFO" => path, "HTTP_HOST" => "app.example.net", "REMOTE_ADDR" => remote,
          "rack.input" => StringIO.new(body.to_s) }
    e["CONTENT_TYPE"] = "text/plain;charset=UTF-8" if body
    e["HTTP_ORIGIN"] = "http://app.example.net" if body
    headers.each { |k, v| e["HTTP_" + k.upcase.tr("-", "_")] = v }
    e
  end

  def beacon(events, visit: VISIT, headers: {}, **opts)
    body = JSON.generate(visit: visit, lang: "en-US", screen: "390x844", events: events)
    @mw.call(env("POST", "/_glass/b", body: body, headers: { "User-Agent" => UA_IPHONE }.merge(headers), **opts))
  end

  def pages
    Glass.flush(timeout: 2)
    @sender.records("page")
  end

  # --- the script -----------------------------------------------------------------

  def test_serves_the_shipped_script_with_etag_cache_and_gzip
    status, headers, body = @mw.call(env("GET", "/_glass/glass.js"))
    assert_equal 200, status
    assert_equal "application/javascript; charset=utf-8", headers["content-type"]
    assert_equal "public, max-age=86400", headers["cache-control"]
    assert_match(/\A"glass-#{Glass::VERSION}-[0-9a-f]{16}"\z/, headers["etag"])
    js = body.join
    assert_equal js.bytesize.to_s, headers["content-length"]
    assert_includes js, "w.glass = {"
    assert_includes js, "'/_glass/b'"
    assert_includes js, "X-Glass-Visit"
    assert_includes js, "sessionStorage"
    assert_includes js, "sendBeacon"
    assert_equal File.binread(File.expand_path("../../browser/glass.js", __dir__)), js, "the shipped copy is the canonical script"
    assert_operator Zlib.gzip(js).bytesize, :<=, 4096, "glass.js must stay within 4 KB gzipped"

    status, headers, body = @mw.call(env("GET", "/_glass/glass.js", headers: { "Accept-Encoding" => "br, gzip" }))
    assert_equal 200, status
    assert_equal "gzip", headers["content-encoding"]
    assert_equal js, Zlib.gunzip(body.join)

    status, _, body = @mw.call(env("GET", "/_glass/glass.js", headers: { "If-None-Match" => headers["etag"] }))
    assert_equal 304, status
    assert_empty body
    status, = @mw.call(env("GET", "/_glass/glass.js", headers: { "If-None-Match" => %(W/#{headers["etag"]}, "other") }))
    assert_equal 304, status
    assert_equal 0, @app_calls, "/_glass/* never reaches the app"
  end

  # Not a 404: a tag that sits in a page for good must not be an error in
  # every console. The Node client answers the same.
  def test_while_the_browser_directive_is_off_the_tag_costs_nothing_and_says_nothing
    Glass.config.browser = false
    status, headers, body = @mw.call(env("GET", "/_glass/glass.js"))
    assert_equal [200, "no-store", "0", []], [status, headers["cache-control"], headers["content-length"], body]
    assert_equal 204, beacon([{ "kind" => "pageview", "path" => "/" }])[0]
    Glass.config.browser = true
    Glass.config.enabled[:browser] = false
    assert_equal 200, @mw.call(env("GET", "/_glass/glass.js"))[0]
    assert_equal 204, beacon([{ "kind" => "pageview", "path" => "/" }])[0]
    assert_equal 404, @mw.call(env("GET", "/_glass/other"))[0]
    assert_equal 0, @app_calls
    assert_empty pages
  end

  # --- beacons --------------------------------------------------------------------------

  def test_beacon_events_become_page_records_with_agent_stamped_fields
    Glass.config.apply_directives("identity" => "pseudonymous")
    now = Time.now.to_f
    status, _, body = beacon([
      { "kind" => "pageview", "ts" => now - 1, "path" => "/wants/8c1f2a?q=1", "route" => "/wants/:id", "title" => "Hook · Wants", "ref" => "https://portal.example.net/today?x=1" },
      { "kind" => "pageview", "ts" => now, "path" => "/wants", "route" => "/wants", "title" => "Wants", "ref" => "https://portal.example.net/other" },
      { "kind" => "click", "ts" => now, "path" => "/wants", "route" => "/wants", "name" => "Add want",
        "el" => { "tag" => "button", "role" => "button", "sel" => "form > button.primary", "href" => "/wants?x=1", "extra" => "no" }, "props" => { "rage" => true } },
      { "kind" => "vital", "ts" => now, "path" => "/wants", "route" => "/wants", "vitals" => { "lcp" => 1840, "cls" => 0.02, "inp" => -5, "bogus" => 1 } },
      { "kind" => "custom", "ts" => now, "path" => "/wants", "route" => "/wants", "name" => "want.created", "props" => { "kind" => "book", "password" => "x", "n" => 3, "deep" => { "a" => 1 }, "long" => "y" * 500 } },
      { "kind" => "error", "ts" => now, "path" => "/wants", "route" => "/wants", "name" => "TypeError", "props" => { "file" => "/assets/app.js", "line" => 12 } },
      { "kind" => "vital", "ts" => now, "path" => "/wants", "route" => "/wants", "vitals" => {} },
      { "kind" => "custom", "ts" => now, "path" => "/wants" },
      { "kind" => "steal", "ts" => now, "path" => "/wants" },
      "junk"
    ], headers: { "X-Forwarded-For" => "100.88.7.21" }, remote: "172.18.0.5")
    assert_equal 204, status
    assert_empty body
    recs = pages
    assert_equal %w[pageview pageview click vital custom error], recs.map { |r| r["kind"] }
    recs.each do |r|
      assert_equal "page", r["t"]
      assert_equal VISIT, r["visit"]
      assert_match(/\Aa_[0-9a-f]{16}\z/, r["visitor"], "an unidentified visit gets the daily anonymous id")
      refute r.key?("user")
      assert_equal({ "browser" => "Safari", "os" => "iOS", "device" => "phone", "screen" => "390x844" }, r["ua"])
      assert_equal "en-US", r["lang"]
      assert_equal "vpn", r["origin"]
      assert_kind_of Float, r["ts"]
      refute_match(/172\.18|100\.101|Mozilla/, JSON.generate(r), "no address, no user agent string")
    end
    pv1, pv2, click, vital, custom, error = recs
    assert_equal "/wants/8c1f2a", pv1["path"], "query string stripped"
    assert_equal "/wants/:id", pv1["route"]
    assert_equal "https://portal.example.net/today", pv1["ref"]
    refute pv2.key?("ref"), "only the visit's first pageview keeps a referrer"
    assert_equal({ "tag" => "button", "role" => "button", "sel" => "form > button.primary", "href" => "/wants" }, click["el"])
    assert_equal({ "rage" => true }, click["props"])
    assert_equal({ "lcp" => 1840, "cls" => 0.02 }, vital["vitals"], "negative and unknown vitals dropped")
    assert_equal({ "kind" => "book", "password" => "[FILTERED]", "n" => 3, "long" => "y" * 200 }, custom["props"])
    assert_equal "TypeError", error["name"]
    assert_equal({ "file" => "/assets/app.js", "line" => 12 }, error["props"])
  end

  def test_record_paths_off_keeps_the_route_and_drops_the_path
    config = Glass::Config.new
    config.record_paths = false
    ev = { "kind" => "pageview", "ts" => Time.now.to_f, "path" => "/ingredients/ashwagandha", "route" => "/ingredients/:key" }
    rec = Glass::Relay.record(ev, Time.now.to_f, config)
    refute rec.key?(:path)
    assert_equal "/ingredients/:key", rec[:route]
  end

  def test_bad_clocks_are_restamped_on_arrival
    now = Time.now.to_f
    beacon([{ "kind" => "pageview", "ts" => now - 200_000, "path" => "/" }, { "kind" => "pageview", "ts" => now + 3_600, "path" => "/" },
            { "kind" => "pageview", "ts" => "yesterday", "path" => "/" }, { "kind" => "pageview", "ts" => now - 60, "path" => "/" }])
    ts = pages.map { |r| r["ts"] }
    ts.first(3).each { |t| assert_in_delta now, t, 5.0 }
    assert_in_delta now - 60, ts.last, 1.0
  end

  def test_beacon_validation
    good = JSON.generate(visit: VISIT, events: [{ "kind" => "pageview", "path" => "/" }])
    post = lambda do |body: good, origin: "http://app.example.net", type: "text/plain;charset=UTF-8", referer: nil|
      e = env("POST", "/_glass/b", body: body)
      e["CONTENT_TYPE"] = type
      e.delete("HTTP_ORIGIN")
      e["HTTP_ORIGIN"] = origin if origin
      e["HTTP_REFERER"] = referer if referer
      @mw.call(e)[0]
    end
    assert_equal 204, post.call
    assert_equal 204, post.call(type: "application/json")
    assert_equal 204, post.call(origin: nil), "a beacon with neither Origin nor Referer is allowed"
    assert_equal 204, post.call(origin: nil, referer: "http://app.example.net/wants")
    assert_equal 204, post.call(origin: "http://APP.EXAMPLE.NET")
    assert_equal 400, post.call(origin: "https://evil.example"), "cross-origin"
    assert_equal 400, post.call(origin: nil, referer: "https://evil.example/x")
    assert_equal 400, post.call(type: "application/x-www-form-urlencoded")
    assert_equal 400, post.call(body: "not json")
    assert_equal 400, post.call(body: "[]")
    assert_equal 400, post.call(body: JSON.generate(visit: "nope", events: []))
    assert_equal 400, post.call(body: JSON.generate(visit: VISIT, events: "x"))
    assert_equal 400, post.call(body: JSON.generate(visit: VISIT, events: Array.new(101) { { "kind" => "pageview" } }))
    assert_equal 413, post.call(body: JSON.generate(visit: VISIT, events: [{ "kind" => "custom", "name" => "x" * 70_000 }]))
    assert_equal 404, @mw.call(env("GET", "/_glass/b"))[0]
    assert_equal 5, pages.size, "each of the five accepted beacons relayed its one pageview, and nothing refused was"
    assert_equal 5, Glass::Relay::Visits.lookup(VISIT)[:events], "a refused beacon is not charged to the visit"
  end

  def test_unseen_visits_have_a_quota_seen_visits_do_not
    Glass::Relay::Visits.reset!
    3.times { assert_equal 204, beacon(Array.new(20) { { "kind" => "pageview", "path" => "/" } })[0] }
    assert_equal 40, pages.size, "50 events for a visit no request vouched for, whole beacons only"
    @sender.bodies.clear
    # A real request carrying the visit header vouches for it.
    @mw.call(env("GET", "/wants", headers: { "X-Glass-Visit" => VISIT }))
    beacon(Array.new(20) { { "kind" => "pageview", "path" => "/" } })
    assert_equal 20, pages.count { |r| r["kind"] == "pageview" }
  end

  def test_identity_join_stamps_user_and_visitor_from_a_served_request
    Glass.config.user = -> { 42 }
    Glass.config.user_name = -> { "Dave" }
    Glass.config.apply_directives("identity" => "pseudonymous")
    keyed = Glass::Tracer.resolve_identity.last
    beacon([{ "kind" => "pageview", "path" => "/" }])
    before = pages.last
    refute before.key?("user")
    assert_match(/\Aa_/, before["visitor"])
    # The request path resolves the user where Current is set (the
    # controller subscriber); here that step is called directly.
    app = lambda do |_env|
      txn = Glass::Tracer.current
      txn.name = "Wants#index"
      txn.user_identity = Glass::Tracer.resolve_identity
      Glass::Tracer.join_visit(txn)
      [200, {}, []]
    end
    Glass::Middleware.new(app).call(env("GET", "/wants", headers: { "X-Glass-Visit" => VISIT }))
    beacon([{ "kind" => "click", "path" => "/", "name" => "x" }])
    after = pages.last
    assert_equal keyed, after["user"]
    assert_equal keyed, after["visitor"]
    Glass.config.apply_directives("identity" => "named")
    Glass::Middleware.new(app).call(env("GET", "/wants", headers: { "X-Glass-Visit" => VISIT }))
    beacon([{ "kind" => "click", "path" => "/", "name" => "y" }])
    named = pages.last
    assert_equal "Dave", named["user"]
    assert_equal keyed, named["visitor"], "visitor stays the keyed hash in named mode"
    Glass.config.apply_directives("identity" => "anonymous")
    other = "v_aaaaaaaaaaaa"
    Glass::Middleware.new(app).call(env("GET", "/wants", headers: { "X-Glass-Visit" => other }))
    beacon([{ "kind" => "click", "path" => "/", "name" => "z" }], visit: other)
    anon = pages.last
    refute anon.key?("user")
    assert_match(/\Aa_/, anon["visitor"])
  end

  def test_visits_map_is_bounded_lru
    Glass::Relay::Visits.reset!
    (Glass::Relay::Visits::MAX + 10).times { |i| Glass::Relay::Visits.seen(format("v_%012x", i)) }
    assert_nil Glass::Relay::Visits.lookup("v_000000000000")
    refute_nil Glass::Relay::Visits.lookup(format("v_%012x", Glass::Relay::Visits::MAX + 9))
  end

  def test_anonymous_visitor_rotates_daily_and_differs_per_agent
    c = Glass.config
    a = Glass::Relay.anonymous_visitor(c, "192.168.1.9", UA_IPHONE)
    assert_equal a, Glass::Relay.anonymous_visitor(c, "192.168.1.9", UA_IPHONE)
    refute_equal a, Glass::Relay.anonymous_visitor(c, "192.168.1.10", UA_IPHONE)
    refute_equal a, Glass::Relay.anonymous_visitor(c, "192.168.1.9", "other")
  end

  def test_user_agent_parser
    parse = ->(ua) { Glass::Relay::UserAgent.parse(ua).values_at("browser", "os", "device") }
    assert_equal %w[Safari iOS phone], parse.call(UA_IPHONE)
    assert_equal %w[Safari iOS tablet], parse.call("Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1")
    assert_equal %w[Chrome Android phone], parse.call("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/120.0 Mobile Safari/537.36")
    assert_equal %w[Chrome Android tablet], parse.call("Mozilla/5.0 (Linux; Android 13; SM-X700) AppleWebKit/537.36 Chrome/120.0 Safari/537.36")
    assert_equal %w[Chrome macOS desktop], parse.call("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36")
    assert_equal %w[Safari macOS desktop], parse.call("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15")
    assert_equal %w[Firefox Linux desktop], parse.call("Mozilla/5.0 (X11; Linux x86_64; rv:120.0) Gecko/20100101 Firefox/120.0")
    assert_equal %w[Edge Windows desktop], parse.call("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0")
    assert_equal %w[other other desktop], parse.call("curl/8.4.0")
    assert_equal %w[other other desktop], parse.call(nil)
  end

  # --- HTML injection ----------------------------------------------------------------------

  def html_app(body, headers = { "content-type" => "text/html; charset=utf-8" }, status = 200)
    Glass::Middleware.new(->(_env) { [status, headers.dup, body] })
  end

  PAGE = "<!doctype html>\n<html><head><title>Glass</title></head><body><div id=\"root\"></div></body></html>"

  def test_injects_the_script_tag_before_head_and_fixes_content_length
    status, headers, body = html_app([PAGE], { "content-type" => "text/html; charset=utf-8", "content-length" => PAGE.bytesize.to_s }).call(env("GET", "/"))
    html = body.join
    assert_equal 200, status
    assert_equal PAGE.sub("</head>", "#{Glass::Relay::TAG}</head>"), html
    assert_equal html.bytesize.to_s, headers["content-length"]
    _, _, body = html_app(["<html><body>x</body></html>"]).call(env("GET", "/"))
    assert_equal "<html><body>x#{Glass::Relay::TAG}</body></html>", body.join
    _, _, body = html_app(["<p>fragment</p>"]).call(env("GET", "/"))
    assert_equal "<p>fragment</p>#{Glass::Relay::TAG}", body.join
  end

  def test_injection_handles_each_bodies_and_is_idempotent
    each_body = Class.new do
      def initialize(s) = (@s = s; @closed = false)
      def each = yield(@s)
      def close = @closed = true
      attr_reader :closed
    end
    rails_body = each_body.new(PAGE)
    _, headers, body = html_app(rails_body, { "Content-Type" => "text/html", "Content-Length" => PAGE.bytesize.to_s }).call(env("GET", "/"))
    assert body.join.include?(Glass::Relay::TAG)
    assert rails_body.closed, "the original body is closed"
    assert_equal body.join.bytesize.to_s, headers["Content-Length"], "headers keep their case"
    already = PAGE.sub("</head>", "#{Glass::Relay::TAG}</head>")
    _, _, body = html_app([already]).call(env("GET", "/"))
    assert_equal already, body.join, "no double injection"
    assert_equal 1, body.join.scan("/_glass/glass.js").size
  end

  def test_injection_skips_non_html_errors_streams_and_when_off
    _, _, body = html_app(["{}"], { "content-type" => "application/json" }).call(env("GET", "/"))
    assert_equal "{}", body.join
    _, _, body = html_app([PAGE], { "content-type" => "text/html" }, 404).call(env("GET", "/missing"))
    assert_equal PAGE, body.join
    _, _, body = html_app([PAGE], { "content-type" => "text/html", "transfer-encoding" => "chunked" }).call(env("GET", "/"))
    assert_equal PAGE, body.join
    Glass.config.browser = false
    _, _, body = html_app([PAGE]).call(env("GET", "/"))
    assert_equal PAGE, body.join
  end

  def test_relay_requests_produce_no_transactions_or_logs
    require_relative "../lib/glass/logs"
    beacon([{ "kind" => "pageview", "path" => "/" }])
    @mw.call(env("GET", "/_glass/glass.js"))
    Glass::Logs.record(1, "outside")
    Glass.flush(timeout: 2)
    assert_empty @sender.records("txn")
    assert_equal ["outside"], @sender.records("log").map { |l| l["msg"] }
    assert_empty @sender.records("metric").select { |m| m["name"].start_with?("rails.") }
  end

  def test_page_overflow_is_counted_in_the_header
    Glass.transport.instance_variable_get(:@limits)[:page] = 3
    beacon(Array.new(10) { { "kind" => "pageview", "path" => "/" } })
    Glass.flush(timeout: 2)
    assert_equal 3, @sender.records("page").size
    assert_equal 7, @sender.batches.last.first["dropped"]["page"]
  end
end
