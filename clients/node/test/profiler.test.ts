import assert from "node:assert/strict";
import { join } from "node:path";
import { test } from "node:test";
import { describeFrame, fold, type CpuProfile } from "../src/index.ts";
import { testAgent } from "./helpers.ts";

const frame = (functionName: string, url: string, lineNumber = 0) => ({ functionName, url, lineNumber });

/** Keep the one thread busy, in a function a flamegraph can name. */
function burn(ms: number): number {
  const until = performance.now() + ms;
  let sum = 0;
  while (performance.now() < until) for (let i = 0; i < 1000; i += 1) sum += Math.sqrt(i);
  return sum;
}

test("names a function by whose code it is, and never by an absolute path", () => {
  const root = "/Users/someone/src/aio";
  assert.deepEqual(describeFrame(frame("serialize", "file:///Users/someone/src/aio/packages/core/src/runtime.ts", 41), root), ["serialize", "packages/core/src/runtime.ts", 42, "app"]);
  assert.deepEqual(
    describeFrame(frame("parse", "file:///Users/someone/src/aio/node_modules/.pnpm/zod@4.0.0/node_modules/zod/lib/types.js", 9), root),
    ["parse", "zod/lib/types.js", 10, "gem"],
  );
  assert.deepEqual(describeFrame(frame("readFileSync", "node:fs", 400), root), ["readFileSync", "node:fs", 401, "node"]);
  assert.deepEqual(describeFrame(frame("(program)", "", -1), root), ["(program)", "", 0, "native"]);
  assert.deepEqual(describeFrame(frame("", "file:///opt/elsewhere/tools/bin/run.js", 0), root), ["(anonymous)", "tools/bin/run.js", 1, "app"]);
  assert.deepEqual(describeFrame(frame("wasm", "wasm://wasm/abc?secret=1", 0), root), ["wasm", "wasm://wasm/abc", 1, "native"]);
});

test("folds samples to stacks, root first, without the idle ones", () => {
  const profile: CpuProfile = {
    startTime: 0, endTime: 100_000,
    nodes: [
      { id: 1, callFrame: frame("(root)", ""), children: [2, 5, 6] },
      { id: 2, callFrame: frame("turn", "file:///app/src/turn.ts", 3), children: [3, 4] },
      { id: 3, callFrame: frame("stringify", "node:internal/json", 0) },
      { id: 4, callFrame: frame("(garbage collector)", "") },
      { id: 5, callFrame: frame("(idle)", "") },
      { id: 6, callFrame: frame("turn", "file:///app/src/turn.ts", 3) },
    ],
    samples: [3, 3, 5, 5, 5, 4, 2, 3, 6],
  };
  const { funcs, stacks, samples } = fold(profile, "/app");
  assert.deepEqual(funcs, [["turn", "src/turn.ts", 4, "app"], ["stringify", "node:internal/json", 1, "node"], ["(garbage collector)", "", 0, "native"]]);
  assert.deepEqual(stacks, [[0, 1], [0, 2], [0]]);
  // Two nodes that are the same stack fold into one row; the collector's samples say so.
  assert.deepEqual(samples, [[0, null, "running", 3], [1, null, "gc", 1], [2, null, "running", 2]]);
  assert.deepEqual(fold({ startTime: 0, endTime: 1, nodes: [], samples: [] }, "/app"), { funcs: [], stacks: [], samples: [] });
});

test("profiles continuously when asked to, and sends the window in flight on stop", async () => {
  const { agent, sent } = testAgent(undefined, { profiles: "continuous", root: join(import.meta.dirname, "..") });
  await new Promise((resolve) => setTimeout(resolve, 20)); // let the first window open
  burn(200);
  await agent.stop();
  const profiles = sent.flatMap((batch) => batch.records).filter((record) => record.t === "profile");
  assert.equal(profiles.length, 1);
  const profile = profiles[0]!;
  assert.equal(profile.hz, 100);
  assert.equal(profile.mode, "wall");
  assert.ok(profile.dur > 0.15);
  assert.equal(profile.request, undefined);
  const names = profile.funcs.map((entry: unknown[]) => entry[0]);
  assert.ok(names.includes("burn"), names.join(" "));
  const burned = profile.funcs.find((entry: unknown[]) => entry[0] === "burn");
  assert.deepEqual([burned[1], burned[3]], ["test/profiler.test.ts", "app"]);
  for (const entry of profile.funcs) assert.ok(!String(entry[1]).startsWith("/"), String(entry[1]));
  for (const [stack, transaction, state, weight] of profile.samples) {
    assert.ok(profile.stacks[stack]);
    assert.equal(transaction, null);
    assert.ok(["running", "gc"].includes(state));
    assert.ok(Number.isInteger(weight) && weight > 0);
  }
});

const reply = (directives: Record<string, unknown>) => () => ({ body: JSON.stringify({ accepted: 0, skipped: 0, directives }) });
const profilesIn = (sent: { records: Record<string, any>[] }[]) => sent.flatMap((batch) => batch.records).filter((record) => record.t === "profile");

test("does nothing until the console asks, then profiles once per request", async () => {
  const quiet = testAgent(undefined, { profiles: "on-demand" });
  burn(50);
  await quiet.agent.stop();
  assert.equal(profilesIn(quiet.sent).length, 0);

  const { agent, sent } = testAgent(reply({ profile_now: { id: "req_1", seconds: 60, hz: 1000 } }), { profiles: "on-demand" });
  await agent.flush();
  await agent.flush(); // the same id again: not a second profile
  await new Promise((resolve) => setTimeout(resolve, 20));
  burn(100);
  await agent.stop(); // a one-shot in flight is cut short and sent
  const profiles = profilesIn(sent);
  assert.equal(profiles.length, 1);
  assert.deepEqual([profiles[0]!.request, profiles[0]!.hz], ["req_1", 1000]);
  assert.ok(profiles[0]!.dur < 5);
});

test("the app's profiling setting turns continuous profiling off without a restart", async () => {
  const { agent, sent } = testAgent(reply({ profiling: false }), { profiles: "continuous", profileWindowMs: 40 });
  await agent.flush(); // learns the setting
  await new Promise((resolve) => setTimeout(resolve, 100)); // the window open at the time ends, and no other begins
  await agent.flush();
  const settled = sent.length;
  burn(80);
  await new Promise((resolve) => setTimeout(resolve, 100));
  await agent.stop();
  assert.equal(profilesIn(sent.slice(settled)).length, 0);
});
