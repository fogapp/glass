# frozen_string_literal: true

require "securerandom"
require_relative "attrs"

module Glass
  # One request or job while it runs: the wide event being assembled, plus
  # its child spans. Lives in fiber-local storage (Thread.current[:glass_txn])
  # for the duration; only the owning fiber touches it, so nothing here
  # locks. Every mutation is an attribute write or an array append, so a
  # request pays almost nothing for being recorded.
  class Transaction
    MAX_SPANS = 500
    MAX_ATTRS = 64
    N1_THRESHOLD = 5
    # Session and transaction control (`SET LOCAL statement_timeout` ahead
    # of every query, savepoints) repeats by design: it reads no rows, so it
    # is never an N+1, though it is still a round trip and a span.
    SESSION_STATEMENT = /\A\s*(?:SET|RESET|SHOW|BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)\b/i
    # Solid Queue's own bookkeeping after an enqueue: a job with a
    # concurrency limit takes its semaphore and lands in ready (or blocked)
    # one job at a time even when enqueued in bulk, so a scheduler that fans
    # out with perform_all_later repeats these per job with nothing the app
    # could preload. The enqueue itself — INSERT INTO solid_queue_jobs —
    # still counts: perform_later in a loop is an N+1 with a real fix.
    QUEUE_STATEMENT = /\A\s*(?:SELECT|UPDATE|DELETE)\b.*\bsolid_queue_|\A\s*INSERT\b.*\bsolid_queue_(?:semaphores|\w*executions)\b/im
    TRACEPARENT = /\A[0-9a-f]{2}-([0-9a-f]{32})-([0-9a-f]{16})-[0-9a-f]{2}\z/
    ZERO_TRACE = "0" * 32
    ZERO_SPAN = "0" * 16

    # A child span. `index` orders it within the transaction and doubles as
    # its id (see #span_hex); `ref` lets a subscriber's finish find the span
    # its start opened without a second stack.
    Span = Struct.new(:index, :parent, :kind, :name, :res, :start, :dur, :status, :attrs, :ref)

    attr_reader :kind, :trace_id, :parent_id, :ts, :start, :spans, :spans_dropped, :attrs, :stack, :thread_id
    attr_accessor :name, :status, :error, :method, :route, :path, :http, :format,
                  :queue, :queue_ms, :attempt, :db_ms, :db_n, :view_ms, :ext_ms, :ext_n,
                  :cache_hit, :cache_miss, :user, :visit, :origin, :n1, :controller_owned, :owner, :dur,
                  :user_identity

    def initialize(kind, name = nil, traceparent: nil, now: nil)
      @kind = kind
      @name = name
      @ts = Process.clock_gettime(Process::CLOCK_REALTIME)
      @start = now || Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @thread_id = Thread.current.object_id
      # One random draw for the trace id and the span id base; child span
      # ids are base + index, generated only if the trace is kept.
      hex = SecureRandom.hex(24)
      if traceparent && (m = TRACEPARENT.match(traceparent)) && m[1] != ZERO_TRACE && m[2] != ZERO_SPAN
        @trace_id = m[1]
        @parent_id = m[2]
      else
        @trace_id = hex[0, 32]
        @parent_id = nil
      end
      @base = (hex[32, 16].to_i(16) >> 1) | 1
      @status = "ok"
      @db_ms = 0.0
      @db_n = 0
      @view_ms = 0.0
      @ext_ms = 0.0
      @ext_n = 0
      @cache_hit = 0
      @cache_miss = 0
      @n1 = false
      @spans = []
      @spans_dropped = 0
      @stack = []
      @attrs = nil
      @sql_counts = nil
      @view_depth = 0
      @gc_time0 = GC.respond_to?(:total_time) ? GC.total_time : nil
      @alloc0 = GC.stat(:total_allocated_objects)
    end

    def span_id
      Kernel.format("%016x", @base)
    end

    def span_hex(span)
      span ? Kernel.format("%016x", @base + span.index + 1) : span_id
    end

    # The innermost open span (or the transaction itself) as a W3C
    # traceparent, for outbound propagation.
    def traceparent
      "00-#{@trace_id}-#{span_hex(@stack.last)}-01"
    end

    def current_span_hex
      span_hex(@stack.last)
    end

    # --- spans --------------------------------------------------------------

    # Opens a span nested under the innermost open one. nil past the cap:
    # the transaction keeps its totals but stops recording children.
    def start_span(kind, name, res = nil, now = nil, ref = nil)
      if @spans.size >= MAX_SPANS
        @spans_dropped += 1
        return nil
      end
      parent = @stack.last
      span = Span.new(@spans.size, parent&.index, kind, name, res,
                      now || Process.clock_gettime(Process::CLOCK_MONOTONIC), nil, "ok", nil, ref)
      @spans << span
      @stack << span
      span
    end

    def finish_span(span, now = nil, error: nil)
      return unless span
      span.dur = ((now || Process.clock_gettime(Process::CLOCK_MONOTONIC)) - span.start) * 1000.0
      span.status = "error" if error
      # Normal nesting pops the top; a mismatched finish (a start that ran
      # without a transaction) just removes the span wherever it is.
      if @stack.last.equal?(span)
        @stack.pop
      else
        @stack.delete(span)
      end
      span
    end

    # A completed leaf span (SQL, HTTP): start and duration are known.
    def add_span(kind, name, res, start, dur, attrs = nil, status = "ok")
      if @spans.size >= MAX_SPANS
        @spans_dropped += 1
        return nil
      end
      span = Span.new(@spans.size, @stack.last&.index, kind, name, res, start, dur, status, attrs)
      @spans << span
      span
    end

    # --- breakdown ----------------------------------------------------------

    def sql(name, normalized, start, dur, cached)
      if cached
        @cache_hit += 1
        return
      end
      @db_ms += dur
      @db_n += 1
      unless SESSION_STATEMENT.match?(normalized) || QUEUE_STATEMENT.match?(normalized)
        counts = (@sql_counts ||= Hash.new(0))
        counts[normalized] += 1
        @n1 = true if counts[normalized] >= N1_THRESHOLD
      end
      add_span("sql", name, normalized, start, dur)
    end

    def view_start(name, res, now = nil)
      @view_depth += 1
      start_span("view", name, res, now)
    end

    # Only a top-level render adds to view_ms: nested partials are inside
    # their template's time already.
    def view_finish(span, now = nil, attrs = nil)
      now ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @view_depth -= 1 if @view_depth.positive?
      if span
        finish_span(span, now)
        span.attrs = attrs if attrs
        @view_ms += span.dur if @view_depth.zero?
      end
    end

    def tag(hash)
      attrs = (@attrs ||= {})
      hash.each do |k, v|
        k = k.to_s
        next if attrs.size >= MAX_ATTRS && !attrs.key?(k)
        attrs[k] = Attrs.scalar(v)
      end
    end

    def mark_error(error_class = nil)
      @status = "error"
      @error ||= error_class.to_s if error_class
    end

    def finish(now = nil)
      now ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @finish = now
      @dur = (now - @start) * 1000.0
      # Process-wide deltas: GC pauses hold every thread, so GC time inside
      # this interval is time this transaction lost. Allocations by other
      # threads during the interval are counted too — an honest upper bound.
      @gc_ms = @gc_time0 ? (GC.total_time - @gc_time0) / 1_000_000.0 : nil
      @alloc = GC.stat(:total_allocated_objects) - @alloc0
      self
    end

    def finished_at
      @finish
    end

    # --- records --------------------------------------------------------------

    def to_record(kept:)
      rec = { t: "txn", ts: @ts, kind: @kind, name: @name.to_s, trace: @trace_id, span: span_id, dur: @dur }
      rec[:parent] = @parent_id if @parent_id
      rec[:status] = @status
      rec[:error] = @error if @error
      if @kind == "request"
        rec[:method] = @method if @method
        rec[:route] = @route if @route
        rec[:path] = @path if @path && Glass.config.record_paths
        rec[:http] = @http if @http
        rec[:format] = @format if @format
      else
        rec[:queue] = @queue if @queue
        rec[:queue_ms] = @queue_ms if @queue_ms
        rec[:attempt] = @attempt if @attempt
      end
      rec[:db_ms] = @db_ms
      rec[:db_n] = @db_n
      rec[:view_ms] = @view_ms
      rec[:ext_ms] = @ext_ms
      rec[:ext_n] = @ext_n
      rec[:cache_hit] = @cache_hit
      rec[:cache_miss] = @cache_miss
      rec[:gc_ms] = @gc_ms if @gc_ms
      rec[:alloc] = @alloc if @alloc
      rec[:n1] = @n1
      rec[:user] = @user if @user
      rec[:visit] = @visit if @visit
      rec[:origin] = @origin if @origin
      rec[:kept] = kept
      attrs = @attrs
      if @spans_dropped.positive?
        attrs = (attrs || {}).merge("spans_dropped" => @spans_dropped)
      end
      rec[:attrs] = attrs if attrs && !attrs.empty?
      rec
    end

    def span_records
      @spans.filter_map do |s|
        next unless s.dur # a span still open when the transaction ended
        rec = {
          t: "span", ts: @ts + (s.start - @start), trace: @trace_id, span: span_hex(s),
          parent: s.parent ? Kernel.format("%016x", @base + s.parent + 1) : span_id,
          kind: s.kind, name: s.name.to_s, dur: s.dur, status: s.status
        }
        rec[:res] = s.res if s.res
        rec[:attrs] = s.attrs if s.attrs && !s.attrs.empty?
        rec
      end
    end
  end
end
