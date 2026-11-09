# frozen_string_literal: true

require_relative "test_helper"

class TransactionTest < Minitest::Test
  HEX32 = /\A[0-9a-f]{32}\z/
  HEX16 = /\A[0-9a-f]{16}\z/

  def mono
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def test_ids_are_w3c_sized_and_continue_an_inbound_traceparent
    txn = Glass::Transaction.new("request")
    assert_match HEX32, txn.trace_id
    assert_match HEX16, txn.span_id
    assert_nil txn.parent_id
    assert_match(/\A00-#{txn.trace_id}-#{txn.span_id}-01\z/, txn.traceparent)

    cont = Glass::Transaction.new("request", traceparent: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
    assert_equal "4bf92f3577b34da6a3ce929d0e0e4736", cont.trace_id
    assert_equal "00f067aa0ba902b7", cont.parent_id
    refute_equal cont.parent_id, cont.span_id

    %w[junk 00-00000000000000000000000000000000-00f067aa0ba902b7-01 00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01].each do |bad|
      t = Glass::Transaction.new("request", traceparent: bad)
      assert_nil t.parent_id, "#{bad} must not be continued"
    end
  end

  def test_spans_nest_under_the_innermost_open_span
    txn = Glass::Transaction.new("request", "X#y")
    view = txn.view_start("app/views/x.html.erb", "app/views/x.html.erb")
    txn.sql("Want Load", "SELECT ?", mono, 1.5, false)
    partial = txn.view_start("app/views/_p.html.erb", "app/views/_p.html.erb")
    txn.view_finish(partial)
    txn.view_finish(view)
    txn.sql("Want Load", "SELECT ?", mono, 0.5, false)
    txn.finish
    spans = txn.span_records
    assert_equal %w[view sql view sql], spans.map { |s| s[:kind] }
    assert_equal txn.span_id, spans[0][:parent]
    assert_equal spans[0][:span], spans[1][:parent], "sql inside the template"
    assert_equal spans[0][:span], spans[2][:parent], "partial inside the template"
    assert_equal txn.span_id, spans[3][:parent], "sql after the template is a child of the root"
    assert_equal spans.map { |s| s[:span] }.uniq.size, 4
    spans.each { |s| assert_match HEX16, s[:span]; assert_equal txn.trace_id, s[:trace] }
  end

  def test_view_ms_counts_top_level_renders_only
    txn = Glass::Transaction.new("request", "X#y")
    t = mono
    outer = txn.view_start("a", "a", t)
    inner = txn.view_start("b", "b", t + 0.010)
    txn.view_finish(inner, t + 0.030)
    txn.view_finish(outer, t + 0.050)
    assert_in_delta 50.0, txn.view_ms, 0.001
    assert_in_delta 20.0, txn.spans[1].dur, 0.001
  end

  def test_db_totals_and_n_plus_one
    txn = Glass::Transaction.new("request", "X#y")
    4.times { txn.sql("Want Load", "SELECT * FROM wants WHERE id = ?", mono, 1.0, false) }
    refute txn.n1
    txn.sql("Want Load", "SELECT * FROM wants WHERE id = ?", mono, 1.0, false)
    assert txn.n1, "the fifth repeat of one statement shape flags N+1"
    txn.sql("Want Load", "SELECT * FROM wants WHERE id = ?", mono, 1.0, true)
    assert_equal 5, txn.db_n
    assert_in_delta 5.0, txn.db_ms
    assert_equal 1, txn.cache_hit, "a cached query counts as cache, not db"
    assert_equal 5, txn.spans.size
  end

  def test_session_statements_are_never_an_n_plus_one
    txn = Glass::Transaction.new("request", "X#y")
    10.times do
      txn.sql("SQL", "SET LOCAL statement_timeout = ?", mono, 0.1, false)
      txn.sql("SQL", "SAVEPOINT active_record_1", mono, 0.1, false)
    end
    refute txn.n1, "a statement timeout set ahead of each query reads no rows"
    assert_equal 20, txn.db_n, "it is still a round trip"
  end

  def test_queue_bookkeeping_is_never_an_n_plus_one
    txn = Glass::Transaction.new("job", "PollSourcesJob")
    10.times do
      txn.sql("SolidQueue::Semaphore Load", 'SELECT "solid_queue_semaphores".* FROM "solid_queue_semaphores" ' \
        'WHERE "solid_queue_semaphores"."key" = ? LIMIT ? FOR UPDATE', mono, 0.1, false)
      txn.sql("SolidQueue::Job Load", 'SELECT "solid_queue_jobs".* FROM "solid_queue_jobs" WHERE "solid_queue_jobs"."id" = ? LIMIT ?',
        mono, 0.1, false)
      txn.sql("SolidQueue::ReadyExecution Create", 'INSERT INTO "solid_queue_ready_executions" ("created_at", "job_id") ' \
        'VALUES (?, ?) RETURNING "id"', mono, 0.1, false)
      txn.sql("SolidQueue::Semaphore Upsert", 'INSERT INTO "solid_queue_semaphores" ("key","value") VALUES (?, ?) ' \
        "ON CONFLICT DO NOTHING", mono, 0.1, false)
    end
    refute txn.n1, "a concurrency-limited job is dispatched one at a time even when enqueued in bulk"
    assert_equal 40, txn.db_n, "it is still a round trip"
  end

  def test_enqueue_in_a_loop_is_still_an_n_plus_one
    txn = Glass::Transaction.new("job", "PollSourcesJob")
    5.times do
      txn.sql("SolidQueue::Job Create", 'INSERT INTO "solid_queue_jobs" ("queue_name", "class_name") VALUES (?, ?) RETURNING "id"',
        mono, 0.1, false)
    end
    assert txn.n1, "perform_later per row has a real fix: perform_all_later"
  end

  def test_span_cap_stops_recording_children_and_says_so
    txn = Glass::Transaction.new("request", "X#y")
    (Glass::Transaction::MAX_SPANS + 25).times { txn.sql("Q", "SELECT ?", mono, 0.1, false) }
    assert_nil txn.start_span("custom", "late")
    assert_equal Glass::Transaction::MAX_SPANS, txn.spans.size
    assert_equal Glass::Transaction::MAX_SPANS + 25, txn.db_n, "totals keep counting"
    txn.finish
    rec = txn.to_record(kept: true)
    assert_equal 26, rec[:attrs]["spans_dropped"]
  end

  def test_record_shape_matches_the_protocol
    txn = Glass::Transaction.new("request", "Api::V1::WantsController#index")
    txn.method = "GET"
    txn.route = "/api/v1/wants"
    txn.path = "/api/v1/wants"
    txn.http = 200
    txn.format = "json"
    txn.user = "u_abc"
    txn.visit = "v_1"
    txn.origin = "lan"
    txn.tag("want_id" => "7", "password" => "x", "n" => 1, "big" => "y" * 2_000)
    txn.finish
    rec = txn.to_record(kept: false)
    %i[t ts kind name trace span dur status method route path http format db_ms db_n view_ms ext_ms ext_n cache_hit cache_miss alloc n1 user visit origin kept attrs].each do |k|
      assert rec.key?(k), "txn record has #{k}"
    end
    assert_equal "txn", rec[:t]
    assert_kind_of Float, rec[:ts]
    assert_kind_of Float, rec[:dur]
    assert_equal "request", rec[:kind]
    assert_equal false, rec[:kept]
    refute rec.key?(:parent)
    refute rec.key?(:error)
    refute rec.key?(:queue)
    assert_equal 1_000, rec[:attrs]["big"].size
    assert_equal "x", rec[:attrs]["password"], "scrubbing is the caller's (Glass.tag) job; the record keeps what it is given"
    line = JSON.parse(JSON.generate(rec))
    assert_equal "Api::V1::WantsController#index", line["name"]
  end

  def test_job_record_fields_and_error_status
    txn = Glass::Transaction.new("job", "SearchPlanJob")
    txn.queue = "default"
    txn.queue_ms = 12.5
    txn.attempt = 2
    txn.mark_error("Timeout::Error")
    txn.mark_error("Other") # the first class sticks
    txn.finish
    rec = txn.to_record(kept: true)
    assert_equal %w[job SearchPlanJob default], rec.values_at(:kind, :name, :queue)
    assert_equal 12.5, rec[:queue_ms]
    assert_equal 2, rec[:attempt]
    assert_equal "error", rec[:status]
    assert_equal "Timeout::Error", rec[:error]
    refute rec.key?(:method)
  end

  def test_attrs_capped_at_64_keys
    txn = Glass::Transaction.new("request", "X#y")
    txn.tag((1..70).to_h { |i| ["k#{i}", i] })
    assert_equal 64, txn.attrs.size
    txn.tag("k1" => "updated")
    assert_equal "updated", txn.attrs["k1"], "existing keys still update"
  end

  def test_open_spans_at_finish_are_not_sent
    txn = Glass::Transaction.new("request", "X#y")
    txn.start_span("custom", "never closed")
    txn.sql("Q", "SELECT ?", mono, 0.1, false)
    txn.finish
    assert_equal ["Q"], txn.span_records.map { |s| s[:name] }
  end
end
