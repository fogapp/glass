# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class TransportTest < Minitest::Test
  include GlassTestSupport

  def config(queue_size: 100, flush_interval: 10)
    c = Glass::Config.new
    c.url = "http://glass.test"
    c.api_key = "glass_ing_k"
    c.queue_size = queue_size
    c.flush_interval = flush_interval
    c
  end

  def transport(sender, **opts)
    Glass::Transport.new(config(**opts), aggregator: Glass::Aggregator.new, sender: sender)
  end

  def test_body_is_gzipped_ndjson_with_a_protocol_header
    sender = FakeSender.new
    t = transport(sender)
    t.push(:txn, { t: "txn", ts: 1.0, kind: "request", name: "X#y", trace: "a" * 32, span: "b" * 16, dur: 1.0 })
    t.push(:marker, { t: "marker", ts: 1.0, kind: "event", title: "hi" })
    t.flush(timeout: 2)
    assert_equal 1, sender.bodies.size
    raw = sender.bodies.first
    assert_equal "\x1f\x8b".b, raw.byteslice(0, 2), "body is gzip"
    text = Zlib.gunzip(raw)
    assert text.end_with?("\n"), "every line is newline-terminated"
    lines = text.each_line(chomp: true).map { |l| JSON.parse(l) }
    header, *records = lines
    assert_equal 1, header["v"]
    process = header["process"]
    assert_equal "web", process["kind"]
    assert_kind_of String, process["host"]
    assert_equal Process.pid, process["pid"]
    assert_kind_of Float, process["started_at"]
    assert_equal RUBY_VERSION, process["runtime"]["ruby"]
    assert_equal Glass::VERSION, process["runtime"]["agent"]
    assert_equal "glass-ruby", process["runtime"]["client"]
    assert_kind_of Float, header["sent_at"]
    assert_equal({ "txn" => 0, "span" => 0, "metric" => 0, "log" => 0, "profile" => 0, "page" => 0, "marker" => 0, "llm" => 0 },
                 header["dropped"])
    assert_equal %w[txn marker], records.map { |r| r["t"] }
  ensure
    t&.shutdown
  end

  def test_an_idle_flush_still_sends_its_header_as_a_heartbeat
    sender = FakeSender.new
    t = transport(sender)
    t.start
    t.flush(timeout: 2)
    assert_equal 1, sender.bodies.size
    header, *records = sender.batches.first
    assert_equal Process.pid, header["process"]["pid"]
    assert_empty records
  ensure
    t&.shutdown
  end

  def test_release_is_present_only_when_known
    sender = FakeSender.new
    c = config
    c.release = "3df7786"
    t = Glass::Transport.new(c, aggregator: Glass::Aggregator.new, sender: sender)
    t.push(:marker, { t: "marker", ts: 1.0, title: "x" })
    t.flush(timeout: 2)
    assert_equal "3df7786", sender.batches.first.first["process"]["release"]
    t.shutdown
    c.release = ""
    sender2 = FakeSender.new
    t2 = Glass::Transport.new(c, aggregator: Glass::Aggregator.new, sender: sender2)
    t2.push(:marker, { t: "marker", ts: 1.0, title: "x" })
    t2.flush(timeout: 2)
    refute sender2.batches.first.first["process"].key?("release")
  ensure
    t&.shutdown
    t2&.shutdown
  end

  def test_metrics_are_drained_from_the_aggregator_at_flush
    sender = FakeSender.new
    agg = Glass::Aggregator.new
    t = Glass::Transport.new(config, aggregator: agg, sender: sender)
    agg.counter("c", 1, {}, Time.now.to_i - 30)
    t.start
    t.flush(timeout: 2)
    assert_equal 1, sender.records("metric").size
  ensure
    t&.shutdown
  end

  def test_202_applies_directives
    sender = FakeSender.new(body: '{"accepted":1,"directives":{"trace_sample_rate":0.25,"log_level":"error","identity":"anonymous"}}')
    c = config
    t = Glass::Transport.new(c, aggregator: Glass::Aggregator.new, sender: sender)
    t.push(:marker, { t: "marker", ts: 1.0, title: "x" })
    t.flush(timeout: 2)
    assert_in_delta 0.25, c.trace_sample_rate
    assert_equal "error", c.log_level
    assert_equal "anonymous", c.identity
  ensure
    t&.shutdown
  end

  def test_401_stops_for_good_and_counts_the_batch
    sender = FakeSender.new(status: 401)
    t = transport(sender)
    t.push(:marker, { t: "marker", ts: 1.0, title: "x" })
    t.flush(timeout: 2)
    assert t.halted
    assert_equal 1, t.dropped[:marker]
    t.push(:marker, { t: "marker", ts: 1.0, title: "y" })
    t.flush(timeout: 1)
    assert_equal 1, sender.bodies.size, "nothing is sent after a 401"
    refute t.running?, "the worker thread has stopped"
  ensure
    t&.shutdown
  end

  def test_413_drops_and_halves_the_next_batch
    sender = FakeSender.new(status: 413)
    t = transport(sender)
    t.push(:marker, { t: "marker", ts: 1.0, title: "x" })
    t.flush(timeout: 2)
    assert_equal 1, t.dropped[:marker]
    assert_equal Glass::Transport::DEFAULT_MAX_RECORDS / 2, t.max_records
    assert_equal Glass::Transport::DEFAULT_MAX_BYTES / 2, t.max_bytes
    t.push(:marker, { t: "marker", ts: 1.0, title: "x" })
    t.flush(timeout: 2)
    assert_equal Glass::Transport::DEFAULT_MAX_RECORDS / 4, t.max_records
    # It grows back only after a run of accepted batches.
    sender.respond_with(status: 202, body: "{}")
    Glass::Transport::RECOVER_AFTER.times do
      t.push(:marker, { t: "marker", ts: 1.0, title: "x" })
      t.flush(timeout: 2)
    end
    assert_equal Glass::Transport::DEFAULT_MAX_RECORDS / 2, t.max_records
  ensure
    t&.shutdown
  end

  def test_max_records_bounds_one_batch_and_the_rest_waits
    sender = FakeSender.new
    t = transport(sender, queue_size: 1_000)
    t.instance_variable_set(:@max_records, 300)
    500.times { |i| t.push(:txn, { t: "txn", i: i }) }
    t.flush(timeout: 2)
    assert_equal 300, sender.records.size
    assert_equal 200, t.buffered(:txn)
    t.flush(timeout: 2)
    assert_equal 500, sender.records.size
  ensure
    t&.shutdown
  end

  # Records are encoded outside the lock, so pushes land while a batch is
  # being taken: what did not fit goes back ahead of them, and the buffer
  # stays bounded.
  def test_max_bytes_puts_back_what_did_not_fit_ahead_of_what_arrived_meanwhile
    sender = FakeSender.new
    t = transport(sender, queue_size: 5)
    t.instance_variable_set(:@max_bytes, JSON.generate({ t: "txn", i: 0 }).bytesize * 3)
    5.times { |i| t.push(:txn, { t: "txn", i: i }) }
    arrived = false
    t.define_singleton_method(:encode) do |record|
      unless arrived
        arrived = true
        5.times { |i| push(:txn, { t: "txn", i: 5 + i }) } # a request thread, mid-encode
      end
      super(record)
    end
    lines, counts = t.send(:take_batch)
    assert_equal [0, 1, 2], lines.map { |l| JSON.parse(l)["i"] }
    assert_equal({ txn: 3 }, counts)
    assert_equal 5, t.buffered(:txn), "the buffer stays bounded"
    assert_equal 2, t.dropped[:txn], "past the bound the newest are dropped, and counted"
    lines, = t.send(:take_batch)
    assert_equal [3, 4, 5], lines.map { |l| JSON.parse(l)["i"] }, "what did not fit goes first next time"
  ensure
    t&.shutdown
  end

  def test_429_pauses_for_retry_after_and_drops_meanwhile
    clock_now = [100.0]
    clock = -> { clock_now[0] }
    sender = FakeSender.new(status: 429, retry_after: "7")
    t = Glass::Transport.new(config, aggregator: Glass::Aggregator.new, sender: sender, clock: clock)
    t.push(:marker, { t: "marker", ts: 1.0, title: "x" })
    t.flush(timeout: 2)
    assert_equal 1, t.dropped[:marker], "the batch that was answered 429 is dropped"
    sender.respond_with(status: 202)
    clock_now[0] = 103.0
    t.push(:marker, { t: "marker", ts: 1.0, title: "y" })
    t.push(:log, { t: "log", ts: 1.0, msg: "z" })
    t.flush(timeout: 2)
    assert_equal 1, sender.bodies.size, "nothing is sent during the pause"
    assert_equal 2, t.dropped[:marker]
    assert_equal 1, t.dropped[:log]
    clock_now[0] = 108.0
    t.push(:marker, { t: "marker", ts: 1.0, title: "after" })
    t.flush(timeout: 2)
    assert_equal 2, sender.bodies.size, "sending resumes once Retry-After has elapsed"
    assert_equal({ "marker" => 2, "log" => 1, "txn" => 0, "span" => 0, "metric" => 0, "profile" => 0, "page" => 0, "llm" => 0 },
                 sender.batches.last.first["dropped"], "the next header carries the cumulative drops")
  ensure
    t&.shutdown
  end

  def test_retry_after_is_clamped
    clock_now = [100.0]
    sender = FakeSender.new(status: 429, retry_after: "9999")
    t = Glass::Transport.new(config, aggregator: Glass::Aggregator.new, sender: sender, clock: -> { clock_now[0] })
    t.push(:marker, { t: "marker", ts: 1.0, title: "x" })
    t.flush(timeout: 2)
    assert_in_delta 400.0, t.instance_variable_get(:@pause_until)
    sender.respond_with(status: 429, retry_after: "junk")
    clock_now[0] = 500.0
    t.push(:marker, { t: "marker", ts: 1.0, title: "x" })
    t.flush(timeout: 2)
    assert_in_delta 501.0, t.instance_variable_get(:@pause_until), 0.001, "junk still backs off at least 1s"
    sender.respond_with(status: 429, retry_after: nil)
    clock_now[0] = 600.0
    t.push(:marker, { t: "marker", ts: 1.0, title: "x" })
    t.flush(timeout: 2)
    assert_in_delta 660.0, t.instance_variable_get(:@pause_until), 0.001, "no header means 60s"
  ensure
    t&.shutdown
  end

  def test_5xx_and_network_errors_drop_without_retry
    sender = FakeSender.new(status: 503)
    t = transport(sender)
    t.push(:txn, { t: "txn" })
    t.flush(timeout: 2)
    assert_equal 1, t.dropped[:txn]
    t.flush(timeout: 2)
    assert_equal 2, sender.bodies.size
    assert_equal [], sender.batches.last.drop(1), "never retried: the next batch is a heartbeat, not the lost records"
    boom = ->(_body) { raise Errno::ECONNREFUSED }
    t2 = transport(boom)
    t2.push(:txn, { t: "txn" })
    t2.push(:span, { t: "span" })
    t2.flush(timeout: 2)
    assert_equal({ txn: 1, span: 1 }, t2.dropped.select { |_, v| v.positive? })
  ensure
    t&.shutdown
    t2&.shutdown
  end

  def test_overflow_drops_instead_of_blocking_and_counts
    gate = Queue.new
    sender = ->(_body) { gate.pop; Glass::Transport::Response.new(202, "{}", nil) }
    t = transport(sender, queue_size: 3)
    done = Queue.new
    Thread.new do
      10.times { |i| t.push(:txn, { t: "txn", i: i }) }
      50.times { |i| t.push(:span, { t: "span", i: i }) }
      done.push(:ok)
    end
    assert_equal :ok, done.pop(timeout: 2), "push must never block the app thread"
    assert_equal 7, t.dropped[:txn]
    assert_equal 50 - 12, t.dropped[:span], "spans get four times the transaction budget"
  ensure
    gate&.close
    t&.shutdown
  end

  def test_unencodable_records_are_dropped_not_fatal
    sender = FakeSender.new
    t = transport(sender)
    t.push(:txn, { t: "txn", bad: "\xff".b.force_encoding("UTF-8") })
    t.push(:txn, { t: "txn", ok: true })
    t.flush(timeout: 2)
    assert_equal 1, sender.records.size
    assert_equal 1, t.dropped[:txn]
  ensure
    t&.shutdown
  end

  def test_flush_waits_for_a_flush_started_after_the_request
    sender = FakeSender.new
    t = transport(sender)
    t.push(:txn, { t: "txn", n: 1 })
    t.flush(timeout: 2)
    t.push(:txn, { t: "txn", n: 2 })
    t.flush(timeout: 2)
    assert_equal [1, 2], sender.records.map { |r| r["n"] }
  ensure
    t&.shutdown
  end

  def test_forked_child_starts_clean_with_its_own_thread
    skip "no fork" unless Process.respond_to?(:fork)
    sender = FakeSender.new
    t = transport(sender)
    t.push(:txn, { t: "txn", n: "parent" })
    t.push(:marker, { t: "marker", title: "x" })
    parent_thread = t.instance_variable_get(:@thread)
    r, w = IO.pipe
    pid = fork do
      r.close
      child_sender = FakeSender.new
      t.instance_variable_set(:@sender, child_sender)
      before = t.buffered(:txn)
      t.push(:txn, { t: "txn", n: "child" })
      thread = t.instance_variable_get(:@thread)
      t.flush(timeout: 2)
      w.write(JSON.generate(
        inherited_buffer: before, records: child_sender.records.map { |x| x["n"] },
        pid_in_header: child_sender.batches.first.first["process"]["pid"],
        new_thread: !thread.equal?(parent_thread), dropped: t.dropped
      ))
      w.close
      exit!(0)
    end
    w.close
    report = JSON.parse(r.read)
    Process.wait(pid)
    assert_equal 1, report["inherited_buffer"], "before its first push the child still holds the parent's copy"
    assert_equal ["child"], report["records"], "the child's first push discards inherited records"
    assert_equal pid, report["pid_in_header"]
    assert report["new_thread"]
    assert_equal 0, report["dropped"]["txn"], "inherited records are the parent's, not drops"
    t.flush(timeout: 2)
    assert_equal ["parent", nil], sender.records.map { |x| x["n"] }, "the parent still owns its buffer"
  ensure
    t&.shutdown
  end

  # --- HttpSender: real socket, canned response ------------------------------------

  def serve_once(status: 202, headers: {}, body: "{}")
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    captured = +""
    thread = Thread.new do
      sock = server.accept
      content_length = 0
      while (line = sock.gets) && line != "\r\n"
        captured << line
        content_length = line.split(":", 2)[1].to_i if line.match?(/\AContent-Length:/i)
      end
      captured << "\r\n"
      captured << sock.read(content_length) if content_length.positive?
      extra = headers.map { |k, v| "#{k}: #{v}\r\n" }.join
      sock.write("HTTP/1.1 #{status} X\r\n#{extra}Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      sock.close
    end
    [server, port, captured, thread]
  end

  def test_http_sender_posts_gzip_ndjson_with_bearer_key
    server, port, captured, thread = serve_once(status: 429, headers: { "Retry-After" => "3" }, body: '{"errors":["slow down"]}')
    c = config
    c.url = "http://127.0.0.1:#{port}/"
    payload = Zlib.gzip("{\"v\":1}\n")
    response = Glass::HttpSender.new(c).call(payload)
    assert thread.join(5)
    head, body = captured.split("\r\n\r\n", 2)
    assert_equal "POST /ingest/v1/batch HTTP/1.1\r\n", head.lines.first
    assert head.lines.any? { |l| l.match?(/\AAuthorization: Bearer glass_ing_k/i) }
    assert head.lines.any? { |l| l.match?(%r{\AContent-Type: application/x-ndjson}i) }
    assert head.lines.any? { |l| l.match?(/\AContent-Encoding: gzip/i) }
    assert head.lines.any? { |l| l.match?(%r{\AUser-Agent: glass-ruby/#{Glass::VERSION}}i) }
    assert_equal payload.b, body.b
    assert_equal 429, response.status
    assert_equal "3", response.retry_after
    assert_equal '{"errors":["slow down"]}', response.body
  ensure
    server&.close
  end

  def test_http_sender_connection_refused_raises_to_the_transport
    c = config
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    c.url = "http://127.0.0.1:#{port}"
    assert_raises(SystemCallError) { Glass::HttpSender.new(c).call("x") }
  end
end
