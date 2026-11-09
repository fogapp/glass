# frozen_string_literal: true

require_relative "test_helper"
require "socket"

begin
  require "active_support"
  require "active_support/notifications"
  require "active_support/broadcast_logger"
  require "active_support/error_reporter"
  require "active_job"
  RAILS_BITS = true
rescue LoadError
  RAILS_BITS = false
end

# The Rails-facing half, driven through ActiveSupport::Notifications and
# Active Job without booting a Rails app: subscriber bodies, nesting, the
# trace crossing a queue, the log sink on a broadcast logger, and the
# Net::HTTP patch against a real local socket.
class IntegrationTest < Minitest::Test
  include GlassTestSupport

  # A minimal stand-in for Rails.application: what Integration.attach reads.
  class FakeApp
    Config = Struct.new(:filter_parameters)
    def config = Config.new([:ssn])
  end

  module FakeRails
    def self.reset! = (@logger = nil; @error = nil)
    def self.logger = @logger ||= ActiveSupport::BroadcastLogger.new(Logger.new(IO::NULL, level: Logger::INFO))
    def self.error = @error ||= ActiveSupport::ErrorReporter.new
    def self.root = nil
    def self.version = "8.1.3"
  end

  def setup
    skip "activesupport not available" unless RAILS_BITS
    @sender = configure_glass(trace_sample_rate: 1.0)
    Glass.config.autostart = false
    Object.const_set(:Rails, FakeRails) unless defined?(::Rails)
    FakeRails.reset!
    require_relative "../lib/glass/rails"
    Glass::Integration.detach!
    Glass::Integration.attach(FakeApp.new)
  end

  def teardown
    ActiveSupport::Notifications.notifier = ActiveSupport::Notifications::Fanout.new
    Object.send(:remove_const, :Rails) if defined?(::Rails) && ::Rails == FakeRails
    super
  end

  def request(env = {})
    app = lambda do |_env|
      ActiveSupport::Notifications.instrument("start_processing.action_controller", controller: "WantsController", action: "index")
      yield
      [200, {}, []]
    end
    Glass::Middleware.new(app).call({ "REQUEST_METHOD" => "GET", "PATH_INFO" => "/wants" }.merge(env))
    Glass.flush(timeout: 2)
  end

  def instrument(name, payload = {}, &block)
    ActiveSupport::Notifications.instrument(name, payload, &block)
  end

  def test_sql_views_and_cache_accumulate_on_the_transaction
    request do
      instrument("render_template.action_view", identifier: "#{Dir.pwd}/app/views/wants/index.html.erb") do
        instrument("sql.active_record", sql: "SELECT \"wants\".* FROM \"wants\" WHERE id = $1", name: "Want Load", cached: false)
        instrument("render_partial.action_view", identifier: "app/views/wants/_want.html.erb") {}
      end
      instrument("sql.active_record", sql: "SELECT 1", name: "SCHEMA")
      instrument("sql.active_record", sql: "BEGIN", name: "TRANSACTION")
      instrument("sql.active_record", sql: "SELECT 2", name: "Want Load", cached: true)
      instrument("sql.active_record", sql: "INSERT INTO \"logs\" VALUES (1)", name: nil)
      instrument("cache_read.active_support", key: "k", hit: true)
      instrument("cache_read.active_support", key: "k", hit: false)
      instrument("cache_read_multi.active_support", key: %w[a b c], hits: %w[a])
      instrument("process_action.action_controller", controller: "WantsController", action: "index", status: 200, format: :json)
    end
    txn = @sender.records("txn").first
    assert_equal "WantsController#index", txn["name"]
    assert_equal 200, txn["http"]
    assert_equal "json", txn["format"]
    assert_equal 2, txn["db_n"]
    assert_equal 3, txn["cache_hit"], "cached query + cache_read hit + one of read_multi"
    assert_equal 3, txn["cache_miss"]
    assert_operator txn["view_ms"], :>, 0
    spans = @sender.records("span")
    assert_equal %w[view sql view sql], spans.map { |s| s["kind"] }
    assert_equal "app/views/wants/index.html.erb", spans[0]["name"], "template identifier relative to the app root"
    assert_equal %(SELECT "wants".* FROM "wants" WHERE id = ?), spans[1]["res"]
    assert_equal spans[0]["span"], spans[1]["parent"], "SQL during the render is a child of the view span"
    assert_equal "INSERT logs", spans[3]["name"], "an unnamed query is labelled by verb and table"
  end

  def test_n_plus_one_is_flagged_from_repeated_statement_shapes
    request do
      6.times { |i| instrument("sql.active_record", sql: "SELECT * FROM wants WHERE id = #{i}", name: "Want Load") }
      instrument("process_action.action_controller", controller: "WantsController", action: "index", status: 200)
    end
    assert_equal true, @sender.records("txn").first["n1"]
  end

  def test_unhandled_error_marks_the_transaction_and_counts
    request do
      ::Rails.error.report(RuntimeError.new("late"), handled: true)
      ::Rails.error.report(ArgumentError.new("bad"), handled: false)
      instrument("process_action.action_controller", controller: "WantsController", action: "index", status: 500)
    end
    txn = @sender.records("txn").first
    assert_equal "error", txn["status"]
    assert_equal "ArgumentError", txn["error"]
    errors = @sender.records("metric").select { |m| m["name"] == "rails.errors" }
    assert_equal [{ "error" => "ArgumentError", "handled" => "false" }, { "error" => "RuntimeError", "handled" => "true" }],
                 errors.map { |m| m["tags"] }.sort_by { |t| t["error"] }
  end

  # Captures serialized jobs the way a real adapter hands them to a worker.
  class CapturingAdapter
    attr_reader :jobs
    def initialize = @jobs = []
    def enqueue(job) = @jobs << job.serialize
    def enqueue_at(job, _at) = @jobs << job.serialize
    def enqueue_after_transaction_commit? = false
  end

  class PingJob < ActiveJob::Base
    queue_as :pings
    def perform(fail = false)
      raise "job failed" if fail
    end
  end

  def test_jobs_become_transactions_with_queue_latency_and_propagated_trace
    ActiveJob::Base.logger = Logger.new(IO::NULL)
    adapter = CapturingAdapter.new
    PingJob.queue_adapter = adapter
    request do
      PingJob.perform_later
      instrument("process_action.action_controller", controller: "WantsController", action: "index", status: 200)
    end
    # The worker side: another thread, no request in progress.
    Thread.new { ActiveJob::Base.execute(adapter.jobs.first) }.join
    Glass.flush(timeout: 2)
    txns = @sender.records("txn")
    job = txns.find { |t| t["kind"] == "job" }
    req = txns.find { |t| t["kind"] == "request" }
    refute_nil job
    assert_equal "IntegrationTest::PingJob", job["name"]
    assert_equal "pings", job["queue"]
    assert_equal 1, job["attempt"]
    assert_kind_of Numeric, job["queue_ms"]
    assert_equal req["trace"], job["trace"], "the job continues the request's trace"
    enqueue = @sender.records("span").find { |s| s["kind"] == "enqueue" }
    assert_equal enqueue["span"], job["parent"], "with the enqueue span as its parent"
    assert_equal({ "queue" => "pings" }, enqueue["attrs"])
    metrics = @sender.records("metric").group_by { |m| m["name"] }
    assert_equal({ "name" => "IntegrationTest::PingJob", "queue" => "pings" }, metrics["rails.job.count"].first["tags"])
    assert metrics.key?("rails.job.duration")
    assert metrics.key?("rails.job.queue_latency")
  end

  def test_failed_job_is_an_error_transaction
    ActiveJob::Base.logger = Logger.new(IO::NULL)
    assert_raises(RuntimeError) { PingJob.perform_now(true) }
    Glass.flush(timeout: 2)
    job = @sender.records("txn").first
    assert_equal "job", job["kind"]
    assert_equal "error", job["status"]
    assert_equal "RuntimeError", job["error"]
    assert_equal 1.0, @sender.records("metric").find { |m| m["name"] == "rails.job.errors" }["sum"]
  end

  def test_serialized_job_carries_traceparent_only_inside_a_trace
    assert_nil PingJob.new.serialize["glass_traceparent"]
    request do
      data = PingJob.new.serialize
      assert_match(/\A00-#{Glass.trace_id}-[0-9a-f]{16}-01\z/, data["glass_traceparent"])
      job = PingJob.new
      job.deserialize(data)
      assert_equal data["glass_traceparent"], job.glass_traceparent
      instrument("process_action.action_controller", controller: "WantsController", action: "index", status: 200)
    end
  end

  def test_log_sink_ships_lines_with_trace_and_honors_levels
    logger = ::Rails.logger
    request do
      logger.debug("not shipped: below the app's level")
      logger.info("\e[1mStarted GET\e[0m \"/wants\"")
      logger.warn { "from a block" }
      logger.error("x" * 9_000)
      Glass.config.log_level = "error"
      logger.warn("not shipped: below the directive")
      instrument("process_action.action_controller", controller: "WantsController", action: "index", status: 200)
    end
    logs = @sender.records("log").select { |l| l["src"] == "rails" }
    assert_equal %w[info warn error], logs.map { |l| l["lvl"] }
    assert_equal "Started GET \"/wants\"", logs[0]["msg"], "ANSI stripped"
    assert_equal "from a block", logs[1]["msg"]
    assert_equal 8_000, logs[2]["msg"].size
    txn = @sender.records("txn").first
    logs.each { |l| assert_equal txn["trace"], l["trace"]; assert_equal txn["span"], l["span"] }
    assert_equal Logger::INFO, logger.level, "the sink never lowers the broadcast logger's level"
  end

  def test_agent_thread_logging_is_not_shipped
    logger = ::Rails.logger
    Thread.new { Thread.current[:glass_agent] = true; logger.info("from the agent") }.join
    Glass::Logs.muted { logger.info("muted") }
    logger.info("plain")
    Glass.flush(timeout: 2)
    assert_equal ["plain"], @sender.records("log").map { |l| l["msg"] }
  end

  def test_events_become_scrubbed_log_records
    subscriber = Glass::Logs::EventSubscriber.new(Glass.config)
    request do
      subscriber.emit(name: "want.created", payload: { id: 7, password: "x", ssn: "1", nested: { a: 1 }, binds: [1], sql: "SELECT 1" },
                      tags: { request_id: "r1" }, timestamp: 1_790_000_120_150_000_000)
      instrument("process_action.action_controller", controller: "WantsController", action: "index", status: 200)
    end
    ev = @sender.records("log").find { |l| l["src"] == "event" }
    assert_equal "want.created", ev["msg"]
    assert_equal "info", ev["lvl"]
    assert_in_delta 1_790_000_120.15, ev["ts"], 0.001
    assert_equal({ "id" => 7, "password" => "[FILTERED]", "ssn" => "[FILTERED]", "nested" => "{\"a\":1}", "sql" => "SELECT ?", "tag.request_id" => "r1" }, ev["attrs"])
    assert_equal @sender.records("txn").first["trace"], ev["trace"]
  end

  def serve_once
    server = TCPServer.new("127.0.0.1", 0)
    captured = +""
    thread = Thread.new do
      sock = server.accept
      while (line = sock.gets) && line != "\r\n"
        captured << line
      end
      sock.write("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      sock.close
    end
    [server, server.addr[1], captured, thread]
  end

  def test_outbound_http_is_a_span_with_traceparent_to_private_hosts
    server, port, captured, thread = serve_once
    request do
      Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/things/1?secret=1"))
      instrument("process_action.action_controller", controller: "WantsController", action: "index", status: 200)
    end
    assert thread.join(5)
    span = @sender.records("span").find { |s| s["kind"] == "http" }
    assert_equal "GET 127.0.0.1", span["name"]
    assert_equal "GET 127.0.0.1/things/1", span["res"], "no query string"
    assert_equal({ "status" => 204 }, span["attrs"])
    txn = @sender.records("txn").first
    assert_equal 1, txn["ext_n"]
    assert_operator txn["ext_ms"], :>, 0
    tp = captured.lines.find { |l| l.match?(/\Atraceparent:/i) }
    assert_equal "00-#{txn['trace']}-#{span['span']}-01", tp.split(":", 2).last.strip
  ensure
    server&.close
  end

  def test_traceparent_propagation_rule
    assert Glass::NetHttp.propagate?("glass")
    refute Glass::NetHttp.propagate?("api.github.com")
    assert_equal Glass::NetHttp.propagate?("api.github.com"), Glass::NetHttp.propagate?("api.github.com"), "remembered per host"
    # The conformance kit's cases are in OriginTest; this is the patch's view of the same rule.
  end

  def test_subscriber_errors_are_counted_never_raised
    request do
      instrument("sql.active_record", sql: 12_345, name: Object.new) # junk payload
      instrument("process_action.action_controller", controller: "WantsController", action: "index", status: 200)
    end
    assert_equal 1, @sender.records("txn").size
  end
end
