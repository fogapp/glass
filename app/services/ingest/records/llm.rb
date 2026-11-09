# typed: strict
# frozen_string_literal: true

module Ingest
  module Records
    # An `llm` record → a `model_calls` row: one call to a model
    # (docs/ingest-protocol.md). Never any text — not the prompt, not the
    # answer: what was asked for, what it cost and how long it took.
    module Llm
      extend T::Sig

      ORIGINS = T.let(%w[production internal eval].freeze, T::Array[String])
      COST_SOURCES = T.let(%w[reported estimated shadow free].freeze, T::Array[String])

      sig { params(record: Record, context: Context).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
      def self.build(record, context)
        provider = Coerce.str(record["provider"], max: 80)
        model = Coerce.str(record["model"], max: 200)
        duration = Coerce.ms(record["dur"])
        return nil unless provider && model && duration

        origin = record["origin"]
        cost_source = record["cost_src"]
        {
          **context.provenance(record),
          trace_id: Coerce.trace_id(record["trace"]), span_id: Coerce.span_id(record["span"]),
          provider: provider, model: model, served: Coerce.str(record["served"], max: 200),
          tier: Coerce.str(record["tier"], max: 40), purpose: Coerce.str(record["purpose"], max: 40) || "turn",
          origin: Coerce.one_of(origin, ORIGINS, "production"),
          agent: Coerce.str(record["agent"], max: 120), session: Coerce.str(record["session"], max: 120),
          round: Coerce.int(record["round"], max: 32_767),
          status: Coerce.status(record["status"]), error_class: Coerce.str(record["error"], max: 200),
          stop: Coerce.str(record["stop"], max: 40), route: Coerce.str(record["route"], max: 200),
          retry_of: Coerce.span_id(record["retry_of"]), fallback_from: Coerce.str(record["fallback_from"], max: 80),
          stream: Coerce.bool(record["stream"]),
          duration_ms: duration, ttft_ms: Coerce.ms(record["ttft"]), first_text_ms: Coerce.ms(record["first_text"]),
          itl_p95_ms: Coerce.ms(record["itl_p95"]),
          queue_ms: Coerce.ms(record["queue_ms"]), load_ms: Coerce.ms(record["load_ms"]),
          prompt_ms: Coerce.ms(record["prompt_ms"]), decode_ms: Coerce.ms(record["decode_ms"]),
          concurrent: Coerce.int(record["concurrent"], max: 32_767),
          tokens_in: Coerce.int(record["in"]) || 0, tokens_cache_read: Coerce.int(record["cache_read"]) || 0,
          tokens_cache_write: Coerce.int(record["cache_write"]) || 0, tokens_out: Coerce.int(record["out"]) || 0,
          tokens_reasoning: Coerce.int(record["reasoning"]) || 0, estimated: Coerce.bool(record["estimated"]),
          cost_usd: Coerce.cost(record["cost"]) || 0.0, cost_source: Coerce.one_of(cost_source, COST_SOURCES, nil),
          tool_calls: Coerce.int(record["tools"]) || 0, tool_calls_valid: Coerce.int(record["tools_valid"]),
          attrs: Coerce.attrs(record["attrs"])
        }
      end
    end
  end
end
