import assert from "node:assert/strict";
import { test } from "node:test";
import { gunzipSync } from "node:zlib";
import { Glass } from "../src/index.ts";
import { testAgent } from "./helpers.ts";

test("is inert without a URL and a key", async () => {
  const agent = new Glass().start({ url: "", key: "" });
  assert.equal(agent.enabled, false);
  agent.marker("nothing");
  agent.increment("x");
  const run = agent.startRun({ name: "owner-chat" });
  run.addSpan({ kind: "tool", name: "shell", startedAt: Date.now(), durMs: 5 });
  run.finish();
  await agent.flush();
  await agent.stop();
});

test("sends a header and one record per line, and applies the directives in the reply", async () => {
  const { agent, sent } = testAgent(() => ({ body: JSON.stringify({ directives: { log_level: "warn", trace_sample_rate: 2, mystery: true } }) }));
  agent.marker("Model version changed", { attrs: { model: "qwen3:8b", api_key: "nope" } });
  agent.log("info", "kept at first");
  await agent.flush();

  assert.equal(sent.length, 1);
  const { header, records, headers } = sent[0]!;
  assert.equal(header.v, 1);
  assert.deepEqual(Object.keys(header.process).sort(), ["host", "kind", "pid", "release", "runtime", "started_at"]);
  assert.equal(header.process.kind, "gateway");
  assert.equal(header.process.release, "5cec02a");
  assert.equal(header.process.runtime.client, "glass-node");
  assert.equal(header.dropped.llm, 0);
  assert.equal(headers.authorization, "Bearer glass_ing_test");
  assert.equal(headers["content-encoding"], "gzip");
  assert.deepEqual(records.map((record) => record.t), ["marker", "log"]);
  assert.deepEqual(records[0]!.attrs, { model: "qwen3:8b", api_key: "[FILTERED]" }, "a credential never leaves");
  assert.equal("attrs" in records[1]!, false, "absent fields are absent, not {}");

  assert.equal(agent.directives!.logLevel, "warn");
  assert.equal("traceSampleRate" in agent.directives!, false, "spans are only sent under a run, and a run is never sampled");
  agent.log("info", "below the level now");
  agent.log("error", "\u001b[31mred\u001b[0m");
  await agent.flush();
  assert.deepEqual(sent[1]!.records.map((record) => record.msg), ["red"]);
});

test("an idle process still heartbeats", async () => {
  const { agent, sent } = testAgent();
  await agent.flush();
  assert.equal(sent.length, 1);
  assert.deepEqual(sent[0]!.records, []);
});

test("drops on overflow and says so in the next header", async () => {
  const { agent, sent } = testAgent(undefined, { queueSize: 2 });
  for (let index = 0; index < 5; index += 1) agent.log("info", `line ${index}`);
  await agent.flush();
  assert.equal(sent[0]!.records.length, 2);
  assert.equal(sent[0]!.header.dropped.log, 3);
});

test("never retries into a dead server: a failed send drops the batch and counts it", async () => {
  const errors: string[] = [];
  const { agent, sent } = testAgent(() => { throw new Error("ECONNREFUSED"); }, { onError: (where: string) => errors.push(where) });
  agent.marker("lost");
  await agent.flush();
  agent.marker("next");
  await agent.flush();
  assert.deepEqual(errors, ["send", "send"]);
  assert.deepEqual(sent[1]!.records.map((record) => record.title), ["next"]);
  assert.equal(sent[1]!.header.dropped.marker, 1);
});

test("honours 429: pauses for Retry-After, shedding what arrives", async () => {
  let status = 429;
  const { agent, sent, advance } = testAgent(() => ({ status, retryAfter: "30" }));
  agent.marker("refused");
  await agent.flush();
  agent.marker("shed while paused");
  await agent.flush();
  assert.equal(sent.length, 1, "nothing is sent during the pause");

  status = 202;
  advance(31_000);
  agent.marker("after");
  await agent.flush();
  assert.deepEqual(sent[1]!.records.map((record) => record.title), ["after"]);
  assert.equal(sent[1]!.header.dropped.marker, 2);
});

test("says so when the server will not take a batch", async () => {
  const errors: string[] = [];
  const { agent, sent } = testAgent(() => ({ status: 500 }), { onError: (_where: string, error: unknown) => errors.push(String(error)) });
  agent.marker("x");
  await agent.flush();
  assert.match(errors[0]!, /answered 500/);
  await agent.flush();
  assert.equal(sent[1]!.header.dropped.marker, 1);
});

