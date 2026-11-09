import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { accountFor, cleanAttrs, longestSilence, type SpanInput } from "../src/index.ts";
import { testAgent } from "./helpers.ts";

const T0 = 1_790_000_120_000;
const span = (id: string, kind: SpanInput["kind"], from: number, dur: number, parent?: string): SpanInput & { id: string } => ({ id, kind, name: id, startedAt: T0 + from, durMs: dur, parent });

test("accounts for a run's time once: phases are exclusive of each other", () => {
  const phases = accountFor(
    [
      span("q", "queue", 10, 800),
      span("m", "memory", 810, 250),
      span("c", "context", 1060, 50),
      span("r0", "model", 1200, 4000),
      span("t", "tool", 5300, 30_000),
      span("w", "wait", 5310, 24_000, "t"),
      span("s", "sandbox", 29_400, 3_900, "t"),
      span("r1", "model", 35_500, 5_000),
      span("d", "channel", 40_600, 400),
    ],
    "root", T0, T0 + 41_250,
  );
  assert.deepEqual(phases, { queue: 800, prep: 300, model: 9000, tool: 6000, wait: 24_000, deliver: 400 });
  assert.equal(41_250 - Object.values(phases).reduce((a, b) => a + b, 0), 750, "what no span covers is the untracked remainder");
});

test("overlapping steps cannot add up to more than the run", () => {
  const phases = accountFor([span("a", "tool", 0, 1000), span("b", "tool", 500, 1000), span("c", "model", 900, 200)], "root", T0, T0 + 1500);
  assert.deepEqual(phases, { queue: 0, prep: 0, model: 0, tool: 1500, wait: 0, deliver: 0 });
});

test("a wait deep inside a step still counts as waiting, and a span with a lost parent hangs off the root", () => {
  const phases = accountFor(
    [span("t", "tool", 0, 10_000), span("gate", "custom", 0, 9_000, "t"), span("w", "wait", 100, 8_000, "gate"), span("orphan", "model", 10_000, 500, "gone")],
    "root", T0, T0 + 10_500,
  );
  assert.deepEqual(phases, { queue: 0, prep: 0, model: 500, tool: 2000, wait: 8000, deliver: 0 });
});

test("the longest silence leaves out time spent waiting on the person", () => {
  assert.equal(longestSilence(T0, T0 + 10_000, [], []), 10_000);
  assert.equal(longestSilence(T0, T0 + 10_000, [T0 + 2_000, T0 + 9_000], []), 7_000);
  // A prompt at 2 s, answered at 9 s: nothing stalled but the person.
  assert.equal(longestSilence(T0, T0 + 10_000, [T0 + 2_000, T0 + 9_000], [[T0 + 2_000, T0 + 9_000]]), 2_000);
});

