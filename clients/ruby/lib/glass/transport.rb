# frozen_string_literal: true

require "json"
require "net/http"
require "socket"
require "uri"
require "zlib"

module Glass
  # One background thread, bounded buffers, one POST per flush. The contract
  # that makes this safe inside every app (protocol "Rules for an agent"):
  # push never blocks — overflow drops and counts; a failed send drops the
  # batch and never retries; 429 pauses for Retry-After; 401 stops for good;
  # 413 halves the next batch. The thread also owns the periodic work that
  # must never touch a request thread: runtime sampling and profile windows.
  class Transport
    TYPES = %i[txn span metric log profile page marker llm].freeze
    # The order a batch takes them in: the cheap uniform rows first.
    BATCH_ORDER = %i[txn llm metric marker span log profile page].freeze
    DEFAULT_MAX_RECORDS = 10_000
    MIN_MAX_RECORDS = 250
    DEFAULT_MAX_BYTES = 16 * 1024 * 1024 # inflated; the server allows 32 MiB
    MIN_MAX_BYTES = 256 * 1024
    RECOVER_AFTER = 6 # accepted batches before a halved limit grows back one step
    RETRY_AFTER_RANGE = (1..300)

    Response = Struct.new(:status, :body, :retry_after)

    attr_reader :dropped, :max_records, :max_bytes, :halted, :started_at, :profiler, :runtime

    def initialize(config, aggregator:, sender: nil, runtime: nil, profiler: nil, clock: nil)
      @config = config
      @aggregator = aggregator
      @sender = sender || config.sender || HttpSender.new(config)
      @runtime = runtime
      @profiler = profiler
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @mutex = Mutex.new
      @wake = ConditionVariable.new
      @flushed = ConditionVariable.new
      @buffers = TYPES.to_h { |t| [t, []] }
      @limits = limits_for(config)
      @dropped = TYPES.to_h { |t| [t, 0] }
      @max_records = DEFAULT_MAX_RECORDS
      @max_bytes = DEFAULT_MAX_BYTES
      @accepted_streak = 0
      @pause_until = nil
      @halted = false
      @thread = nil
      @pid = nil
      @started_at = Time.now.to_f
      @requested_seq = 0
      @completed_seq = 0
      @flush_requested = false
      @stop = false
      @next_flush = nil
      @next_runtime = nil
    end

    # --- producers (any thread) --------------------------------------------

    def push(type, record)
      return nil if @halted
      ensure_running
      @mutex.synchronize { push_locked(type, record) }
      nil
    end

    # A transaction and its kept spans under one lock.
    def push_transaction(txn, spans)
      return nil if @halted
      ensure_running
      @mutex.synchronize do
        push_locked(:txn, txn)
        spans&.each { |s| push_locked(:span, s) }
      end
      nil
    end

    def buffered(type)
      @mutex.synchronize { @buffers[type].size }
    end

    # --- lifecycle --------------------------------------------------------

    # Start the thread now (boot, or after a fork) instead of on the first
    # push, so an idle process still heartbeats and reports its runtime.
    def start
      ensure_running
      self
    end

    def running?
      @thread&.alive? && @pid == Process.pid
    end

    # Ask the worker for a flush and wait for it, at most `timeout` seconds.
    # Used at exit; a worker wedged in a slow POST is abandoned, not joined.
    def flush(timeout: 2, final: false)
      return nil unless running?
      deadline = @clock.call + timeout
      @mutex.synchronize do
        # Wait for a flush that *started* after this request: a flush already
        # in progress when we asked does not count, or the final records
        # (the ones at_exit exists for) would be left behind.
        @requested_seq += 1
        mine = @requested_seq
        @flush_requested = true
        @final = true if final
        @wake.signal
        while @completed_seq < mine
          remaining = deadline - @clock.call
          break if remaining <= 0
          @flushed.wait(@mutex, remaining)
        end
      end
      nil
    end

    def shutdown
      thread = @thread
      @thread = nil
      if thread&.alive? && thread != Thread.current
        @mutex.synchronize do
          @stop = true
          @wake.broadcast
        end
        thread.kill unless thread.join(2)
      end
      @profiler&.shutdown
      @stop = false
      @mutex.synchronize { @buffers.each_value(&:clear) }
    end

    # The child of a fork starts clean: the parent's worker owns whatever it
    # had buffered, and the parent's counts are its own.
    def after_fork
      @thread = nil
      @pid = nil
      @buffers.each_value(&:clear)
      @dropped.transform_values! { 0 }
      @aggregator.reset!
      @pause_until = nil
      @started_at = Time.now.to_f
      @profiler&.after_fork
      @runtime&.reset!
    end

    # --- the worker ----------------------------------------------------------

    private

    def limits_for(config)
      q = config.queue_size
      { txn: q, span: q * 4, metric: q * 2, log: q, profile: 8, page: q, marker: 500, llm: q * 2 }
    end

    def push_locked(type, record)
      buf = @buffers[type]
      if buf.size >= @limits[type]
        @dropped[type] += 1
      else
        buf << record
      end
    end

    # Puma and Solid Queue fork; threads do not survive a fork. Detect the
    # new pid on the next push and start fresh — plus Glass's own fork hook
    # calls after_fork eagerly, so a forked child heartbeats before its first
    # transaction.
    def ensure_running
      return if @thread&.alive? && @pid == Process.pid
      @mutex.synchronize do
        return if @thread&.alive? && @pid == Process.pid
        after_fork if @pid && @pid != Process.pid
        @pid = Process.pid
        @stop = false
        @thread = Thread.new { work }
        @thread.name = "glass"
      end
      Glass.install_fork_hook
    end

    def work
      Thread.current[:glass_agent] = true
      Thread.current.report_on_exception = false
      now = @clock.call
      # Jitter the first flush so a fleet restarted together does not report
      # in lockstep forever.
      @next_flush = now + @config.flush_interval * (0.3 + rand * 0.7)
      @next_runtime = now + 1.0
      loop do
        @mutex.synchronize do
          until @stop || @flush_requested
            wait = next_deadline - @clock.call
            break if wait <= 0
            @wake.wait(@mutex, wait)
          end
        end
        break if @stop
        tick
        break if @stop || @halted
      end
    rescue StandardError => e
      Glass.error("agent", e)
    ensure
      release_flush_waiters(@requested_seq)
    end

    def next_deadline
      deadlines = [@next_flush, @next_runtime]
      deadlines << @profiler.deadline if @profiler
      deadlines.compact.min
    end

    def tick
      now = @clock.call
      if @runtime && now >= @next_runtime
        @next_runtime = now + 10
        if @config.feature?(:runtime)
          @runtime.sample(@config.process_kind) rescue Glass.error("runtime", $!)
        end
      end
      if @profiler
        @profiler.tick(now).each { |rec| push(:profile, rec) } rescue Glass.error("profiler", $!)
      end
      requested, seq = @mutex.synchronize do
        r = @flush_requested
        @flush_requested = false
        [r, @requested_seq]
      end
      if requested || now >= @next_flush
        @next_flush = now + @config.flush_interval
        flush_now(final: @final)
        release_flush_waiters(seq)
      end
    end

    def release_flush_waiters(seq)
      @mutex.synchronize do
        @completed_seq = seq if seq > @completed_seq
        @flushed.broadcast
      end
    end

    # Drain everything buffered into one body and send it. Never raises.
    def flush_now(final: false)
      metrics = @aggregator.drain(Time.now.to_i, force: final)
      @mutex.synchronize do
        @dropped[:metric] += @aggregator.take_dropped
        metrics.each { |m| push_locked(:metric, m) }
      end
      if @pause_until && @clock.call < @pause_until
        shed_all # a 429 pause: drop what arrived, and count it
        return
      end
      @pause_until = nil
      lines, counts = take_batch
      # An idle process still says it is alive: a header alone is a heartbeat.
      body = build_body(lines)
      deliver(body, counts)
    rescue StandardError => e
      Glass.error("flush", e)
    end

    def shed_all
      @mutex.synchronize do
        @buffers.each { |type, buf| @dropped[type] += buf.size; buf.clear }
      end
    end

    # Up to max_records / max_bytes of records, in priority order: the
    # cheap uniform rows first, the bulky optional ones last. What does not
    # fit stays for the next flush (the buffers stay bounded either way).
    #
    # The lock is held only to take a slice and to put back what did not
    # fit: encoding thousands of records must not stall the request threads
    # pushing into the same buffers meanwhile.
    def take_batch
      lines = []
      counts = Hash.new(0)
      bytes = 0
      BATCH_ORDER.each do |type|
        room = @max_records - lines.size
        break if room <= 0
        slice = @mutex.synchronize { @buffers[type].shift(room) }
        next if slice.empty?
        unencodable = 0
        rest = nil
        slice.each_with_index do |record, i|
          line = encode(record)
          unless line
            unencodable += 1
            next
          end
          if bytes + line.bytesize > @max_bytes
            rest = slice[i..]
            break
          end
          lines << line
          bytes += line.bytesize
          counts[type] += 1
        end
        put_back(type, rest, unencodable) if rest || unencodable.positive?
      end
      [lines, counts]
    end

    # What did not fit goes back to the front, oldest first; whatever
    # arrived meanwhile keeps its place behind it, and if the two together
    # are over the bound the newest are dropped, as a push would have.
    def put_back(type, rest, unencodable)
      @mutex.synchronize do
        @dropped[type] += unencodable
        next unless rest
        buf = @buffers[type]
        buf.unshift(*rest)
        over = buf.size - @limits[type]
        if over.positive?
          buf.pop(over)
          @dropped[type] += over
        end
      end
    end

    def encode(record)
      JSON.generate(record)
    rescue StandardError => e
      Glass.error("encode", e)
      nil
    end

    def build_body(lines)
      body = +""
      body << JSON.generate(header) << "\n"
      lines.each { |l| body << l << "\n" }
      Zlib.gzip(body)
    end

    def header
      process = {
        kind: @config.process_kind, host: hostname, pid: Process.pid, started_at: @started_at,
        runtime: runtime_info
      }
      release = @config.release
      process[:release] = release unless release.to_s.empty?
      { v: 1, process: process, sent_at: Time.now.to_f, dropped: @mutex.synchronize { @dropped.dup } }
    end

    def runtime_info
      info = { ruby: RUBY_VERSION, agent: VERSION, client: "glass-ruby" }
      info[:rails] = ::Rails.version if defined?(::Rails) && ::Rails.respond_to?(:version)
      server = server_name
      info[:server] = server if server
      info
    end

    def server_name
      if defined?(::Puma) && ::Puma.instance_variable_get(:@get_stats) then "puma"
      elsif defined?(::Falcon::Server) then "falcon"
      elsif defined?(::Unicorn::HttpServer) then "unicorn"
      elsif $PROGRAM_NAME.to_s.include?("solid-queue") || File.basename($PROGRAM_NAME.to_s) == "jobs" then "solid_queue"
      end
    rescue StandardError
      nil
    end

    def hostname
      @hostname ||= (Socket.gethostname rescue "unknown")
    end

    # The protocol's response table, exactly.
    def deliver(body, counts)
      response = @sender.call(body)
      case response.status
      when 202
        @accepted_streak += 1
        recover_limits
        apply_reply(response.body)
      when 401, 403
        halt!
        count_dropped(counts)
      when 413
        @max_records = [@max_records / 2, MIN_MAX_RECORDS].max
        @max_bytes = [@max_bytes / 2, MIN_MAX_BYTES].max
        @accepted_streak = 0
        count_dropped(counts)
      when 429
        seconds = (response.retry_after || 60).to_i.clamp(RETRY_AFTER_RANGE)
        @pause_until = @clock.call + seconds
        count_dropped(counts)
      else
        count_dropped(counts)
      end
    rescue StandardError => e
      count_dropped(counts)
      Glass.error("send", e)
    end

    def recover_limits
      return if @max_records >= DEFAULT_MAX_RECORDS && @max_bytes >= DEFAULT_MAX_BYTES
      return if @accepted_streak < RECOVER_AFTER
      @accepted_streak = 0
      @max_records = [@max_records * 2, DEFAULT_MAX_RECORDS].min
      @max_bytes = [@max_bytes * 2, DEFAULT_MAX_BYTES].min
    end

    def apply_reply(body)
      reply = JSON.parse(body.to_s)
      return unless reply.is_a?(Hash)
      request = @config.apply_directives(reply["directives"])
      @profiler&.request(request) if request
    rescue JSON::ParserError
      nil
    end

    def count_dropped(counts)
      @mutex.synchronize { counts.each { |type, n| @dropped[type] += n } }
    end

    # 401: the key is unknown or revoked. Nothing this process can do is
    # useful until it restarts with a new one, so stop paying for
    # instrumentation too: Glass.enabled? reads this.
    def halt!
      @halted = true
      @stop = true
      @profiler&.shutdown
      Glass.halt!
    end
  end

  # POSTs one gzipped NDJSON body. Sized for a LAN hop to Glass: short
  # timeouts, no retries, no connection pooling worth the code.
  class HttpSender
    def initialize(config)
      @config = config
    end

    def call(body)
      uri = URI.parse(@config.endpoint)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @config.open_timeout
      http.read_timeout = @config.read_timeout
      http.write_timeout = @config.read_timeout if http.respond_to?(:write_timeout=)
      req = Net::HTTP::Post.new(uri.request_uri)
      req["Content-Type"] = "application/x-ndjson"
      req["Content-Encoding"] = "gzip"
      req["User-Agent"] = "glass-ruby/#{VERSION}"
      req["Authorization"] = "Bearer #{@config.api_key}"
      req.body = body
      resp = http.request(req)
      Transport::Response.new(resp.code.to_i, resp.body, resp["Retry-After"])
    end
  end
end
