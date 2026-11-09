# frozen_string_literal: true

require_relative "test_helper"

class ModelCallTest < Minitest::Test
  include GlassTestSupport

  def full_call
    {
      provider: "anthropic-api", model: "claude-sonnet-4-6", served: "claude-sonnet-4-6", tier: "frontier",
      purpose: "turn", origin: "production", agent: "owner-chat", session: "ses_81c4", round: 0,
      started_at: Time.at(1_790_000_121.2), duration_ms: 4180.0, ttft_ms: 612.0, first_text_ms: 1900.0, itl_p95_ms: 41.0,
      queue_ms: 0, load_ms: 0, prompt_ms: 220.0, decode_ms: 3300.0, concurrent: 1, stream: true,
      input_tokens: 1840, cache_read_tokens: 21_400, cache_write_tokens: 0, output_tokens: 512, reasoning_tokens: 96,
      estimated: false, cost_usd: 0.0193, cost_source: "estimated", stop: "tool_use", status: "ok",
      route: "agent:owner-chat", tools: 1, tools_valid: 1,
      trace: "7d3c0e1a9b8f4c62a1e5d4c3b2a19087", span: "2222222222222204", attrs: { model_version: "mv_3a" }
    }
  end

  def test_the_record_is_the_protocols_llm_record
    sender = configure_glass
    Glass.model_call(**full_call)
    Glass.flush
    rec = sender.records("llm").first
    # The protocol doc's example, field for field.
    assert_equal({
      "t" => "llm", "ts" => 1_790_000_121.2, "trace" => "7d3c0e1a9b8f4c62a1e5d4c3b2a19087", "span" => "2222222222222204",
      "provider" => "anthropic-api", "model" => "claude-sonnet-4-6", "served" => "claude-sonnet-4-6", "tier" => "frontier",
      "purpose" => "turn", "origin" => "production", "agent" => "owner-chat", "session" => "ses_81c4", "round" => 0,
      "dur" => 4180.0, "ttft" => 612.0, "first_text" => 1900.0, "itl_p95" => 41.0,
      "queue_ms" => 0.0, "load_ms" => 0.0, "prompt_ms" => 220.0, "decode_ms" => 3300.0, "concurrent" => 1, "stream" => true,
      "in" => 1840, "cache_read" => 21_400, "cache_write" => 0, "out" => 512, "reasoning" => 96, "estimated" => false,
      "cost" => 0.0193, "cost_src" => "estimated",
      "stop" => "tool_use", "status" => "ok", "route" => "agent:owner-chat", "tools" => 1, "tools_valid" => 1,
      "attrs" => { "model_version" => "mv_3a" }
    }, rec)
  end

  def test_defaults_and_absent_fields
    sender = configure_glass
    before = Time.now.to_f
    Glass.model_call(provider: "ollama", model: "qwen3:8b", duration_ms: 1000)
    Glass.flush
    rec = sender.records("llm").first
    assert_equal %w[t ts provider model purpose origin dur in cache_read cache_write out reasoning cost status tools].sort, rec.keys.sort,
                 "absent optional fields are absent, not null"
    assert_equal "turn", rec["purpose"]
    assert_equal "production", rec["origin"]
    assert_equal "ok", rec["status"]
    assert_in_delta before - 1.0, rec["ts"], 0.5, "started_at defaults to now minus the duration"
  end

  def test_a_call_without_what_the_protocol_requires_is_not_sent
    sender = configure_glass
    Glass.model_call(provider: "x", model: "y")
    Glass.model_call(model: "y", duration_ms: 3)
    Glass.model_call(provider: "x", model: "y", duration_ms: Float::NAN)
    Glass.flush
    assert_empty sender.records("llm")
  end

  def test_unknown_keywords_and_bad_values_never_raise_into_the_app
    sender = configure_glass
    assert_nil Glass.model_call(provider: "x", model: "y", duration_ms: 5, prompt: "secret words", completion: "no", cost_usd: "lots",
                                attrs: { api_key: "k", n: Float::INFINITY, nested: { a: 1 } })
    Glass.flush
    rec = sender.records("llm").first
    refute_includes JSON.generate(rec), "secret words", "there is nowhere for a prompt to go"
    assert_equal 0.0, rec["cost"]
    assert_equal({ "api_key" => "[FILTERED]", "nested" => '{"a":1}' }, rec["attrs"])
  end

  def test_inside_a_transaction_the_call_joins_its_trace
    sender = configure_glass
    txn = Glass::Transaction.new("job", "Summarise")
    Thread.current[Glass::Tracer::KEY] = txn
    Glass.model_call(provider: "x", model: "y", duration_ms: 5)
    Glass.model_call(provider: "x", model: "y", duration_ms: 5, trace: "f" * 32)
    Glass.flush
    assert_equal [txn.trace_id, "f" * 32], sender.records("llm").map { |r| r["trace"] }
  ensure
    Thread.current[Glass::Tracer::KEY] = nil
  end

  def test_metrics_match_the_node_client
    sender = configure_glass
    Glass.model_call(**full_call, started_at: Time.now - 120)
    Glass.model_call(**full_call, started_at: Time.now - 120, cost_source: "shadow", cost_usd: 9.0, ttft_ms: nil)
    Glass.flush
    metrics = sender.records("metric")
    by_name = metrics.group_by { |m| m["name"] }
    assert_equal %w[ai.calls ai.cost ai.duration ai.tokens ai.ttft], by_name.keys.sort
    calls = by_name["ai.calls"].first
    assert_equal({ "provider" => "anthropic-api", "model" => "claude-sonnet-4-6", "purpose" => "turn", "status" => "ok" }, calls["tags"])
    assert_in_delta 0.0193, by_name["ai.cost"].sum { |m| m["sum"] }, 1e-9, "a shadow price is not money spent"
    assert_equal "usd", by_name["ai.cost"].first["unit"]
    tokens = by_name["ai.tokens"].to_h { |m| [m["tags"]["kind"], m["sum"]] }
    assert_equal({ "input" => 3680.0, "output" => 1024.0, "cache_read" => 42_800.0 }, tokens, "a zero count is no series")
    assert_equal "tokens", by_name["ai.tokens"].first["unit"]
    assert_equal "ms", by_name["ai.duration"].first["unit"]
    assert_equal 1, by_name["ai.ttft"].first["n"]
  end

  def test_inert_without_configuration
    Glass.reset!
    assert_nil Glass.model_call(provider: "x", model: "y", duration_ms: 5)
    assert_nil Glass.instance_variable_get(:@transport), "no thread, no buffers"
  end

  def test_buffer_is_bounded_and_drops_are_counted
    configure_glass(queue_size: 2)
    t = Glass.transport
    gate = Queue.new
    t.instance_variable_set(:@sender, ->(_b) { gate.pop; Glass::Transport::Response.new(202, "{}", nil) })
    6.times { Glass.model_call(provider: "x", model: "y", duration_ms: 5) }
    assert_equal 2, t.dropped[:llm]
  ensure
    gate&.close
  end
end
