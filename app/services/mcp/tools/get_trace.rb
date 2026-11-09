# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class GetTrace < Base
      MAX_LOGS = 100

      tool_name "get_trace"
      title "One trace, whole"
      description "Everything recorded under one trace id: the request, job or agent run (and the work it set " \
        "going, across apps) with its timing breakdown, the spans inside it — SQL, views, cache, outbound HTTP, " \
        "and for a run its model calls, tools and waits — each with its offset from the start, its duration and " \
        "its parent; the model calls made, with tokens and cost; and the log lines written during it. Trace ids come " \
        "from `query` (shape list — every transaction and log row carries `trace`). Only traces the sampler kept " \
        "(`kept:true`) have spans. A trace with more spans than `max_spans` keeps its longest ones."
      input_schema(
        properties: {
          trace_id: { type: "string", description: "The trace id: 32 hex characters." },
          max_spans: { type: "integer", description: "1–1000, default 200." }
        },
        required: %w[trace_id]
      )
      annotations(title: "One trace, whole", **READ_ONLY)

      sig { params(server_context: T.untyped, trace_id: T.untyped, max_spans: T.untyped, _extra: T.untyped).returns(MCP::Tool::Response) }
      def self.call(server_context:, trace_id:, max_spans: nil, **_extra)
        id = Traces::Lookup.normalize(trace_id)
        return failure("A trace id is 32 hex characters — #{trace_id.inspect} is not one.") if id.nil?

        answer do
          context = query_context(server_context)
          found = Traces::Lookup.call(id: id, context: context)
          raise Query::Invalid, missing(id) if found.nil?

          keep = limit_of(max_spans, default: 200, max: 1_000)
          shown = longest(found, keep)
          McpSerializer.trace_json(shown, context, logs: logs(found, context), note: note(found, keep))
        end
      end

      sig { params(id: String).returns(String) }
      def self.missing(id)
        "No trace #{id} in the last #{Traces::Lookup::LOOKBACK.in_days.to_i} days — it was never reported, or has aged out of retention."
      end
      private_class_method :missing

      # The trace with at most `keep` spans: the longest, back in time order.
      sig { params(found: Traces::Lookup::Found, keep: Integer).returns(Traces::Lookup::Found) }
      def self.longest(found, keep)
        return found if found.spans.size <= keep

        spans = found.spans.max_by(keep) { |span| span.duration_ms.to_f }.sort_by(&:ts)
        Traces::Lookup::Found.new(id: found.id, transactions: found.transactions, spans: spans, model_calls: found.model_calls,
          truncated: true)
      end
      private_class_method :longest

      sig { params(found: Traces::Lookup::Found, keep: Integer).returns(T.nilable(String)) }
      def self.note(found, keep)
        return nil if found.spans.size <= keep && !found.truncated

        total = found.truncated ? "more than #{found.spans.size}" : found.spans.size.to_s
        "This trace has #{total} spans; the #{[ keep, found.spans.size ].min} longest are shown. " \
          "Aggregate the rest with query: source spans, filter “trace:#{found.id}”, group_by [\"kind\",\"resource\"]."
      end
      private_class_method :note

      sig { params(found: Traces::Lookup::Found, context: Query::Context).returns(T::Array[T::Hash[String, T.untyped]]) }
      def self.logs(found, context)
        starts = found.transactions.map(&:ts)
        ends = found.transactions.map { |txn| txn.ts + txn.duration_ms.to_f / 1000.0 }
        rows(context, source: "logs", shape: "list", filter: "trace:#{found.id}", limit: MAX_LOGS,
          from: T.must(starts.min) - Traces::Lookup::MARGIN, to: ends.max + Traces::Lookup::MARGIN).reverse.map do |row|
          McpSerializer.list_row(row).slice("ts", "app", "level", "message", "source", "span", "attrs")
        end
      end
      private_class_method :logs
    end
  end
end
