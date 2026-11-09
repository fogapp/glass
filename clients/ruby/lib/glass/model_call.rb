# frozen_string_literal: true

require_relative "attrs"

module Glass
  # One call to a model, as the protocol's `llm` record (glass:docs/ingest-protocol.md),
  # and the `ai.*` metrics every call leaves behind however long its row is
  # kept — the same record and the same series the Node client sends
  # (clients/node/src/run.ts, emitModelCall). What was asked for, what it
  # cost and how long it took: never a prompt, a completion or a system
  # prompt — there is no field for one.
  module ModelCall
    MAX_ATTRS = 64

    # Keyword → wire field, for the optional milliseconds (non-negative, or absent).
    MS = { ttft_ms: :ttft, first_text_ms: :first_text, itl_p95_ms: :itl_p95,
           queue_ms: :queue_ms, load_ms: :load_ms, prompt_ms: :prompt_ms, decode_ms: :decode_ms }.freeze
    # Keyword → wire field, for the optional strings and scalars sent as given.
    PLAIN = { served: :served, tier: :tier, agent: :agent, session: :session, round: :round,
              concurrent: :concurrent, stream: :stream, estimated: :estimated, cost_source: :cost_src,
              stop: :stop, error: :error, retry_of: :retry_of, fallback_from: :fallback_from,
              route: :route, tools_valid: :tools_valid }.freeze
    TOKENS = { input_tokens: "input", output_tokens: "output",
               cache_read_tokens: "cache_read", cache_write_tokens: "cache_write" }.freeze

    module_function

    # The wire record, or nil when the call is missing what the protocol
    # requires (`provider`, `model`, a duration).
    def record(call, scrub: nil)
      provider = text(call[:provider])
      model = text(call[:model])
      duration = number(call[:duration_ms])
      return nil unless provider && model && duration

      rec = { t: "llm", ts: started_at(call, duration) }
      rec[:trace] = call[:trace].to_s if call[:trace]
      rec[:span] = call[:span].to_s if call[:span]
      rec.merge!(provider: provider, model: model, purpose: text(call[:purpose]) || "turn",
                 origin: text(call[:origin]) || "production", dur: duration.round(3))
      PLAIN.each do |key, field|
        value = call[key]
        next if value.nil?
        rec[field] = value.is_a?(Symbol) ? value.to_s : value
      end
      MS.each do |key, field|
        value = number(call[key])
        rec[field] = value.round(3) if value
      end
      rec.merge!(in: count(call[:input_tokens]), cache_read: count(call[:cache_read_tokens]),
                 cache_write: count(call[:cache_write_tokens]), out: count(call[:output_tokens]),
                 reasoning: count(call[:reasoning_tokens]), cost: (number(call[:cost_usd]) || 0.0).round(6),
                 status: text(call[:status]) || "ok", tools: count(call[:tools]))
      attrs = clean_attrs(call[:attrs], scrub)
      rec[:attrs] = attrs if attrs
      rec
    end

    # ai.calls, ai.cost (not for a subscription call's shadow price — that is
    # what it would have cost, not money spent), ai.tokens by kind,
    # ai.duration and ai.ttft: the series Node emits, with its tags and units.
    def metrics(aggregator, rec, call)
      at = rec[:ts].floor
      tags = { provider: rec[:provider], model: rec[:model], purpose: rec[:purpose] }
      aggregator.counter("ai.calls", 1, tags.merge(status: rec[:status]), at)
      aggregator.counter("ai.cost", rec[:cost], tags, at, unit: "usd") unless rec[:cost_src] == "shadow"
      TOKENS.each do |key, kind|
        n = count(call[key])
        aggregator.counter("ai.tokens", n, tags.merge(kind: kind), at, unit: "tokens") if n.positive?
      end
      aggregator.dist("ai.duration", rec[:dur], tags, "ms", at)
      aggregator.dist("ai.ttft", rec[:ttft], tags, "ms", at) if rec[:ttft]
    end

    def started_at(call, duration)
      case (value = call[:started_at])
      when Time then value.to_f
      when Numeric then value.to_f
      else Time.now.to_f - duration / 1000.0
      end
    end

    def text(value)
      return nil if value.nil?
      s = value.to_s
      s.empty? ? nil : s
    end

    def number(value)
      return nil unless value.is_a?(Numeric)
      f = value.to_f
      f.finite? ? [f, 0.0].max : nil
    end

    def count(value)
      value.is_a?(Numeric) && value.to_f.finite? ? [value.to_i, 0].max : 0
    end

    # String → scalar, at most MAX_ATTRS keys, nothing that names a
    # credential (the app's own filter rules, as everywhere else).
    def clean_attrs(attrs, scrub)
      return nil unless attrs.is_a?(Hash) && !attrs.empty?
      attrs = attrs.transform_keys(&:to_s)
      attrs = scrub.call(attrs) if scrub
      out = {}
      attrs.each do |key, value|
        break if out.size >= MAX_ATTRS
        next if value.nil? || (value.is_a?(Float) && !value.finite?)
        out[key] = Attrs.scalar(value)
      end
      out.empty? ? nil : out
    end
  end
end
