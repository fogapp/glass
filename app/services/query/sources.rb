# typed: strict
# frozen_string_literal: true

module Query
  # The registry: every table the engine may read, and every column of it a
  # query may name. A field's `sql` is the only place an identifier enters a
  # compiled statement — a query can ask for `duration`, never for a column.
  module Sources
    extend T::Sig

    class Type < T::Enum
      enums do
        Text = new("text")
        Int = new("integer")
        Number = new("number")
        Bool = new("boolean")
        # A 128-bit trace id: a uuid column, 32 hex characters on the wire.
        Trace = new("trace")
        # The reporting app: an integer column, a slug to everyone else.
        App = new("app")
      end
    end

    class Field < T::Struct
      extend T::Sig

      const :name, String
      const :sql, String
      const :type, Type
      const :label, String
      # A measure is a number worth aggregating (avg, p95); everything else
      # is a dimension — something to filter and group by.
      const :measure, T::Boolean, default: false
      const :unit, T.nilable(String), default: nil
      # The facet of a unit of work this field belongs to (Telemetry::Work);
      # nil for the spine, which every kind has.
      const :facet, T.nilable(String), default: nil

      sig { returns(T::Boolean) }
      def numeric? = type == Type::Int || type == Type::Number
    end

    class Source < T::Struct
      extend T::Sig

      const :name, String
      const :label, String
      const :table, String
      const :fields, T::Array[Field]
      # What one row counts for: `weight` where rows can stand for several
      # (adaptive sampling), `1` elsewhere.
      const :weight_sql, String, default: "1"
      # What a bare word in the filter searches.
      const :text_fields, T::Array[String], default: []
      # The columns a `list` answers with, in order.
      const :list_fields, T::Array[String]
      # The column of free-form attributes (`@key`), when rows carry them —
      # a list answers with it as `attrs` whatever the table calls it.
      const :attrs, T.nilable(String), default: "attrs"

      sig { params(name: String).returns(T.nilable(Field)) }
      def field(name) = fields.find { |field| field.name == name }

      # The field, or Invalid naming the ones there are.
      sig { params(name: String).returns(Field) }
      def field!(name)
        field(name) || begin
          known = fields.map(&:name)
          guess = DidYouMean::SpellChecker.new(dictionary: known).correct(name).first
          hint = guess ? "did you mean “#{guess}”?" : "fields are #{known.join(', ')}; use @#{name} for an attribute"
          raise Invalid, "#{self.name} has no field “#{name}” — #{hint}"
        end
      end

      sig { returns(T::Boolean) }
      def status? = !field("status").nil?

      # How many rows a group stands for: a count, or the sum of the
      # weights where rows are sampled.
      sig { returns(String) }
      def count_sql = weight_sql == "1" ? "count(*)" : "sum(#{weight_sql})"
    end

    # A unit of work's fields, by facet (Telemetry::Work). The spine first.
    WORK_FIELDS = T.let([
      Field.new(name: "app", sql: "app_id", type: Type::App, label: "App"),
      Field.new(name: "kind", sql: "kind", type: Type::Text, label: "Kind"),
      Field.new(name: "name", sql: "name", type: Type::Text, label: "Name"),
      Field.new(name: "status", sql: "status", type: Type::Text, label: "Status"),
      Field.new(name: "error", sql: "error_class", type: Type::Text, label: "Error class"),
      Field.new(name: "process", sql: "process", type: Type::Text, label: "Process"),
      Field.new(name: "host", sql: "host", type: Type::Text, label: "Host"),
      Field.new(name: "release", sql: "release", type: Type::Text, label: "Release"),
      Field.new(name: "user", sql: "user_ref", type: Type::Text, label: "User"),
      Field.new(name: "kept", sql: "kept", type: Type::Bool, label: "Trace kept"),
      Field.new(name: "trace", sql: "trace_id", type: Type::Trace, label: "Trace"),
      Field.new(name: "span", sql: "span_id", type: Type::Int, label: "Span"),
      Field.new(name: "duration", sql: "duration_ms", type: Type::Number, label: "Duration", measure: true, unit: "ms"),

      Field.new(name: "http_status", sql: "http_status", type: Type::Int, label: "HTTP status", facet: "http"),
      Field.new(name: "method", sql: "method", type: Type::Text, label: "Method", facet: "http"),
      Field.new(name: "route", sql: "route", type: Type::Text, label: "Route", facet: "http"),
      Field.new(name: "path", sql: "path", type: Type::Text, label: "Path", facet: "http"),
      Field.new(name: "format", sql: "format", type: Type::Text, label: "Format", facet: "http"),
      Field.new(name: "visit", sql: "visit_id", type: Type::Text, label: "Visit", facet: "http"),
      Field.new(name: "origin", sql: "origin", type: Type::Text, label: "Network origin", facet: "http"),

      Field.new(name: "queue", sql: "queue", type: Type::Text, label: "Queue", facet: "queue"),
      Field.new(name: "queue_ms", sql: "queue_ms", type: Type::Number, label: "Queue wait", measure: true, unit: "ms", facet: "queue"),
      Field.new(name: "attempt", sql: "attempt", type: Type::Int, label: "Attempt", facet: "queue"),

      Field.new(name: "db", sql: "db_ms", type: Type::Number, label: "Database time", measure: true, unit: "ms", facet: "rails"),
      Field.new(name: "db_count", sql: "db_count", type: Type::Int, label: "Queries", measure: true, facet: "rails"),
      Field.new(name: "view", sql: "view_ms", type: Type::Number, label: "View time", measure: true, unit: "ms", facet: "rails"),
      Field.new(name: "gc", sql: "gc_ms", type: Type::Number, label: "GC time", measure: true, unit: "ms", facet: "rails"),
      Field.new(name: "allocations", sql: "allocations", type: Type::Int, label: "Allocations", measure: true, facet: "rails"),
      Field.new(name: "cache_hits", sql: "cache_hits", type: Type::Int, label: "Cache hits", measure: true, facet: "rails"),
      Field.new(name: "cache_misses", sql: "cache_misses", type: Type::Int, label: "Cache misses", measure: true, facet: "rails"),
      Field.new(name: "n_plus_one", sql: "n_plus_one", type: Type::Bool, label: "N+1 seen", facet: "rails"),

      Field.new(name: "ext", sql: "ext_ms", type: Type::Number, label: "External time", measure: true, unit: "ms", facet: "outbound"),
      Field.new(name: "ext_count", sql: "ext_count", type: Type::Int, label: "External calls", measure: true, facet: "outbound"),

      Field.new(name: "agent", sql: "agent", type: Type::Text, label: "Agent", facet: "ai"),
      Field.new(name: "session", sql: "session", type: Type::Text, label: "Session", facet: "ai"),
      Field.new(name: "trigger", sql: "trigger", type: Type::Text, label: "Trigger", facet: "ai"),
      Field.new(name: "channel", sql: "channel", type: Type::Text, label: "Channel", facet: "ai"),
      Field.new(name: "stop", sql: "stop", type: Type::Text, label: "Stop reason", facet: "ai"),
      Field.new(name: "model", sql: "model", type: Type::Text, label: "Answering model", facet: "ai"),
      Field.new(name: "rounds", sql: "rounds", type: Type::Int, label: "Model rounds", measure: true, facet: "ai"),
      Field.new(name: "calls", sql: "model_calls", type: Type::Int, label: "Model calls", measure: true, facet: "ai"),
      Field.new(name: "tools", sql: "tool_calls", type: Type::Int, label: "Tool calls", measure: true, facet: "ai"),
      Field.new(name: "tool_errors", sql: "tool_errors", type: Type::Int, label: "Failed tool calls", measure: true, facet: "ai"),
      Field.new(name: "tokens_in", sql: "tokens_in", type: Type::Int, label: "Input tokens", measure: true, unit: "tokens", facet: "ai"),
      Field.new(name: "tokens_out", sql: "tokens_out", type: Type::Int, label: "Output tokens", measure: true, unit: "tokens", facet: "ai"),
      Field.new(name: "cache_read", sql: "tokens_cache_read", type: Type::Int, label: "Cached input tokens read", measure: true,
        unit: "tokens", facet: "ai"),
      Field.new(name: "cache_write", sql: "tokens_cache_write", type: Type::Int, label: "Cached input tokens written", measure: true,
        unit: "tokens", facet: "ai"),
      Field.new(name: "input_total", sql: "(tokens_in + tokens_cache_read + tokens_cache_write)", type: Type::Int,
        label: "Input tokens, cached or not", measure: true, unit: "tokens", facet: "ai"),
      Field.new(name: "cost", sql: "cost_usd", type: Type::Number, label: "Cost", measure: true, unit: "usd", facet: "ai"),

      Field.new(name: "prep", sql: "prep_ms", type: Type::Number, label: "Preparing", measure: true, unit: "ms", facet: "experience"),
      Field.new(name: "model_ms", sql: "model_ms", type: Type::Number, label: "Model time", measure: true, unit: "ms", facet: "experience"),
      Field.new(name: "tool_ms", sql: "tool_ms", type: Type::Number, label: "Tool time", measure: true, unit: "ms", facet: "experience"),
      Field.new(name: "wait", sql: "wait_ms", type: Type::Number, label: "Waiting on a person", measure: true, unit: "ms",
        facet: "experience"),
      Field.new(name: "deliver", sql: "deliver_ms", type: Type::Number, label: "Delivering", measure: true, unit: "ms",
        facet: "experience"),
      Field.new(name: "lag", sql: "lag_ms", type: Type::Number, label: "Lag before it began", measure: true, unit: "ms",
        facet: "experience"),
      Field.new(name: "ttft", sql: "ttft_ms", type: Type::Number, label: "Time to first visible text", measure: true, unit: "ms",
        facet: "experience"),
      Field.new(name: "stall", sql: "stall_ms", type: Type::Number, label: "Longest silence", measure: true, unit: "ms",
        facet: "experience"),
      # How long the app took, leaving out the time it spent waiting for a
      # person to answer: what latency and Apdex mean for a run. For every
      # other kind it is the duration.
      Field.new(name: "active", sql: "greatest(duration_ms - wait_ms, 0)", type: Type::Number, label: "Active time", measure: true,
        unit: "ms", facet: "experience")
    ].freeze, T::Array[Field])

    # Duration less a kind's phases (Telemetry::Work): the time nothing
    # accounts for. One expression for every kind — the app's own Ruby for
    # a request, the hole in the timeline for a run.
    sig { returns(String) }
    def self.remainder_sql
      column = WORK_FIELDS.to_h { |field| [ field.name, field.sql ] }
      sum = ->(kind) { kind.phases.map { |phase| "coalesce(#{column.fetch(phase)}, 0)" }.join(" + ") }
      declared = Telemetry::Work::KINDS.map { |kind| "WHEN '#{kind.name}' THEN #{sum.call(kind)}" }
      "greatest(duration_ms - (CASE kind #{declared.join(' ')} ELSE #{sum.call(Telemetry::Work::GENERIC)} END), 0)"
    end

    TRANSACTIONS = Source.new(
      name: "transactions", label: "Requests, jobs and runs", table: "transactions", weight_sql: "weight",
      text_fields: %w[name path error],
      list_fields: %w[app kind name status http_status method path duration db db_count view ext gc
                      release process host user visit origin error trace span kept n_plus_one queue queue_ms
                      agent session trigger channel stop model rounds calls tools tool_errors tokens_in tokens_out
                      cache_read cache_write cost prep model_ms tool_ms wait deliver lag ttft stall],
      fields: WORK_FIELDS + [
        Field.new(name: "app_time", sql: remainder_sql, type: Type::Number, label: "App time", measure: true, unit: "ms",
          facet: "rails"),
        Field.new(name: "untracked", sql: remainder_sql, type: Type::Number, label: "Untracked time", measure: true, unit: "ms",
          facet: "experience")
      ]
    )

    SPANS = Source.new(
      name: "spans", label: "Spans", table: "spans",
      text_fields: %w[name resource],
      list_fields: %w[app kind name resource status duration trace span parent],
      fields: [
        Field.new(name: "app", sql: "app_id", type: Type::App, label: "App"),
        Field.new(name: "kind", sql: "kind", type: Type::Text, label: "Kind"),
        Field.new(name: "name", sql: "name", type: Type::Text, label: "Name"),
        Field.new(name: "resource", sql: "resource", type: Type::Text, label: "Resource"),
        Field.new(name: "status", sql: "status", type: Type::Text, label: "Status"),
        Field.new(name: "trace", sql: "trace_id", type: Type::Trace, label: "Trace"),
        Field.new(name: "span", sql: "span_id", type: Type::Int, label: "Span"),
        Field.new(name: "parent", sql: "parent_id", type: Type::Int, label: "Parent span"),
        Field.new(name: "duration", sql: "duration_ms", type: Type::Number, label: "Duration", measure: true, unit: "ms")
      ]
    )

    LOGS = Source.new(
      name: "logs", label: "Logs", table: "logs",
      text_fields: %w[message],
      list_fields: %w[app level message source process host release trace span],
      fields: [
        Field.new(name: "app", sql: "app_id", type: Type::App, label: "App"),
        Field.new(name: "level", sql: "level", type: Type::Text, label: "Level"),
        Field.new(name: "message", sql: "message", type: Type::Text, label: "Message"),
        Field.new(name: "source", sql: "source", type: Type::Text, label: "Source"),
        Field.new(name: "process", sql: "process", type: Type::Text, label: "Process"),
        Field.new(name: "host", sql: "host", type: Type::Text, label: "Host"),
        Field.new(name: "release", sql: "release", type: Type::Text, label: "Release"),
        Field.new(name: "trace", sql: "trace_id", type: Type::Trace, label: "Trace"),
        Field.new(name: "span", sql: "span_id", type: Type::Int, label: "Span")
      ]
    )

    # Profile samples as rows to aggregate — CPU time by endpoint over time
    # is `sum(ms) by transaction` here. The flamegraph itself is
    # Profiles::Flamegraph; this source is for everything around it.
    PROFILES = Source.new(
      name: "profiles", label: "Profile samples", table: "profile_samples", attrs: nil,
      list_fields: %w[app process host release transaction state samples ms],
      fields: [
        Field.new(name: "app", sql: "app_id", type: Type::App, label: "App"),
        Field.new(name: "process", sql: "process", type: Type::Text, label: "Process"),
        Field.new(name: "host", sql: "host", type: Type::Text, label: "Host"),
        Field.new(name: "release", sql: "release", type: Type::Text, label: "Release"),
        Field.new(name: "transaction", sql: "txn", type: Type::Text, label: "Endpoint or job"),
        Field.new(name: "state", sql: "state", type: Type::Text, label: "Thread state"),
        Field.new(name: "request", sql: "request_id", type: Type::Text, label: "Profile request"),
        Field.new(name: "ms", sql: "ms", type: Type::Number, label: "Sampled time", measure: true, unit: "ms"),
        Field.new(name: "samples", sql: "samples", type: Type::Int, label: "Samples", measure: true)
      ]
    )

    PAGE_EVENTS = Source.new(
      name: "page_events", label: "Visitor events", table: "page_events", attrs: "props",
      text_fields: %w[name path title],
      list_fields: %w[app kind visit visitor user path route title name selector href browser os device origin referrer rage lcp inp cls
                      trace],
      fields: [
        Field.new(name: "app", sql: "app_id", type: Type::App, label: "App"),
        Field.new(name: "kind", sql: "kind", type: Type::Text, label: "Kind"),
        Field.new(name: "visit", sql: "visit_id", type: Type::Text, label: "Visit"),
        Field.new(name: "visitor", sql: "visitor_id", type: Type::Text, label: "Visitor"),
        Field.new(name: "user", sql: "user_ref", type: Type::Text, label: "User"),
        Field.new(name: "path", sql: "path", type: Type::Text, label: "Path"),
        Field.new(name: "route", sql: "route", type: Type::Text, label: "Route"),
        Field.new(name: "title", sql: "title", type: Type::Text, label: "Title"),
        Field.new(name: "name", sql: "name", type: Type::Text, label: "Name"),
        Field.new(name: "selector", sql: "selector", type: Type::Text, label: "Element"),
        Field.new(name: "href", sql: "href", type: Type::Text, label: "Link"),
        Field.new(name: "referrer", sql: "referrer", type: Type::Text, label: "Referrer"),
        Field.new(name: "browser", sql: "browser", type: Type::Text, label: "Browser"),
        Field.new(name: "os", sql: "os", type: Type::Text, label: "OS"),
        Field.new(name: "device", sql: "device", type: Type::Text, label: "Device"),
        Field.new(name: "screen", sql: "screen", type: Type::Text, label: "Screen"),
        Field.new(name: "lang", sql: "lang", type: Type::Text, label: "Language"),
        Field.new(name: "origin", sql: "origin", type: Type::Text, label: "Network origin"),
        Field.new(name: "trace", sql: "trace_id", type: Type::Trace, label: "Trace"),
        Field.new(name: "rage", sql: "rage", type: Type::Bool, label: "Rage click"),
        Field.new(name: "lcp", sql: "lcp", type: Type::Number, label: "LCP", measure: true, unit: "ms"),
        Field.new(name: "inp", sql: "inp", type: Type::Number, label: "INP", measure: true, unit: "ms"),
        Field.new(name: "cls", sql: "cls", type: Type::Number, label: "CLS", measure: true),
        Field.new(name: "ttfb", sql: "ttfb", type: Type::Number, label: "TTFB", measure: true, unit: "ms"),
        Field.new(name: "fcp", sql: "fcp", type: Type::Number, label: "FCP", measure: true, unit: "ms")
      ]
    )

    VISITS = Source.new(
      name: "visits", label: "Visits", table: "visits", attrs: nil,
      text_fields: %w[entry_path exit_path],
      list_fields: %w[app visit visitor user entry_path exit_path referrer browser os device origin pageviews interactions errors duration],
      fields: [
        Field.new(name: "app", sql: "app_id", type: Type::App, label: "App"),
        Field.new(name: "visit", sql: "visit_id", type: Type::Text, label: "Visit"),
        Field.new(name: "visitor", sql: "visitor_id", type: Type::Text, label: "Visitor"),
        Field.new(name: "user", sql: "user_ref", type: Type::Text, label: "User"),
        Field.new(name: "entry_path", sql: "entry_path", type: Type::Text, label: "Entry page"),
        Field.new(name: "entry_route", sql: "entry_route", type: Type::Text, label: "Entry route"),
        Field.new(name: "exit_path", sql: "exit_path", type: Type::Text, label: "Exit page"),
        Field.new(name: "referrer", sql: "referrer", type: Type::Text, label: "Referrer"),
        Field.new(name: "browser", sql: "browser", type: Type::Text, label: "Browser"),
        Field.new(name: "os", sql: "os", type: Type::Text, label: "OS"),
        Field.new(name: "device", sql: "device", type: Type::Text, label: "Device"),
        Field.new(name: "origin", sql: "origin", type: Type::Text, label: "Network origin"),
        Field.new(name: "pageviews", sql: "pageviews", type: Type::Int, label: "Pageviews", measure: true),
        Field.new(name: "interactions", sql: "interactions", type: Type::Int, label: "Interactions", measure: true),
        Field.new(name: "errors", sql: "error_count", type: Type::Int, label: "Errors", measure: true),
        Field.new(name: "duration", sql: "extract(epoch FROM last_seen_at - ts)", type: Type::Number, label: "Duration", measure: true, unit: "s"),
        # One pageview and nothing else: the visit that left.
        Field.new(name: "bounced", sql: "(pageviews <= 1 AND interactions = 0)", type: Type::Bool, label: "Bounced")
      ]
    )

    # One call to a model: kept whole, never
    # sampled, so spend and latency are exact.
    MODEL_CALLS = Source.new(
      name: "model_calls", label: "Model calls", table: "model_calls",
      text_fields: %w[model provider error],
      list_fields: %w[app provider model served purpose origin agent session round status error stop duration ttft
                      tokens_in cache_read cache_write tokens_out reasoning cost cost_source route tools tools_valid
                      retry_of fallback_from process host release trace span],
      fields: [
        Field.new(name: "app", sql: "app_id", type: Type::App, label: "App"),
        Field.new(name: "provider", sql: "provider", type: Type::Text, label: "Provider"),
        Field.new(name: "model", sql: "model", type: Type::Text, label: "Model asked for"),
        Field.new(name: "served", sql: "served", type: Type::Text, label: "Model that answered"),
        Field.new(name: "tier", sql: "tier", type: Type::Text, label: "Tier"),
        Field.new(name: "purpose", sql: "purpose", type: Type::Text, label: "Purpose"),
        Field.new(name: "origin", sql: "origin", type: Type::Text, label: "Origin"),
        Field.new(name: "agent", sql: "agent", type: Type::Text, label: "Agent"),
        Field.new(name: "session", sql: "session", type: Type::Text, label: "Session"),
        Field.new(name: "round", sql: "round", type: Type::Int, label: "Round"),
        Field.new(name: "status", sql: "status", type: Type::Text, label: "Status"),
        Field.new(name: "error", sql: "error_class", type: Type::Text, label: "Error class"),
        Field.new(name: "stop", sql: "stop", type: Type::Text, label: "Stop reason"),
        Field.new(name: "route", sql: "route", type: Type::Text, label: "Why this model"),
        Field.new(name: "cost_source", sql: "cost_source", type: Type::Text, label: "Cost source"),
        Field.new(name: "estimated", sql: "estimated", type: Type::Bool, label: "Tokens estimated"),
        Field.new(name: "stream", sql: "stream", type: Type::Bool, label: "Streamed"),
        Field.new(name: "fallback_from", sql: "fallback_from", type: Type::Text, label: "Fell back from"),
        Field.new(name: "process", sql: "process", type: Type::Text, label: "Process"),
        Field.new(name: "host", sql: "host", type: Type::Text, label: "Host"),
        Field.new(name: "release", sql: "release", type: Type::Text, label: "Release"),
        Field.new(name: "trace", sql: "trace_id", type: Type::Trace, label: "Trace"),
        Field.new(name: "span", sql: "span_id", type: Type::Int, label: "Span"),
        Field.new(name: "retry_of", sql: "retry_of", type: Type::Int, label: "Retry of"),
        Field.new(name: "duration", sql: "duration_ms", type: Type::Number, label: "Duration", measure: true, unit: "ms"),
        Field.new(name: "ttft", sql: "ttft_ms", type: Type::Number, label: "Time to first token", measure: true, unit: "ms"),
        Field.new(name: "first_text", sql: "first_text_ms", type: Type::Number, label: "Time to first text", measure: true, unit: "ms"),
        Field.new(name: "itl_p95", sql: "itl_p95_ms", type: Type::Number, label: "Inter-token p95", measure: true, unit: "ms"),
        Field.new(name: "server_queue", sql: "queue_ms", type: Type::Number, label: "Server queue", measure: true, unit: "ms"),
        Field.new(name: "load", sql: "load_ms", type: Type::Number, label: "Model load", measure: true, unit: "ms"),
        Field.new(name: "prompt", sql: "prompt_ms", type: Type::Number, label: "Prompt evaluation", measure: true, unit: "ms"),
        Field.new(name: "decode", sql: "decode_ms", type: Type::Number, label: "Decoding", measure: true, unit: "ms"),
        Field.new(name: "concurrent", sql: "concurrent", type: Type::Int, label: "Calls in flight at start", measure: true),
        Field.new(name: "tokens_in", sql: "tokens_in", type: Type::Int, label: "Input tokens", measure: true, unit: "tokens"),
        Field.new(name: "cache_read", sql: "tokens_cache_read", type: Type::Int, label: "Cached input tokens read", measure: true,
          unit: "tokens"),
        Field.new(name: "cache_write", sql: "tokens_cache_write", type: Type::Int, label: "Cached input tokens written", measure: true,
          unit: "tokens"),
        Field.new(name: "tokens_out", sql: "tokens_out", type: Type::Int, label: "Output tokens", measure: true, unit: "tokens"),
        Field.new(name: "reasoning", sql: "tokens_reasoning", type: Type::Int, label: "Reasoning tokens", measure: true, unit: "tokens"),
        Field.new(name: "input_total", sql: "(tokens_in + tokens_cache_read + tokens_cache_write)", type: Type::Int,
          label: "Input tokens, cached or not", measure: true, unit: "tokens"),
        Field.new(name: "cost", sql: "cost_usd", type: Type::Number, label: "Cost", measure: true, unit: "usd"),
        Field.new(name: "tools", sql: "tool_calls", type: Type::Int, label: "Tool calls asked for", measure: true),
        Field.new(name: "tools_valid", sql: "tool_calls_valid", type: Type::Int, label: "Tool calls that parsed", measure: true),
        # Output speed once the model was talking: tokens over the time
        # after the first one.
        Field.new(name: "tokens_per_s",
          sql: "(tokens_out / nullif(coalesce(decode_ms, duration_ms - coalesce(ttft_ms, 0)), 0) * 1000.0)",
          type: Type::Number, label: "Output tokens per second", measure: true, unit: "per_second")
      ]
    )

    ALL = T.let([ TRANSACTIONS, SPANS, LOGS, PROFILES, PAGE_EVENTS, VISITS, MODEL_CALLS ].freeze, T::Array[Source])

    sig { params(name: String).returns(Source) }
    def self.fetch(name)
      ALL.find { |source| source.name == name } ||
        raise(Invalid, "Unknown source “#{name}” — one of #{ALL.map(&:name).join(', ')}, or metrics")
    end
  end
end
