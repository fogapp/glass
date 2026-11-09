# frozen_string_literal: true

# Glass: the observability agent for the home fleet.
#
# One gem line in a Rails app and — given GLASS_URL and GLASS_API_KEY — the
# app reports requests, SQL, jobs, outbound HTTP, runtime vitals, logs and
# continuous profiles to Glass over `glass-ingest/1`, and offers a StatsD
# vocabulary for its own metrics. Without both values every public method
# is a cheap no-op and no thread is started.
#
# The discipline is Flare's (fog's clients/flare): one background thread,
# bounded buffers, drop on overflow, never retry into a dead server, honour
# 429, stop on 401, flush at exit, and nothing on a request path may block
# on Glass or raise into the app.

require_relative "glass/version"
require_relative "glass/bounded_cache"
require_relative "glass/config"
require_relative "glass/sketch"
require_relative "glass/aggregator"
require_relative "glass/sql"
require_relative "glass/origin"
require_relative "glass/transaction"
require_relative "glass/tracer"
require_relative "glass/transport"
require_relative "glass/model_call"
require_relative "glass/runtime"
require_relative "glass/profiler"
require_relative "glass/relay"
require_relative "glass/middleware"
require_relative "glass/railtie" if defined?(Rails::Railtie)

module Glass
  # Guards lazy singleton construction: concurrent first calls must not
  # each build a Transport (orphaning buffers and a worker thread).
  LOCK = Mutex.new
  private_constant :LOCK

  module ForkHook
    def _fork
      Glass.before_fork
      pid = super
      Glass.after_fork_in_child if pid.zero?
      pid
    end
  end

  class << self
    def config
      @config || LOCK.synchronize { @config ||= Config.new }
    end

    def configure
      yield config
      attach_rails_late
      self
    end

    # Live: configured, and not told to stop by a 401.
    def enabled?
      !@halted && config.enabled?
    end

    def halt!
      @halted = true
    end

    # --- metrics (StatsD-shaped) -----------------------------------------------

    def increment(name, by = 1, tags: {})
      return nil unless enabled?
      aggregator.counter(name, by, tags)
    rescue StandardError => e
      error("increment", e)
    end

    def decrement(name, by = 1, tags: {})
      return nil unless enabled?
      aggregator.counter(name, -by, tags)
    rescue StandardError => e
      error("decrement", e)
    end

    def gauge(name, value, tags: {})
      return nil unless enabled?
      aggregator.gauge(name, value, tags)
    rescue StandardError => e
      error("gauge", e)
    end

    def histogram(name, value, tags: {}, unit: nil)
      return nil unless enabled?
      aggregator.dist(name, value, tags, unit)
    rescue StandardError => e
      error("histogram", e)
    end

    def timing(name, ms, tags: {})
      return nil unless enabled?
      aggregator.dist(name, ms, tags, "ms")
    rescue StandardError => e
      error("timing", e)
    end

    # Times the block as a distribution and, inside a transaction, as a
    # `custom` span. Returns the block's value; the block's exceptions
    # propagate (and mark the span).
    def time(name, tags: {})
      return yield unless enabled?
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      timed = ->(now) { aggregator.dist(name, (now - start) * 1000.0, tags, "ms") }
      around_span(Tracer.current, "custom", name, nil, start, "time", timed) { yield }
    end

    def set(name, member, tags: {})
      return nil unless enabled?
      aggregator.set(name, member, tags)
    rescue StandardError => e
      error("set", e)
    end

    # A marker: something that happened, drawn on every chart.
    def event(title, tags: {}, kind: "event")
      return nil unless enabled?
      rec = { t: "marker", ts: Time.now.to_f, kind: kind.to_s, title: title.to_s[0, 200] }
      rec[:attrs] = config.scrub(tags.transform_keys(&:to_s)) if tags && !tags.empty?
      transport.push(:marker, rec)
    rescue StandardError => e
      error("event", e)
    end

    # One call to a model: what was asked for, what it cost, how long it
    # took — never a prompt or a completion. Sends the protocol's `llm`
    # record (every call is kept, never sampled) and the `ai.*` metrics.
    # Keywords (all optional but provider, model and duration_ms; see the
    # README): provider:, model:, duration_ms:, started_at: (Time or epoch
    # seconds; now minus the duration when omitted), served:, tier:,
    # purpose:, origin:, agent:, session:, round:, input_tokens: (uncached),
    # cache_read_tokens:, cache_write_tokens:, output_tokens:,
    # reasoning_tokens:, estimated:, cost_usd:, cost_source:, ttft_ms:,
    # first_text_ms:, itl_p95_ms:, queue_ms:, load_ms:, prompt_ms:,
    # decode_ms:, concurrent:, stream:, stop:, status:, error: (the class),
    # retry_of:, fallback_from:, route:, tools:, tools_valid:, trace:,
    # span:, attrs:. Inside a transaction the call joins its trace unless
    # trace: says otherwise. Keywords it does not know are ignored, never
    # raised: a typo must not take a request down.
    def model_call(**call)
      return nil unless enabled?
      call[:trace] ||= Tracer.current&.trace_id
      rec = ModelCall.record(call, scrub: config.method(:scrub))
      return nil unless rec
      transport.push(:llm, rec)
      ModelCall.metrics(aggregator, rec, call)
      nil
    rescue StandardError => e
      error("model_call", e)
    end

    # --- tracing --------------------------------------------------------------

    # Attributes on the current transaction (scrubbed by key).
    def tag(**attrs)
      return nil unless enabled?
      txn = Tracer.current
      txn&.tag(config.scrub(attrs))
      nil
    rescue StandardError => e
      error("tag", e)
    end

    # A custom span around the block inside the current transaction.
    # Outside one, the block simply runs.
    def span(name, kind: "custom", resource: nil)
      txn = enabled? ? Tracer.current : nil
      return yield unless txn
      around_span(txn, kind, name, resource, nil, "span") { yield }
    end

    def current_transaction
      enabled? ? Tracer.current : nil
    end

    def trace_id
      current_transaction&.trace_id
    end

    # W3C traceparent for the innermost open span, or nil outside a trace.
    def traceparent
      current_transaction&.traceparent
    end

    # --- lifecycle ------------------------------------------------------------

    # Start the agent thread now. The railtie calls this at boot for server
    # and worker processes; otherwise the first record starts it.
    def start
      return nil unless enabled?
      install_fork_hook
      transport.start
      nil
    end

    # Installed once the agent runs (Ruby 3.1+ routes fork, Process.fork
    # and Kernel#fork through Process._fork): the parent stops its profile
    # window before the fork, the child restarts the agent right away.
    def install_fork_hook
      return if @fork_hook || !::Process.respond_to?(:_fork)
      @fork_hook = true
      ::Process.singleton_class.prepend(ForkHook)
    end

    # Drain buffers, waiting at most `timeout` seconds. Called at exit.
    def flush(timeout: 2)
      @transport&.flush(timeout: timeout, final: true)
    end

    def transport
      @transport || begin
        cfg = config
        agg = aggregator
        LOCK.synchronize do
          @transport ||= Transport.new(cfg, aggregator: agg, runtime: Runtime.new(cfg, agg),
                                       profiler: Profiler.new(cfg, Tracer.intervals))
        end
      end
    end

    def aggregator
      @aggregator || LOCK.synchronize { @aggregator ||= Aggregator.new }
    end

    # The one internal counter: something inside the agent raised. Counted,
    # never raised into the app; logged at debug so a broken subscriber is
    # findable without being noisy.
    def error(where, exception)
      @aggregator&.counter("glass.agent.errors", 1, { where: where.to_s })
      logger = @config&.logger
      if logger.respond_to?(:debug)
        # Muted: the line must not come back through the log sink.
        previous = Thread.current[:glass_muted]
        Thread.current[:glass_muted] = true
        begin
          logger.debug { "glass: #{where}: #{exception.class}: #{exception.message} (#{exception.backtrace&.first})" }
        ensure
          Thread.current[:glass_muted] = previous
        end
      end
      nil
    rescue StandardError
      nil
    end

    # Test hook: forget all state, including the worker thread.
    def reset!
      LOCK.synchronize do
        @transport&.shutdown
        @transport = nil
        @aggregator = nil
        @config = nil
        @halted = false
        @rails_attached = nil
        Tracer.reset!
        Sql.reset!
        Origin.reset!
        NetHttp.reset! if defined?(NetHttp)
        Relay::Visits.reset!
      end
    end

    # Fork hook (installed once the agent runs): the parent stops its
    # profile so no collector thread state crosses the fork; the child
    # starts a clean agent so it heartbeats before its first transaction.
    def before_fork
      @transport&.profiler&.before_fork
    rescue StandardError => e
      error("fork", e)
    end

    def after_fork_in_child
      t = @transport
      return unless t
      t.after_fork
      t.start
    rescue StandardError => e
      error("fork", e)
    end

    private

    # A span around the block inside `txn` (nil: the block just runs, and
    # `on_finish` still gets the monotonic end time). The block's value is
    # returned and its exceptions propagate, marking the span; nothing Glass
    # does around it may raise into the app.
    def around_span(txn, kind, name, resource, start, where, on_finish = nil)
      span = begin
        txn&.start_span(kind.to_s, name.to_s, resource, start)
      rescue StandardError => e
        error(where, e)
        nil
      end
      failed = false
      begin
        yield
      rescue Exception
        failed = true
        raise
      ensure
        begin
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          txn&.finish_span(span, now, error: failed)
          on_finish&.call(now)
        rescue StandardError => e
          error(where, e)
        end
      end
    end

    # Best-effort repair for Gemfile ordering: with `gem "glass"` above
    # `gem "rails"`, Rails::Railtie is not defined when glass is required,
    # the railtie never loads, and the gem would be silently inert. The
    # first configure checks again and installs what the railtie would
    # have — subscribers, patches, the log sink, the agent — though the
    # middleware can only be added while the stack is still open, so
    # request transactions then cover the controller action only.
    def attach_rails_late
      return if @rails_attached || defined?(Glass::Railtie)
      return unless defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application
      return unless enabled?
      @rails_attached = true
      require_relative "glass/rails"
      Glass::Integration.attach(::Rails.application)
    rescue StandardError => e
      error("attach", e)
    end
  end
end

at_exit { Glass.flush(timeout: 2) if Glass.enabled? }
