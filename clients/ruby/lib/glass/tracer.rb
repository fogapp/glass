# frozen_string_literal: true

require "digest"
require "time"
require_relative "transaction"
require_relative "sketch"
require_relative "origin"
require_relative "relay"

module Glass
  # Tail sampling: the transaction row is always sent; its
  # spans go too when the trace is worth a waterfall — it errored, it was
  # slower than the endpoint's running p95, it is the first sight of the
  # endpoint this boot, or it won the trace_sample_rate draw.
  class Sampler
    MIN_OBSERVATIONS = 20
    MAX_NAMES = 2_000
    REFRESH_EVERY = 10

    Running = Struct.new(:sketch, :p95, :since)

    def initialize
      @mutex = Mutex.new
      @names = {}
    end

    def keep?(name, dur, error, rate, draw = nil)
      first = false
      slow = false
      @mutex.synchronize do
        r = @names[name]
        if r.nil?
          if @names.size < MAX_NAMES
            first = true
            r = @names[name] = Running.new(Sketch.new, nil, 0)
          end
        elsif r.sketch.count >= MIN_OBSERVATIONS
          # The p95 is re-read every few observations; sorting the buckets
          # on every request would be the most expensive thing on the path.
          if r.p95.nil? || r.since >= REFRESH_EVERY
            r.p95 = r.sketch.quantile(0.95)
            r.since = 0
          end
          slow = dur > r.p95
        end
        if r
          r.sketch.add(dur)
          r.since += 1
        end
      end
      return true if error || first || slow
      rate.positive? && (draw || Kernel.rand) < rate
    end

    def reset!
      @mutex.synchronize { @names.clear }
    end
  end

  # Per-thread transaction intervals for profile attribution:
  # the profiler joins Vernier's per-thread, timestamped samples to
  # these at the end of each window. Bounded per window; past the cap new
  # intervals are dropped (the samples then read as unattributed).
  class Intervals
    MAX = 50_000

    def initialize
      @mutex = Mutex.new
      @done = []   # [thread_id, start, finish, name]
      @active = {} # thread_id => txn
    end

    def begin(txn)
      @mutex.synchronize { @active[txn.thread_id] = txn }
    end

    def finish(txn)
      @mutex.synchronize do
        @active.delete(txn.thread_id) if @active[txn.thread_id].equal?(txn)
        @done << [txn.thread_id, txn.start, txn.finished_at, txn.name] if @done.size < MAX
      end
    end

    # Everything finished since the last take, plus the transactions still
    # running (open-ended, named as far as they are known). Clears the
    # finished list.
    def take
      @mutex.synchronize do
        done = @done
        @done = []
        @active.each_value { |txn| done << [txn.thread_id, txn.start, nil, txn.name] }
        done
      end
    end

    def reset!
      @mutex.synchronize do
        @done.clear
        @active.clear
      end
    end
  end

  # Starting and finishing transactions, and everything decided at the
  # end: sampling, RED metrics, identity, records. Class-level state is
  # per process and reset with Glass.reset!.
  module Tracer
    KEY = :glass_txn
    USER_MAX = 120
    VISIT = /\A[\w.:\-]{1,64}\z/

    class << self
      def current
        Thread.current[KEY]
      end

      def sampler
        @sampler ||= Sampler.new
      end

      def intervals
        @intervals ||= Intervals.new
      end

      def reset!
        @sampler = nil
        @intervals = nil
        @hmac = nil
        Thread.current[KEY] = nil
      end

      # --- requests ---------------------------------------------------------

      def start_request(env)
        config = Glass.config
        txn = Transaction.new("request", nil, traceparent: env["HTTP_TRACEPARENT"])
        txn.method = env["REQUEST_METHOD"]
        path = "#{env['SCRIPT_NAME']}#{env['PATH_INFO']}"
        txn.path = path.empty? ? "/" : path[0, 2_000]
        visit = env["HTTP_X_GLASS_VISIT"]
        txn.visit = visit if visit.is_a?(String) && VISIT.match?(visit)
        Relay::Visits.seen(txn.visit) if txn.visit && config.browser_active?
        txn.origin = Origin.classify(env, config.vpn_networks)
        txn.queue_ms = queue_ms(env["HTTP_X_REQUEST_START"] || env["HTTP_X_QUEUE_START"], txn.ts)
        Thread.current[KEY] = txn
        intervals.begin(txn) if config.profiling_active?
        txn
      end

      def finish_request(txn, status, error = nil)
        txn.http = status.to_i if status
        txn.mark_error(error.class.name) if error
        txn.mark_error(nil) if txn.http && txn.http >= 500 && txn.status != "error"
        txn.name ||= default_request_name(txn)
        txn.finish
        Thread.current[KEY] = nil
        complete(txn)
      end

      # A request that never reached a controller is named by what it
      # was: a static file, or its status.
      def default_request_name(txn)
        if txn.http && (txn.http == 200 || txn.http == 206 || txn.http == 304) &&
           (txn.method == "GET" || txn.method == "HEAD")
          "(static)"
        else
          "(#{txn.http || 'unknown'})"
        end
      end

      # --- jobs -------------------------------------------------------------

      def start_job(job)
        traceparent = job.respond_to?(:glass_traceparent) ? job.glass_traceparent : nil
        txn = Transaction.new("job", job.class.name, traceparent: traceparent)
        txn.queue = job.queue_name.to_s if job.respond_to?(:queue_name)
        txn.owner = job
        Thread.current[KEY] = txn
        intervals.begin(txn) if Glass.config.profiling_active?
        set_error_context(txn)
        txn
      end

      def finish_job(txn, job, error = nil)
        txn.attempt = job.executions if job.respond_to?(:executions) && job.executions
        txn.queue_ms = job_queue_ms(job, txn.ts)
        txn.mark_error(error.class.name) if error
        txn.user = resolve_user
        txn.finish
        Thread.current[KEY] = nil
        complete(txn)
      end

      # --- shared -------------------------------------------------------------

      # Sampling, RED metrics, then hand the records to the transport. Runs
      # on the request thread; everything here is arithmetic and appends.
      def complete(txn)
        config = Glass.config
        intervals.finish(txn) if config.profiling_active?
        name = txn.name.to_s
        error = txn.status == "error"
        red(txn, name, error)
        kept = sampler.keep?(name, txn.dur, error, config.trace_sample_rate)
        spans = kept ? txn.span_records : nil
        Glass.transport.push_transaction(txn.to_record(kept: kept && !spans.empty?), spans)
        nil
      end

      def red(txn, name, error)
        agg = Glass.aggregator
        if txn.kind == "request"
          status_class = txn.http ? "#{txn.http / 100}xx" : "0xx"
          agg.counter("rails.request.count", 1, { name: name, status: status_class })
          agg.dist("rails.request.duration", txn.dur, { name: name }, "ms")
          agg.counter("rails.request.errors", 1, { name: name }) if error
        else
          tags = { name: name, queue: txn.queue }
          agg.counter("rails.job.count", 1, tags)
          agg.dist("rails.job.duration", txn.dur, tags, "ms")
          agg.counter("rails.job.errors", 1, tags) if error
          agg.dist("rails.job.queue_latency", txn.queue_ms, tags, "ms") if txn.queue_ms
        end
      end

      # Called where Current is still set (the process_action subscriber,
      # the job's perform finish). Identity per the directive: nothing, a
      # keyed hash of the app's user id, or a display name.
      def resolve_user
        resolve_identity&.first
      end

      # [user as the directive wants it, the keyed hash], or nil. The keyed
      # hash is what a `visitor` carries once the visit is identified, in
      # every mode that identifies at all.
      def resolve_identity
        config = Glass.config
        mode = config.identity
        return nil if mode == "anonymous"
        id = config.user&.call
        return nil if id.nil? || id.to_s.empty?
        keyed = "u_" + hmac_sha256_hex(config.api_key.to_s, id.to_s)[0, 16]
        if mode == "named"
          name = config.user_name&.call
          return [name.to_s[0, USER_MAX], keyed] if name && !name.to_s.empty?
        end
        [keyed, keyed]
      rescue StandardError => e
        Glass.error("identity", e)
        nil
      end

      # The browser → server join: a request that carries the visit vouches
      # for it, and an identified one names it.
      def join_visit(txn)
        return unless txn.visit
        user, keyed = txn.user_identity
        Relay::Visits.seen(txn.visit, user, keyed)
      rescue StandardError => e
        Glass.error("visit", e)
      end

      # HMAC-SHA256 over Digest (stdlib, no OpenSSL dependency); the padded
      # key blocks are memoized per api_key.
      def hmac_sha256_hex(key, message)
        if @hmac.nil? || @hmac[0] != key
          k = key.bytesize > 64 ? Digest::SHA256.digest(key) : key.b
          k = k.ljust(64, "\0")
          ipad = k.bytes.map { |b| b ^ 0x36 }.pack("C*")
          opad = k.bytes.map { |b| b ^ 0x5c }.pack("C*")
          @hmac = [key, ipad, opad]
        end
        _, ipad, opad = @hmac
        Digest::SHA256.hexdigest(opad + Digest::SHA256.digest(ipad + message.b))
      end

      # Lets Flare events link back to the trace they happened in. Only
      # meaningful after the Rails executor has started (it resets the
      # execution context on entry), so it is called from an executor hook
      # and at job start rather than from the middleware.
      def set_error_context(txn = current)
        return unless txn && defined?(::Rails) && ::Rails.respond_to?(:error)
        ::Rails.error.set_context(glass_trace_id: txn.trace_id)
      rescue StandardError
        nil
      end

      # X-Request-Start / X-Queue-Start: "t=<seconds>" or an integer in
      # seconds, milliseconds, microseconds or nanoseconds, by magnitude.
      def queue_ms(header, now)
        return nil if header.nil?
        raw = header.to_s.delete_prefix("t=").to_f
        return nil if raw <= 0
        seconds =
          if raw > 1e17 then raw / 1e9
          elsif raw > 1e14 then raw / 1e6
          elsif raw > 1e11 then raw / 1e3
          else raw
          end
        ms = (now - seconds) * 1000.0
        ms >= 0 && ms < 3_600_000 ? ms : nil
      end

      def job_queue_ms(job, now)
        enqueued = job.respond_to?(:enqueued_at) ? job.enqueued_at : nil
        return nil if enqueued.nil?
        at = time_to_f(enqueued)
        scheduled = job.respond_to?(:scheduled_at) ? job.scheduled_at : nil
        if scheduled
          s = time_to_f(scheduled)
          at = s if s && at && s > at
        end
        return nil unless at
        ms = (now - at) * 1000.0
        ms >= 0 ? ms : 0.0
      rescue StandardError
        nil
      end

      def time_to_f(value)
        case value
        when Time then value.to_f
        when String then Time.iso8601(value).to_f
        else value.respond_to?(:to_time) ? value.to_time.to_f : nil
        end
      rescue StandardError
        nil
      end
    end
  end
end
