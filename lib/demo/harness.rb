# typed: false
# frozen_string_literal: true

module Demo
  # A pretend agent harness for the pretend fleet:
  # one Node gateway that takes messages from a few channels, runs agents
  # over a local and a frontier model, calls tools, and reports every
  # interaction as a `run` with its spans and its model calls.
  #
  # Three stories are written in, as in Demo::Fleet, because a page that has
  # only ever shown a healthy harness cannot be judged:
  #
  #   - prompt caching stopped working: for twenty-two hours between two
  #     releases every frontier call paid full price for its whole context.
  #     Spend per turn tripled and nothing else changed.
  #   - a cold container: the first shell of a conversation starts its
  #     sandbox, four seconds or so that the tool span would otherwise hide.
  #   - an approval nobody answered: three hours ago a turn sat ten minutes
  #     waiting on a person, timed out, and answered that it could not. Its
  #     active time is ordinary; all of the ten minutes is `wait`.
  #
  # And one thing only Glass can draw: a tool call into hook is the same
  # trace as hook's request and its SQL.
  module Harness
    Spec = Struct.new(:slug, :name, keyword_init: true)
    SPEC = Spec.new(slug: "aio", name: "Aio").freeze
    PROCESS = "gateway"

    Model = Struct.new(:provider, :name, :tier, :input, :output, :cache_read, :cache_write, :ttft, :tokens_per_s, keyword_init: true)
    FRONTIER = Model.new(provider: "anthropic-api", name: "claude-sonnet-4-6", tier: "frontier", input: 3.0e-6, output: 15.0e-6,
      cache_read: 0.3e-6, cache_write: 3.75e-6, ttft: 620, tokens_per_s: 72).freeze
    LOCAL = Model.new(provider: "local", name: "qwen3:8b", tier: "local", input: 0, output: 0, cache_read: 0, cache_write: 0,
      ttft: 340, tokens_per_s: 31).freeze

    # name, lane, median ms, error rate, share, asks a person, reviewed
    Tool = Struct.new(:name, :median, :error_rate, :share, :asks, :reviewed, :sandbox, :calls, keyword_init: true)
    TOOLS = [
      Tool.new(name: "shell", median: 900, error_rate: 0.05, share: 0.2, asks: 0.14, reviewed: true, sandbox: true),
      Tool.new(name: "read_file", median: 40, error_rate: 0.02, share: 0.14, asks: 0, reviewed: false, sandbox: true),
      Tool.new(name: "web_fetch", median: 700, error_rate: 0.06, share: 0.12, asks: 0.05, reviewed: true),
      Tool.new(name: "recall", median: 160, error_rate: 0.0, share: 0.14, asks: 0, reviewed: false),
      Tool.new(name: "mcp_hook_search", median: 260, error_rate: 0.03, share: 0.12, asks: 0, reviewed: false, calls: "hook"),
      Tool.new(name: "mcp_fog_apps_list", median: 120, error_rate: 0.01, share: 0.08, asks: 0, reviewed: false),
      Tool.new(name: "mac_calendar_events", median: 380, error_rate: 0.04, share: 0.1, asks: 0, reviewed: false),
      Tool.new(name: "schedule", median: 60, error_rate: 0.01, share: 0.05, asks: 0.3, reviewed: true),
      Tool.new(name: "write_document", median: 90, error_rate: 0.0, share: 0.05, asks: 0, reviewed: true)
    ].freeze

    AGENTS = { "owner-chat" => 0.72, "researcher" => 0.18, "home-ops" => 0.1 }.freeze
    CHANNELS = { "telegram" => 0.55, "console" => 0.3, "voice" => 0.1, "slack" => 0.05 }.freeze
    # What reaching the person costs, by where they are: ms, spread.
    DELIVERY = { "telegram" => [ 340, 0.4 ], "console" => [ 4, 0.3 ], "voice" => [ 1900, 0.3 ], "slack" => [ 290, 0.4 ] }.freeze
    CALL_ERRORS = %w[overloaded overloaded rate_limit timeout].freeze

    def write_harness(household)
      say "#{SPEC.name}…"
      app = ensure_app(household, SPEC)
      hook = App.unscoped.find_by(household_id: household.id, slug: "hook")
      @cache_break = @now - 30 * 3600
      @cache_fix = @now - 8 * 3600
      @stall_at = @now - 3 * 3600
      @harness_series = Hash.new { |hash, key| hash[key] = {} }
      releases = harness_releases

      write_harness_markers(app, releases)
      write_harness_runs(app, hook, releases)
      write_harness_metrics(app)
      write_harness_process(app, releases)
    end

    private

    def harness_releases
      rng = Random.new(SPEC.slug.sum)
      times = [ @from - 86_400 ]
      cursor = @from + rng.rand(8..30) * 3600
      while cursor < @cache_break - 8 * 3600
        times << cursor
        cursor += rng.rand(20..60) * 3600
      end
      (times + [ @cache_break, @cache_fix ]).sort.map { |time| [ time, Digest::SHA1.hexdigest("#{SPEC.slug}#{time.to_i}")[0, 40] ] }
    end

    def write_harness_markers(app, releases)
      batch = batch_for(app, SPEC, PROCESS, nil)
      releases.drop(1).each do |time, sha|
        batch.add_record("t" => "marker", "ts" => time.to_f, "kind" => "deploy", "title" => "Rebuilt #{sha[0, 12]}",
          "attrs" => { "release" => sha })
      end
      batch.add_record("t" => "marker", "ts" => (@now - 3 * 86_400 + 1800).to_f, "kind" => "event",
        "title" => "Model version changed: #{LOCAL.name}", "attrs" => { "model" => LOCAL.name, "provider" => LOCAL.provider })
      batch.markers.each { |row| row[:release] = row[:attrs]["release"] }
      flush(app, batch)
    end

    # ---- runs ------------------------------------------------------------

    def write_harness_runs(app, hook, releases)
      deployed = ->(time) { release_at(releases, time) }
      @warm_sessions = {}
      batches = Hash.new { |hash, release| hash[release] = batch_for(app, SPEC, PROCESS, release) }
      hook_batch = hook && batch_for(hook, Fleet::HOOK, "web", nil)
      stalled = false

      minute = Time.at(@from.to_i - @from.to_i % 60).utc
      while minute < @now
        level = activity(minute)
        starts = Array.new(poisson(0.085 * level)) { [ minute + @rng.rand * 60, :message ] }
        starts << [ minute + @rng.rand * 60, :cron ] if (minute.to_i / 60) % 240 == 7
        starts << [ minute + @rng.rand * 60, :task ] if @rng.rand < 0.0022
        if !stalled && minute >= @stall_at
          starts << [ minute, :stall ]
          stalled = true
        end
        starts.each do |at, why|
          next if at >= @now

          records, hook_records = interaction(at, why)
          batch = batches[deployed.call(at)]
          records.each { |record| batch.add_record(record) }
          hook_records.each { |record| hook_batch&.add_record(record) }
        end
        minute += 60
      end
      batches.each_value { |batch| flush(app, batch) }
      flush(hook, hook_batch) if hook_batch
    end

    # One thing asked of the harness: the run, its spans, its model calls,
    # what it left behind — and, when a tool reached into hook, hook's side.
    def interaction(at, why)
      trigger = { message: "message", stall: "message", cron: "cron", task: "task" }.fetch(why)
      agent = case why
      when :cron then "home-ops"
      when :task then "researcher"
      else weighted(AGENTS.keys) { |name| AGENTS[name] }
      end
      channel = %i[message stall].include?(why) ? weighted(CHANNELS.keys) { |name| CHANNELS[name] } : nil
      channel = "telegram" if why == :stall
      session = "ses_#{Digest::MD5.hexdigest("#{agent}#{channel}#{at.to_i / 14_400}")[0, 10]}"
      session = "ses_#{hex(5)}" if channel.nil?
      trace = hex(16)
      root = hex(8)
      local_first = why != :stall && @rng.rand < (agent == "home-ops" ? 0.8 : 0.3)
      model = local_first ? LOCAL : FRONTIER

      records = []
      hook_records = []
      spans = []
      calls = []
      clock = @rng.rand(4.0..28.0) # ingress: identity, session lookup
      phase = Hash.new(0.0)
      totals = Hash.new(0)
      cost = 0.0
      ext_ms = 0.0
      ext_n = 0
      tool_n = 0
      tool_err = 0
      quiet = [] # stretches in which the person saw nothing; waiting on the person is their doing, and is not one
      first_text = nil
      status = "ok"
      stop = "ok"
      error = nil

      add_span = lambda do |kind, name, start, duration, parent: root, res: nil, state: "ok", attrs: {}|
        id = hex(8)
        spans << { "t" => "span", "ts" => at.to_f + start / 1000.0, "trace" => trace, "span" => id, "parent" => parent, "kind" => kind,
                   "name" => name, "res" => res, "dur" => duration.round(3), "status" => state, "attrs" => attrs }.compact
        id
      end

      # Waiting for the conversation: usually nothing, sometimes the turn
      # before it or a compaction holding the lock.
      if @rng.rand < 0.08
        waited = lognormal(900, 0.8)
        add_span.call("queue", "session", clock, waited, attrs: { "behind" => @rng.rand < 0.5 ? "compaction" : "run" })
        phase[:queue] += waited
        clock += waited
      end

      memory = lognormal(170, 0.5)
      add_span.call("memory", "contribute", clock, memory, attrs: { "hits" => @rng.rand(0..8), "retrieved" => @rng.rand < 0.8 })
      clock += memory
      assemble = @rng.rand(18.0..60.0)
      context_tokens = (9_000 + lognormal(6_000, 0.6)).round
      add_span.call("context", "assemble", clock, assemble, attrs: { "totalTokens" => context_tokens, "droppedMessages" => 0 })
      clock += assemble
      phase[:prep] = memory + assemble

      rounds = why == :stall ? 2 : 1 + [ 0, 0, 1, 1, 1, 2, 2, 3, 4 ].sample(random: @rng)
      rounds += @rng.rand(1..3) if why == :task
      started_quiet = 0.0

      rounds.times do |round|
        final = round == rounds - 1
        call = model_call(at, clock, trace, model: model, agent: agent, session: session, round: round, purpose: "turn",
          context_tokens: context_tokens, final: final, first_round: round.zero?)
        # A provider having a bad moment: the call fails, and is tried again.
        if model == FRONTIER && @rng.rand < 0.018
          failed = call.merge("status" => "error", "error" => CALL_ERRORS.sample(random: @rng), "dur" => @rng.rand(300.0..1400.0).round(1),
            "out" => 0, "cost" => 0, "stop" => nil, "ttft" => nil, "first_text" => nil, "tools" => 0, "tools_valid" => nil).compact
          failed_span = add_span.call("model", model.provider, clock, failed["dur"], res: model.name, state: "error", attrs: { "round" => round })
          failed["span"] = failed_span
          calls << failed
          records << harness_log(at, clock, trace, root, "warn", "model call failed (#{failed['error']}); retrying")
          phase[:model] += failed["dur"]
          ext_ms += failed["dur"]
          ext_n += 1
          clock += failed["dur"] + 1_000
          call = call.merge("ts" => at.to_f + clock / 1000.0, "retry_of" => failed_span)
        end
        duration = call["dur"]
        call["span"] = add_span.call("model", model.provider, clock, duration, res: model.name, attrs: { "round" => round })
        calls << call
        phase[:model] += duration
        ext_ms += duration
        ext_n += 1
        cost += call["cost"]
        %w[in out cache_read cache_write].each { |key| totals[key] += call[key].to_i }
        if final
          first_text = clock + call["ttft"]
          quiet << (clock + call["ttft"] - started_quiet)
        end
        clock += duration
        break if final

        context_tokens += call["out"]
        (why == :stall ? 1 : @rng.rand(1..2)).times do
          tool = why == :stall ? TOOLS.first : weighted(TOOLS, &:share)
          result = tool_call(at, clock, trace, root, tool, agent: agent, session: session, stall: why == :stall, add_span: add_span)
          tool_n += 1
          tool_err += 1 if result[:error]
          phase[:tool] += result[:tool_ms]
          phase[:wait] += result[:wait_ms]
          ext_ms += result[:ext_ms]
          ext_n += result[:ext_n]
          calls.concat(result[:calls])
          records.concat(result[:logs])
          hook_records.concat(result[:hook])
          clock += result[:duration]
          context_tokens += @rng.rand(400..3_000)
          call["tools"] = call["tools"].to_i + 1
          call["tools_valid"] = call["tools"]
        end
        started_quiet = clock
      end

      if why == :task && @rng.rand < 0.12
        status = "error"
        stop = "rounds"
        error = "NoAnswer"
      end

      if channel
        median, sigma = DELIVERY.fetch(channel)
        deliver = lognormal(median, sigma)
        add_span.call("channel", "deliver", clock + 6, deliver, res: channel, attrs: { "attempts" => 1 })
        phase[:deliver] = deliver
        ext_ms += deliver if channel != "console"
        ext_n += 1 if channel != "console"
        # A channel that does not stream shows the answer when it lands.
        first_text = clock + 6 + deliver unless channel == "console"
        clock += 6 + deliver
      end
      duration = clock + @rng.rand(6.0..30.0) # commit

      records << {
        "t" => "txn", "ts" => at.to_f, "kind" => "run", "name" => agent, "trace" => trace, "span" => root, "dur" => duration.round(3),
        "status" => status, "error" => error, "agent" => agent, "session" => session, "trigger" => trigger, "channel" => channel,
        "stop" => stop, "model" => model.name, "rounds" => rounds, "calls" => calls.size, "tools_n" => tool_n, "tool_err" => tool_err,
        "tok_in" => totals["in"], "tok_out" => totals["out"], "tok_cache_read" => totals["cache_read"],
        "tok_cache_write" => totals["cache_write"], "cost" => cost.round(6),
        "queue_ms" => phase[:queue].round(3), "prep_ms" => phase[:prep].round(3), "model_ms" => phase[:model].round(3),
        "tool_ms" => phase[:tool].round(3), "wait_ms" => phase[:wait].round(3), "deliver_ms" => phase[:deliver].round(3),
        "ext_ms" => ext_ms.round(3), "ext_n" => ext_n,
        "lag_ms" => why == :task ? lognormal(18_000, 0.9).round(1) : (channel == "telegram" ? @rng.rand(200.0..1_400.0).round(1) : nil),
        "ttft_ms" => first_text&.round(3), "stall_ms" => quiet.max&.round(3),
        "user" => channel ? Generator::USERS.first : nil, "kept" => true, "attrs" => { "run" => "run_#{hex(6)}" }
      }.compact
      records.concat(spans)
      calls.each do |call|
        records << call
        harness_count(call)
      end

      # What the turn left behind: now and then the conversation is
      # compacted, by the local model, holding the session while it works.
      if trigger == "message" && @rng.rand < 0.08
        records.concat(compaction(at, duration + 40, trace, root, agent, session))
      end
      [ records, hook_records ]
    end

    def model_call(at, offset, trace, model:, agent:, session:, round:, purpose:, context_tokens:, final:, first_round: false, origin: "production")
      time = at + offset / 1000.0
      out = lognormal(final ? 420 : 180, 0.6).round.clamp(8, 8_000)
      ttft = lognormal(model.ttft, 0.4)
      load = model == LOCAL && @rng.rand < 0.06 ? lognormal(5_200, 0.3) : 0.0
      decode = out / model.tokens_per_s.to_f * 1000.0
      cached = model == FRONTIER && !(time >= @cache_break && time < @cache_fix)
      read = cached ? (context_tokens * (first_round ? 0.8 : 0.93)).round : 0
      write = cached ? (context_tokens * (first_round ? 0.12 : 0.05)).round : 0
      fresh = context_tokens - read - write
      cost = fresh * model.input + read * model.cache_read + write * model.cache_write + out * model.output
      {
        "t" => "llm", "ts" => time.to_f, "trace" => trace, "provider" => model.provider, "model" => model.name, "served" => model.name,
        "tier" => model.tier, "purpose" => purpose, "origin" => origin, "agent" => agent, "session" => session, "round" => round,
        "dur" => (load + ttft + decode).round(1), "ttft" => (load + ttft).round(1), "first_text" => (load + ttft).round(1),
        "itl_p95" => (1000.0 / model.tokens_per_s * 2.6).round(1), "concurrent" => @rng.rand < 0.85 ? 0 : 1, "stream" => true,
        "queue_ms" => model == LOCAL ? 0 : nil, "load_ms" => model == LOCAL ? load.round(1) : nil,
        "prompt_ms" => model == LOCAL ? (ttft * 0.8).round(1) : nil, "decode_ms" => model == LOCAL ? decode.round(1) : nil,
        "in" => fresh, "cache_read" => read, "cache_write" => write, "out" => out, "reasoning" => model == FRONTIER ? (out * 0.15).round : 0,
        "estimated" => false, "cost" => cost.round(6), "cost_src" => model == LOCAL ? "free" : "estimated",
        "stop" => final ? "end_turn" : "tool_use", "status" => "ok", "route" => model == LOCAL ? "default-local" : "agent:#{agent}",
        "tools" => 0
      }.compact
    end

    # One tool call: the gate (a reviewer, sometimes a person), the sandbox
    # when it needs one, the work. Phases are exclusive — the wait on a
    # person is not tool time.
    def tool_call(at, offset, trace, root, tool, agent:, session:, stall:, add_span:)
      calls = []
      logs = []
      hook = []
      inner = 0.0
      wait_ms = 0.0
      ext_ms = 0.0
      ext_n = 0
      children = []
      failed = @rng.rand < tool.error_rate
      note = nil

      if tool.reviewed
        review = model_call(at, offset + inner + 2, trace, model: LOCAL, agent: agent, session: session, round: nil, purpose: "reviewer",
          context_tokens: @rng.rand(600..1_400), final: true, origin: "internal").merge("out" => @rng.rand(12..40), "span" => hex(8))
        review["dur"] = (review["ttft"] + review["out"] / LOCAL.tokens_per_s.to_f * 1000).round(1)
        calls << review
        children << [ "model", "reviewer", inner + 2, review["dur"], LOCAL.name, {}, review["span"] ]
        inner += review["dur"] + 4
        ext_ms += review["dur"]
        ext_n += 1
      end
      if stall || @rng.rand < tool.asks
        wait_ms = stall ? 600_000.0 : [ lognormal(14_000, 0.9), 590_000 ].min
        answer = stall ? "expired" : (@rng.rand < 0.9 ? "approved" : "denied")
        children << [ "wait", "approval", inner, wait_ms, nil, { "status" => answer, "tool" => tool.name } ]
        inner += wait_ms
        if answer != "approved"
          failed = true
          note = answer == "expired" ? "approval expired after 600s: #{tool.name}" : "approval denied: #{tool.name}"
          logs << harness_log(at, offset + inner, trace, root, "warn", "[approvals] #{note}")
        end
      end
      unless note
        if tool.sandbox && !@warm_sessions[session]
          @warm_sessions[session] = true
          cold = lognormal(4_200, 0.3)
          children << [ "sandbox", "start", inner, cold, nil, { "cold" => true, "backend" => "docker" } ]
          inner += cold
        end
        work = lognormal(tool.median, 0.6)
        if tool.calls == "hook"
          children << [ "http", "POST hook", inner, work, "POST app.example.net/mcp", {} ]
          ext_ms += work
          ext_n += 1
        end
        inner += work
      end

      span = add_span.call("tool", tool.name, offset, inner, state: failed ? "error" : "ok",
        attrs: { "lane" => tool.name.start_with?("mac_") ? "mac" : (tool.name.start_with?("mcp_") ? "mcp" : "core"),
                 "schemaFailure" => failed && note.nil? && @rng.rand < 0.4 }.compact)
      children.each do |kind, name, start, duration, res, attrs, id|
        child = add_span.call(kind, name, offset + start, duration, parent: span, res: res, attrs: attrs)
        hook.concat(hook_request(at, offset + start, trace, child, duration)) if kind == "http"
        calls.each { |call| call["span"] = child if call["span"] == id }
      end
      { duration: inner + 3, tool_ms: inner - wait_ms, wait_ms: wait_ms, ext_ms: ext_ms, ext_n: ext_n, error: failed, calls: calls,
        logs: logs, hook: hook }
    end

    # hook's side of a tool call into it: the same trace, continued from the
    # tool's outbound span.
    def hook_request(at, offset, trace, parent, duration)
      span = hex(8)
      mine = duration * 0.86
      db = mine * 0.4
      start = at.to_f + (offset + duration * 0.07) / 1000.0
      txn = { "t" => "txn", "ts" => start, "kind" => "request", "name" => "McpController#handle", "trace" => trace, "span" => span,
              "parent" => parent, "dur" => mine.round(3), "status" => "ok", "method" => "POST", "route" => "/mcp", "path" => "/mcp",
              "http" => 200, "format" => "json", "db_ms" => db.round(3), "db_n" => 3, "origin" => "lan", "kept" => true, "attrs" => {} }
      sql = Array.new(3) do |index|
        { "t" => "span", "ts" => start + (mine * 0.1 + index * db / 3) / 1000.0, "trace" => trace, "span" => hex(8), "parent" => span,
          "kind" => "sql", "name" => "Want Load", "res" => 'SELECT "wants".* FROM "wants" WHERE "wants"."title" ILIKE ? LIMIT ?',
          "dur" => (db / 3).round(3), "status" => "ok", "attrs" => {} }
      end
      [ txn ] + sql
    end

    def compaction(at, offset, trace, root, agent, session)
      span = hex(8)
      call = model_call(at, offset + 30, trace, model: LOCAL, agent: agent, session: session, round: nil, purpose: "compaction",
        context_tokens: @rng.rand(18_000..40_000), final: true, origin: "internal")
      call_span = hex(8)
      call["span"] = call_span
      harness_count(call)
      [
        { "t" => "txn", "ts" => at.to_f + offset / 1000.0, "kind" => "run", "name" => "compaction", "trace" => trace, "span" => span,
          "parent" => root, "dur" => (call["dur"] + 80).round(3), "status" => "ok", "agent" => agent, "session" => session,
          "trigger" => "compaction", "stop" => "ok", "model" => LOCAL.name, "calls" => 1, "tok_in" => call["in"], "tok_out" => call["out"],
          "cost" => 0, "model_ms" => call["dur"], "prep_ms" => 60.0, "ext_ms" => call["dur"], "ext_n" => 1, "kept" => true,
          "attrs" => { "archivedMessages" => @rng.rand(20..90) } },
        { "t" => "span", "ts" => at.to_f + (offset + 30) / 1000.0, "trace" => trace, "span" => call_span, "parent" => span, "kind" => "model",
          "name" => LOCAL.provider, "res" => LOCAL.name, "dur" => call["dur"], "status" => "ok", "attrs" => {} },
        call
      ]
    end

    def harness_log(at, offset, trace, span, level, message)
      { "t" => "log", "ts" => at.to_f + offset / 1000.0, "lvl" => level, "msg" => message, "src" => "gateway", "trace" => trace,
        "span" => span, "attrs" => {} }
    end

    # ---- metrics ---------------------------------------------------------

    # What the client derives from every model call before anything else
    # can lose it: the long history of spend.
    def harness_count(call)
      tags = { "provider" => call["provider"], "model" => call["model"], "purpose" => call["purpose"] }
      at = call["ts"]
      harness_add([ "ai.calls", "counter", nil, tags.merge("status" => call["status"]) ], at, 1.0)
      harness_add([ "ai.cost", "counter", "usd", tags ], at, call["cost"].to_f)
      { "input" => "in", "output" => "out", "cache_read" => "cache_read", "cache_write" => "cache_write" }.each do |kind, key|
        harness_add([ "ai.tokens", "counter", "tokens", tags.merge("kind" => kind) ], at, call[key].to_f) if call[key].to_i.positive?
      end
      harness_add([ "ai.duration", "dist", "ms", tags ], at, call["dur"].to_f)
      harness_add([ "ai.ttft", "dist", "ms", tags ], at, call["ttft"].to_f) if call["ttft"]
    end

    def harness_add(series, at, value)
      raw = at >= (@now - Generator::RAW_METRIC_WINDOW).to_f
      width = raw ? 10 : 300
      bucket = [ raw, at.to_i - at.to_i % width ]
      cell = (@harness_series[series][bucket] ||= { n: 0, sum: 0.0, min: value, max: value, last: value, sketch: series[1] == "dist" ? Telemetry::Sketch.new : nil })
      cell[:n] += 1
      cell[:sum] += value
      cell[:min] = [ cell[:min], value ].min
      cell[:max] = [ cell[:max], value ].max
      cell[:last] = value
      cell[:sketch]&.add(value)
    end

    def write_harness_metrics(app)
      gauges = [
        [ "node.memory.rss_bytes", "bytes", ->(t) { 310e6 + 40e6 * activity(t) + sawtooth(t, 86_400 * 2.3, 90e6) } ],
        [ "node.heap.used_bytes", "bytes", ->(t) { 120e6 + 30e6 * activity(t) + Math.sin(t.to_f / 700).abs * 12e6 } ],
        [ "node.eventloop.delay_ms", "ms", ->(t) { 1.2 + 9 * activity(t) + Math.sin(t.to_f / 400).abs * 3 } ],
        [ "node.handles", nil, ->(t) { 38 + 20 * activity(t) } ],
        [ "aio.sandboxes.active", nil, ->(t) { (2.2 * activity(t)).round } ],
        [ "aio.approvals.pending", nil, ->(t) { t >= @stall_at && t < @stall_at + 660 ? 1 : 0 } ],
        [ "aio.fleet.running", nil, ->(t) { (1.4 * activity(t) + Math.sin(t.to_f / 1900).abs).round } ]
      ]
      raw_from = (@now - Generator::RAW_METRIC_WINDOW).to_i
      gauges.each do |name, unit, value|
        series = [ name, "gauge", unit, { "process" => PROCESS } ]
        (@from.to_i - @from.to_i % 300...raw_from).step(300) do |at|
          mid = [ value.call(Time.at(at + 150)), 0 ].max.to_f
          @harness_series[series][[ false, at ]] = { n: 30, sum: mid * 30, min: mid * 0.96, max: mid * 1.05, last: mid, sketch: nil }
        end
        (raw_from - raw_from % 10...@now.to_i).step(10) do |at|
          sample = [ value.call(Time.at(at)), 0 ].max.to_f
          @harness_series[series][[ true, at ]] = { n: 1, sum: sample, min: sample, max: sample, last: sample, sketch: nil }
        end
      end

      definitions = @harness_series.keys
      ids = register_series(app, definitions)
      raw = []
      folded = []
      definitions.zip(ids).each do |series, id|
        @harness_series[series].each do |(is_raw, at), cell|
          row = { series_id: id, ts: Time.at(at).utc, n: cell[:n], sum: cell[:sum], min: cell[:min], max: cell[:max], last: cell[:last],
                  sketch: cell[:sketch]&.to_pairs }
          (is_raw ? raw : folded) << row
        end
      end
      write_points(raw: raw, folded: folded)
    end

    def write_harness_process(app, releases)
      header = Ingest::Batch::Header.new(kind: PROCESS, host: "#{SPEC.slug}-#{PROCESS}-1", pid: 1, release: releases.last[1],
        started_at: releases.last[0] + 20, runtime: { "node" => "24.3.0", "agent" => "0.1.0", "client" => "glass-node" }, dropped: {})
      Telemetry::AgentProcess.where(app_id: app.telemetry_id, host: header.host).delete_all
      Ingest::Heartbeat.beat!(app, header, records: 0, now: Time.now.utc)
      app.update_columns(first_seen_at: @from, last_seen_at: Time.current)
    end
  end
end