test("a run becomes one transaction, its spans and its model calls, sent when it finishes", async () => {
  const { agent, sent } = testAgent();
  const run = agent.startRun({ name: "owner-chat", agent: "owner-chat", session: "ses_81c4", trigger: "message", channel: "telegram", user: "u_9c1f", startedAt: T0, lagMs: 1200, attrs: { run: "run_01j9" } });
  run.addSpan({ kind: "queue", name: "session", startedAt: T0 + 20, durMs: 820, attrs: { behind: "compaction" } });
  const model = run.addSpan({ kind: "model", name: "anthropic-api", res: "claude-sonnet-4-6", startedAt: T0 + 1200, durMs: 4180 });
  const call = run.modelCall({ provider: "anthropic-api", model: "claude-sonnet-4-6", served: "claude-sonnet-4-6", startedAt: T0 + 1200, durMs: 4180, ttftMs: 612, inputTokens: 1840, cacheReadTokens: 21_400, outputTokens: 512, costUsd: 0.0193, costSource: "estimated", stop: "tool_use", round: 0, tools: 1, span: model });
  const tool = run.addSpan({ kind: "tool", name: "shell", startedAt: T0 + 5400, durMs: 30_200, status: "error", attrs: { input: { command: "rm -rf /" }, bytes: 412 } });
  run.addSpan({ kind: "wait", name: "approval", startedAt: T0 + 5410, durMs: 24_800, parent: tool });
  run.modelCall({ provider: "local", model: "qwen3:8b", purpose: "reviewer", origin: "internal", startedAt: T0 + 5405, durMs: 640, inputTokens: 900, outputTokens: 24, costUsd: 0.5, costSource: "shadow" });
  // Learned after the call returned: the record is still held.
  call.toolsValid = 1;
  run.visible(false, T0 + 5410);
  run.visible(true, T0 + 40_000);

  await agent.flush();
  assert.equal(sent[0]!.records.length, 0, "nothing is sent while the run is open");

  run.finish({ endedAt: T0 + 41_250, stop: "ok" });
  run.finish({ endedAt: T0 + 99_999 });
  await agent.flush(true);

  const records = sent[1]!.records;
  assert.deepEqual([...new Set(records.map((record) => record.t))], ["txn", "llm", "metric", "span"], "the cheap uniform rows travel first");
  const txn = records.find((record) => record.t === "txn")!;
  assert.deepEqual(txn, {
    t: "txn", ts: T0 / 1000, kind: "run", name: "owner-chat", trace: run.trace, span: run.span, dur: 41_250, status: "ok",
    agent: "owner-chat", session: "ses_81c4", trigger: "message", channel: "telegram", stop: "ok", user: "u_9c1f",
    model: "claude-sonnet-4-6", rounds: 1, calls: 2, tools_n: 1, tool_err: 1,
    tok_in: 2740, tok_out: 536, tok_cache_read: 21_400, tok_cache_write: 0, cost: 0.0193,
    queue_ms: 820, prep_ms: 0, model_ms: 4180, tool_ms: 5400, wait_ms: 24_800, deliver_ms: 0,
    ext_ms: 4820, ext_n: 2, lag_ms: 1200, ttft_ms: 40_000, stall_ms: 9790, kept: true, attrs: { run: "run_01j9" },
  });

  const spans = records.filter((record) => record.t === "span");
  assert.deepEqual(spans.map((record) => [record.kind, record.name, record.parent === run.span]), [["queue", "session", true], ["model", "anthropic-api", true], ["tool", "shell", true], ["wait", "approval", false]]);
  assert.equal(spans[2]!.status, "error");
  assert.equal(spans[3]!.parent, tool);

  const [first, reviewer] = records.filter((record) => record.t === "llm");
  assert.deepEqual(first, {
    t: "llm", ts: (T0 + 1200) / 1000, trace: run.trace, span: model, provider: "anthropic-api", model: "claude-sonnet-4-6", served: "claude-sonnet-4-6",
    purpose: "turn", origin: "production", agent: "owner-chat", session: "ses_81c4", round: 0, dur: 4180, ttft: 612,
    in: 1840, cache_read: 21_400, cache_write: 0, out: 512, reasoning: 0, cost: 0.0193, cost_src: "estimated",
    stop: "tool_use", status: "ok", tools: 1, tools_valid: 1,
  });
  assert.equal(reviewer!.purpose, "reviewer");
  assert.equal(reviewer!.trace, run.trace, "a call under a run carries the run's trace");

  const metrics = records.filter((record) => record.t === "metric");
  const cost = metrics.filter((record) => record.name === "ai.cost");
  assert.deepEqual(cost.map((record) => [record.tags.model, record.sum]), [["claude-sonnet-4-6", 0.0193]], "a shadow cost is not money spent");
  assert.deepEqual(metrics.find((record) => record.name === "ai.tool.calls")!.tags, { status: "error", tool: "shell" });
  assert.ok(metrics.some((record) => record.name === "ai.run.active" && record.sum === 41_250 - 24_800));
});

test("never sends what a tool was given, and bounds what it does send", () => {
  assert.deepEqual(cleanAttrs({ bytes: 4, cold: true, password: "x", api_key: "y", authorization: "z", totalTokens: 9, nested: { a: 1 }, nothing: null, text: "t".repeat(2000) }), {
    bytes: 4, cold: true, password: "[FILTERED]", api_key: "[FILTERED]", authorization: "[FILTERED]", totalTokens: 9, nested: '{"a":1}', text: "t".repeat(1000),
  });
  assert.equal(cleanAttrs({}), undefined);
});

