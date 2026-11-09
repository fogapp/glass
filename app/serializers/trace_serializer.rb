# typed: strict
# frozen_string_literal: true

# A trace as the waterfall draws it: one flat list of spans, each naming its
# parent, with a unit of work (a transaction) as the root of each app's part
# of the tree, and the model calls made under it, each naming the span it
# was.
module TraceSerializer
  extend T::Sig

  sig do
    params(found: Traces::Lookup::Found, context: Query::Context).returns(T::Hash[Symbol, T.untyped])
  end
  def self.trace_json(found, context)
    transactions = found.transactions
    spans = found.spans
    started = transactions.map { |txn| txn.ts.to_f }.min.to_f
    ended = transactions.map { |txn| txn.ts.to_f + txn.duration_ms / 1000.0 }.max.to_f
    {
      trace: found.id, started_at: started, duration_ms: (ended - started) * 1000.0, truncated: found.truncated,
      transactions: transactions.map { |txn| transaction_json(txn, context) },
      spans: spans.map { |span| span_json(span, context) },
      model_calls: found.model_calls.map { |call| model_call_json(call, context) }
    }
  end

  sig { params(txn: Telemetry::Transaction, context: Query::Context).returns(T::Hash[Symbol, T.untyped]) }
  def self.transaction_json(txn, context)
    {
      ts: txn.ts.to_f, app: context.slug(txn.app_id), kind: txn.kind, name: txn.name, process: txn.process,
      host: txn.host, release: txn.release, span: Telemetry.span_hex(txn.span_id),
      parent: (parent = txn.parent_span_id) && Telemetry.span_hex(parent),
      duration: txn.duration_ms, status: txn.status, error: txn.error_class,
      method: txn.method, route: txn.route, path: txn.path, http_status: txn.http_status, format: txn.format,
      queue: txn.queue, queue_ms: txn.queue_ms, attempt: txn.attempt,
      db: txn.db_ms, db_count: txn.db_count, view: txn.view_ms, ext: txn.ext_ms, ext_count: txn.ext_count,
      cache_hits: txn.cache_hits, cache_misses: txn.cache_misses, gc: txn.gc_ms, allocations: txn.allocations,
      n_plus_one: txn.n_plus_one, user: txn.user_ref, visit: txn.visit_id, origin: txn.origin, kept: txn.kept,
      attrs: txn.attrs
    }.merge(txn.kind == "run" ? run_json(txn) : {})
  end

  # The facets only a run carries (Telemetry::Work): left off every other
  # kind rather than sent as a row of zeros.
  sig { params(txn: Telemetry::Transaction).returns(T::Hash[Symbol, T.untyped]) }
  def self.run_json(txn)
    {
      agent: txn.agent, session: txn.session, trigger: txn.trigger, channel: txn.channel, stop: txn.stop, model: txn.model,
      rounds: txn.rounds, calls: txn.model_calls, tools: txn.tool_calls, tool_errors: txn.tool_errors,
      tokens_in: txn.tokens_in, tokens_out: txn.tokens_out, cache_read: txn.tokens_cache_read,
      cache_write: txn.tokens_cache_write, cost: txn.cost_usd,
      prep: txn.prep_ms, model_ms: txn.model_ms, tool_ms: txn.tool_ms, wait: txn.wait_ms, deliver: txn.deliver_ms,
      lag: txn.lag_ms, ttft: txn.ttft_ms, stall: txn.stall_ms
    }
  end

  sig { params(call: Telemetry::ModelCall, context: Query::Context).returns(T::Hash[Symbol, T.untyped]) }
  def self.model_call_json(call, context)
    {
      ts: call.ts.to_f, app: context.slug(call.app_id), span: (span = call.span_id) && Telemetry.span_hex(span),
      provider: call.provider, model: call.model, served: call.served, purpose: call.purpose, origin: call.origin,
      agent: call.agent, round: call.round, status: call.status, error: call.error_class, stop: call.stop, route: call.route,
      retry_of: (retried = call.retry_of) && Telemetry.span_hex(retried), fallback_from: call.fallback_from,
      duration: call.duration_ms, ttft: call.ttft_ms, first_text: call.first_text_ms,
      server_queue: call.queue_ms, load: call.load_ms, prompt: call.prompt_ms, decode: call.decode_ms,
      tokens_in: call.tokens_in, cache_read: call.tokens_cache_read, cache_write: call.tokens_cache_write,
      tokens_out: call.tokens_out, reasoning: call.tokens_reasoning, estimated: call.estimated,
      cost: call.cost_usd, cost_source: call.cost_source, tools: call.tool_calls, tools_valid: call.tool_calls_valid
    }
  end

  sig { params(span: Telemetry::Span, context: Query::Context).returns(T::Hash[Symbol, T.untyped]) }
  def self.span_json(span, context)
    {
      ts: span.ts.to_f, app: context.slug(span.app_id), span: Telemetry.span_hex(span.span_id),
      parent: (parent = span.parent_id) && Telemetry.span_hex(parent), kind: span.kind, name: span.name,
      resource: span.resource, duration: span.duration_ms, status: span.status, attrs: span.attrs
    }
  end
end