test("stops on 401", async () => {
  const errors: string[] = [];
  const { agent, sent } = testAgent(() => ({ status: 401 }), { onError: (_where: string, error: unknown) => errors.push(String(error)) });
  agent.marker("x");
  await agent.flush();
  assert.equal(agent.enabled, false);
  assert.match(errors[0]!, /refused the ingest key/);
  agent.marker("y");
  await agent.flush();
  assert.equal(sent.length, 1);
});

test("halves the next batch on 413 and grows back after six accepted", async () => {
  let status = 413;
  const { agent, sent } = testAgent(() => ({ status }), { queueSize: 20_000 });
  for (let index = 0; index < 12_000; index += 1) agent.log("info", "x");
  await agent.flush();
  assert.equal(sent[0]!.records.length, 10_000);
  status = 202;
  await agent.flush();
  assert.equal(sent[1]!.records.length, 2_000, "what did not fit the first batch waited");
  for (let index = 0; index < 6_000; index += 1) agent.log("info", "x");
  await agent.flush();
  assert.equal(sent[2]!.records.length, 5_000, "the limit was halved");
  for (let index = 0; index < 5; index += 1) await agent.flush();
  for (let index = 0; index < 10_000; index += 1) agent.log("info", "x");
  await agent.flush();
  assert.equal(sent.at(-1)!.records.length, 10_000, "and restored");
});

test("reports its own failures as a metric instead of raising them", async () => {
  const { agent, sent, advance } = testAgent(undefined, { beforeFlush: () => { throw new Error("gauge sampler broke"); } });
  await agent.flush();
  advance(20_000);
  await agent.flush();
  advance(20_000);
  await agent.flush();
  const metrics = sent.flatMap((batch) => batch.records).filter((record) => record.name === "glass.agent.errors");
  assert.ok(metrics.length >= 1);
});

test("a final flush still runs after one in flight: the open metric window and what arrived meanwhile are sent", async () => {
  const sent: string[][] = [];
  let release: () => void = () => undefined;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  let first = true;
  const agent = new Glass().start({
    url: "http://glass.test", key: "glass_ing_test", flushIntervalMs: 3_600_000, vitals: false, inbound: false, outbound: false, profiles: "off",
    sender: async (body) => {
      const lines = gunzipSync(body).toString("utf8").split("\n").filter(Boolean).slice(1).map((line) => JSON.parse(line) as Record<string, unknown>);
      sent.push(lines.map((record) => String(record.t === "metric" ? record.name : record.msg)));
      if (first) {
        first = false;
        await gate;
      }
      return { status: 202, body: "{}", retryAfter: null };
    },
  });
  agent.log("info", "before");
  const inFlight = agent.flush();
  await new Promise((resolve) => setImmediate(resolve));
  agent.log("info", "during");
  agent.increment("turns");
  const stopped = agent.stop();
  release();
  await inFlight;
  await stopped;
  assert.deepEqual(sent, [["before"], ["turns", "during"]]);
});

test("a value that cannot be said is left out, and never throws into the app", async () => {
  const errors: string[] = [];
  const { agent, sent } = testAgent(undefined, { onError: (where: string) => errors.push(where) });
  const cycle: Record<string, unknown> = {};
  cycle.self = cycle;
  const awkward = { fn: () => 1, sym: Symbol("x"), big: 10n, cycle, kept: "yes" };
  assert.doesNotThrow(() => agent.marker("Odd attrs", { attrs: awkward }));
  assert.doesNotThrow(() => agent.log("info", "odd attrs", { attrs: awkward }));
  assert.doesNotThrow(() => agent.log("info", "only odd attrs", { attrs: { fn: () => 1 } }));
  assert.doesNotThrow(() => agent.marker(undefined as unknown as string));
  const run = agent.startRun({ name: "owner-chat", attrs: awkward });
  assert.doesNotThrow(() => run.finish({ attrs: { big: 1n } }));
  await agent.flush();
  const records = sent[0]!.records;
  const [marker, log, bare] = records;
  assert.deepEqual(marker!.attrs, { kept: "yes" });
  assert.deepEqual(log!.attrs, { kept: "yes" });
  assert.equal("attrs" in bare!, false);
  assert.deepEqual(records.find((record) => record.t === "txn")!.attrs, { kept: "yes" });
  assert.deepEqual(errors, []);
});