test("the envelope in one call: ambient for what runs beneath it, closed as an error when it throws", async () => {
  const { agent, sent } = testAgent();
  const value = await agent.run({ name: "home-ops", trigger: "cron" }, async (run) => {
    assert.equal(agent.currentRun(), run);
    await agent.span("memory", "contribute", async () => {
      await new Promise((resolve) => setTimeout(resolve, 5));
      agent.log("info", "inside");
    });
    // Joined, not nested.
    return agent.run({ name: "ignored" }, (inner) => (inner === run ? "joined" : "nested"));
  });
  assert.equal(value, "joined");
  assert.equal(agent.currentRun(), null);
  await assert.rejects(agent.run({ name: "home-ops" }, () => { throw new TypeError("boom"); }), /boom/);
  assert.equal(await agent.span("tool", "outside any run", () => 7), 7);

  await agent.flush(true);
  const records = sent[0]!.records;
  const runs = records.filter((record) => record.t === "txn");
  assert.deepEqual(runs.map((record) => [record.name, record.status, record.error, record.stop]), [["home-ops", "ok", undefined, "ok"], ["home-ops", "error", "TypeError", "error"]]);
  assert.deepEqual(records.filter((record) => record.t === "span").map((record) => [record.kind, record.name]), [["memory", "contribute"]]);
  const log = records.find((record) => record.t === "log")!;
  assert.equal(log.trace, runs[0]!.trace);
});

test("a model call outside any run is sent at once", async () => {
  const { agent, sent } = testAgent();
  agent.modelCall({ provider: "local", model: "qwen3:8b", purpose: "title", origin: "internal", startedAt: T0, durMs: 300, outputTokens: 12 });
  await agent.flush(true);
  assert.deepEqual(sent[0]!.records.filter((record) => record.t === "llm").map((record) => [record.purpose, record.trace]), [["title", undefined]]);
});

test("a run can join the trace of the run that set it going, and be thrown away if it turns out not to be one", async () => {
  const { agent, sent } = testAgent();
  const child = agent.startRun({ name: "researcher", trigger: "task" });
  child.adopt("a".repeat(32), "b".repeat(16));
  child.addSpan({ kind: "tool", name: "recall", startedAt: T0, durMs: 5 });
  child.finish();
  const nothing = agent.startRun({ name: "interaction" });
  nothing.addSpan({ kind: "tool", name: "x", startedAt: T0, durMs: 5 });
  nothing.discard();
  nothing.finish();
  await agent.flush(true);
  const records = sent[0]!.records;
  assert.deepEqual(records.filter((record) => record.t === "txn").map((record) => [record.name, record.trace, record.parent]), [["researcher", "a".repeat(32), "b".repeat(16)]]);
  assert.deepEqual(records.filter((record) => record.t === "span").map((record) => record.trace), ["a".repeat(32)]);
});

test("filters the keys every client filters, and keeps the rest", () => {
  const kit = JSON.parse(readFileSync(new URL("../../../spec/fixtures/ingest/filter.json", import.meta.url), "utf8")) as { filtered: string[]; kept: string[] };
  for (const key of kit.filtered) assert.deepEqual(cleanAttrs({ [key]: "value" }), { [key]: "[FILTERED]" }, key);
  for (const key of kit.kept) assert.deepEqual(cleanAttrs({ [key]: "value" }), { [key]: "value" }, key);
});

test("a run that calls a model in a loop keeps a bounded number of calls, and counts the rest", async () => {
  const { agent, sent } = testAgent();
  const run = agent.startRun({ name: "looping" });
  for (let index = 0; index < 2_005; index += 1) run.modelCall({ provider: "ollama", model: "qwen3:8b", startedAt: T0, durMs: 1 });
  run.finish();
  await agent.flush();
  const records = sent[0]!.records;
  const txn = records.find((record) => record.t === "txn")!;
  assert.equal(records.filter((record) => record.t === "llm").length, 2_000);
  assert.equal(txn.calls, 2_005);
  assert.equal(txn.attrs.dropped_calls, 5);
});
