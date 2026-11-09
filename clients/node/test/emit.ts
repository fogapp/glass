// Prints one batch body, as the client would send it, for the server's suite
// to read (spec/services/ingest/node_client_spec.rb): the one test in which
// a real client and the real ingest builders meet.
import { join } from "node:path";
import { gunzipSync } from "node:zlib";
import { Glass } from "../src/index.ts";

let body = "";
const agent = new Glass().start({
  url: "http://glass.test", key: "glass_ing_test", process: "gateway", release: "5cec02a", host: "studio", flushIntervalMs: 3_600_000, vitals: false,
  profiles: "continuous", root: join(import.meta.dirname, ".."),
  sender: async (gzipped) => {
    body = gunzipSync(gzipped).toString("utf8");
    return { status: 202, body: "{}", retryAfter: null };
  },
});

const start = Date.now() - 60_000;
const run = agent.startRun({ name: "owner-chat", agent: "owner-chat", session: "ses_81c4", trigger: "message", channel: "telegram", user: "u_9c1f", startedAt: start, lagMs: 900, attrs: { run: "run_01j9" } });
run.addSpan({ kind: "queue", name: "session", startedAt: start + 20, durMs: 800, attrs: { behind: "compaction" } });
run.addSpan({ kind: "memory", name: "contribute", startedAt: start + 820, durMs: 200, attrs: { hits: 6 } });
const first = run.addSpan({ kind: "model", name: "anthropic-api", res: "claude-sonnet-4-6", startedAt: start + 1100, durMs: 4000, attrs: { round: 0 } });
run.modelCall({ provider: "anthropic-api", model: "claude-sonnet-4-6", served: "claude-sonnet-4-6", tier: "frontier", round: 0, startedAt: start + 1100, durMs: 4000, ttftMs: 600, firstTextMs: 1900, itlP95Ms: 41, concurrent: 1, stream: true, inputTokens: 1840, cacheReadTokens: 21_400, cacheWriteTokens: 0, outputTokens: 512, reasoningTokens: 96, costUsd: 0.0193, costSource: "estimated", stop: "tool_use", route: "agent:owner-chat", tools: 1, toolsValid: 1, span: first, attrs: { model_version: "mv_3a" } });
const tool = run.addSpan({ kind: "tool", name: "shell", startedAt: start + 5200, durMs: 30_000, attrs: { lane: "core", bytes: 412 } });
run.addSpan({ kind: "wait", name: "approval", startedAt: start + 5210, durMs: 24_000, parent: tool, attrs: { status: "approved" } });
run.addSpan({ kind: "sandbox", name: "start", startedAt: start + 29_300, durMs: 3_900, parent: tool, attrs: { cold: true } });
const second = run.addSpan({ kind: "model", name: "anthropic-api", res: "claude-sonnet-4-6", startedAt: start + 35_300, durMs: 5000, attrs: { round: 1 } });
run.modelCall({ provider: "anthropic-api", model: "claude-sonnet-4-6", served: "claude-sonnet-4-6", round: 1, startedAt: start + 35_300, durMs: 5000, ttftMs: 540, inputTokens: 1840, cacheReadTokens: 21_400, outputTokens: 512, costUsd: 0.0199, costSource: "estimated", stop: "end_turn", retryOf: first, span: second });
run.addSpan({ kind: "channel", name: "deliver", res: "telegram", startedAt: start + 40_400, durMs: 400, attrs: { attempts: 1 } });
run.visible(false, start + 5210);
run.visible(true, start + 40_800);
run.finish({ endedAt: start + 41_000 });

agent.modelCall({ provider: "local", model: "qwen3:8b", purpose: "title", origin: "internal", startedAt: start + 41_500, durMs: 640, queueMs: 0, loadMs: 0, promptMs: 220, decodeMs: 400, inputTokens: 900, outputTokens: 24, estimated: true, costUsd: 0, costSource: "free", stop: "end_turn" });
agent.marker("Model version changed: qwen3:8b", { attrs: { model: "qwen3:8b" } });
agent.log("warn", "[approvals] waited 24s on shell", { source: "gateway" });
agent.gauge("node.eventloop.delay_ms", 3.2, undefined, "ms");

// Something for the profiler to have seen.
function burn(ms: number): number {
  const until = performance.now() + ms;
  let sum = 0;
  while (performance.now() < until) for (let i = 0; i < 1000; i += 1) sum += Math.sqrt(i);
  return sum;
}
await new Promise((resolve) => setTimeout(resolve, 20));
burn(150);

await agent.stop(); // the last flush, with the profiling window in flight
process.stdout.write(body);
