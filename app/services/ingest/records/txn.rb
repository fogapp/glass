# typed: strict
# frozen_string_literal: true

module Ingest
  module Records
    # A `txn` record → a `transactions` row (docs/ingest-protocol.md).
    #
    # The row is a spine and facets (Telemetry::Work). The spine is built
    # here; each facet has a builder of its own under Txn::, and a record's
    # kind says which of them read it. A facet the kind does not carry is
    # built from nothing, so every row has every column and a run can never
    # end up with an HTTP status.
    module Txn
      extend T::Sig

      Columns = T.type_alias { T::Hash[Symbol, T.untyped] }

      sig { params(record: Record, context: Context).returns(T.nilable(Columns)) }
      def self.build(record, context)
        kind = record["kind"]
        name = Coerce.str(record["name"], max: 200)
        trace = Coerce.trace_id(record["trace"])
        span = Coerce.span_id(record["span"])
        duration = Coerce.ms(record["dur"])
        return nil unless Telemetry::Work.valid_name?(kind) && name && trace && span && duration

        weight = Coerce.float(record["weight"])
        carried = Telemetry::Work.kind(kind).facets
        spine = {
          **context.provenance(record), kind: kind, name: name,
          trace_id: trace, span_id: span, parent_span_id: Coerce.span_id(record["parent"]),
          duration_ms: duration, status: Coerce.status(record["status"]),
          error_class: Coerce.str(record["error"], max: 200), user_ref: Coerce.str(record["user"], max: 120),
          kept: Coerce.bool(record["kept"]), weight: weight && weight >= 1 ? weight : 1.0,
          attrs: Coerce.attrs(record["attrs"])
        }
        FACETS.each { |facet, builder| spine.merge!(builder.columns(carried.include?(facet) ? record : NOTHING)) }
        spine
      end

      NOTHING = T.let({}.freeze, T::Hash[String, T.untyped])

      # The HTTP side of a request, and the browser visit it belonged to.
      module Http
        extend T::Sig

        sig { params(record: T::Hash[String, T.untyped]).returns(Columns) }
        def self.columns(record)
          origin = record["origin"]
          {
            method: Coerce.str(record["method"], max: 10), route: Coerce.str(record["route"], max: 500),
            path: Coerce.str(record["path"], max: 2_000), http_status: Coerce.int(record["http"], max: 999),
            format: Coerce.str(record["format"], max: 40), visit_id: Coerce.str(record["visit"], max: 64),
            origin: Coerce.one_of(origin, Telemetry::ORIGINS, nil)
          }
        end
      end

      # Work that waited its turn.
      module Queue
        extend T::Sig

        sig { params(record: T::Hash[String, T.untyped]).returns(Columns) }
        def self.columns(record)
          { queue: Coerce.str(record["queue"], max: 80), queue_ms: Coerce.ms(record["queue_ms"]),
            attempt: Coerce.int(record["attempt"], max: 32_767) }
        end
      end

      # Where a Rails process's time went, summed in the agent.
      module RailsTime
        extend T::Sig

        sig { params(record: T::Hash[String, T.untyped]).returns(Columns) }
        def self.columns(record)
          {
            db_ms: Coerce.ms(record["db_ms"]) || 0.0, db_count: Coerce.int(record["db_n"]) || 0,
            view_ms: Coerce.ms(record["view_ms"]) || 0.0,
            cache_hits: Coerce.int(record["cache_hit"]) || 0, cache_misses: Coerce.int(record["cache_miss"]) || 0,
            gc_ms: Coerce.ms(record["gc_ms"]) || 0.0, allocations: Coerce.int(record["alloc"], max: Batch::MAX_COUNT),
            n_plus_one: Coerce.bool(record["n1"])
          }
        end
      end

      # Calls out to other services.
      module Outbound
        extend T::Sig

        sig { params(record: T::Hash[String, T.untyped]).returns(Columns) }
        def self.columns(record)
          { ext_ms: Coerce.ms(record["ext_ms"]) || 0.0, ext_count: Coerce.int(record["ext_n"]) || 0 }
        end
      end

      # An agent's run: who ran, in which conversation, and what it spent.
      module Ai
        extend T::Sig

        sig { params(record: T::Hash[String, T.untyped]).returns(Columns) }
        def self.columns(record)
          {
            agent: Coerce.str(record["agent"], max: 120), session: Coerce.str(record["session"], max: 120),
            trigger: Coerce.str(record["trigger"], max: 40), channel: Coerce.str(record["channel"], max: 40),
            stop: Coerce.str(record["stop"], max: 40), model: Coerce.str(record["model"], max: 200),
            rounds: Coerce.int(record["rounds"]) || 0, model_calls: Coerce.int(record["calls"]) || 0,
            tool_calls: Coerce.int(record["tools_n"]) || 0, tool_errors: Coerce.int(record["tool_err"]) || 0,
            tokens_in: Coerce.int(record["tok_in"]) || 0, tokens_out: Coerce.int(record["tok_out"]) || 0,
            tokens_cache_read: Coerce.int(record["tok_cache_read"]) || 0,
            tokens_cache_write: Coerce.int(record["tok_cache_write"]) || 0,
            cost_usd: Coerce.cost(record["cost"]) || 0.0
          }
        end
      end

      # Where the time between asking and being answered went, and what
      # the person waiting saw of it.
      module Experience
        extend T::Sig

        sig { params(record: T::Hash[String, T.untyped]).returns(Columns) }
        def self.columns(record)
          {
            prep_ms: Coerce.ms(record["prep_ms"]) || 0.0, model_ms: Coerce.ms(record["model_ms"]) || 0.0,
            tool_ms: Coerce.ms(record["tool_ms"]) || 0.0, wait_ms: Coerce.ms(record["wait_ms"]) || 0.0,
            deliver_ms: Coerce.ms(record["deliver_ms"]) || 0.0, lag_ms: Coerce.ms(record["lag_ms"]),
            ttft_ms: Coerce.ms(record["ttft_ms"]), stall_ms: Coerce.ms(record["stall_ms"])
          }
        end
      end

      # One builder per facet, named as Telemetry::Work names them.
      FACETS = T.let({
        "http" => Http, "queue" => Queue, "rails" => RailsTime, "outbound" => Outbound, "ai" => Ai, "experience" => Experience
      }.freeze, T::Hash[String, T.untyped])
    end
  end
end
