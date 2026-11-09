import { describe, expect, it } from "vitest";
import { uncovered, waterfall } from "@/components/telemetry/waterfall";
import type { Trace, TraceModelCall, TraceSpan, TraceTransaction } from "@/types";

const T0 = 1_790_000_120;
const txn = (over: Partial<TraceTransaction>): TraceTransaction => ({ ts: T0, app: "aio", kind: "run", name: "owner-chat", process: "gateway", host: null, release: null, span: "root", parent: null, duration: 10_000, status: "ok", error: null, attrs: {}, ...over }) as TraceTransaction;
const span = (id: string, kind: TraceSpan["kind"], from: number, duration: number, parent = "root"): TraceSpan => ({ ts: T0 + from / 1000, app: "aio", span: id, parent, kind, name: id, resource: null, duration, status: "ok", attrs: {} });

describe("uncovered", () => {
  it("finds the stretches no interval covers, whatever order and overlap they come in", () => {
    expect(uncovered(0, 100, [[60, 80], [10, 30], [20, 40]])).toEqual([[0, 10], [40, 20], [80, 20]]);
    expect(uncovered(0, 100, [])).toEqual([[0, 100]]);
    expect(uncovered(0, 100, [[-5, 200]])).toEqual([]);
  });
});

describe("a trace as a waterfall", () => {
  it("nests spans under their parents in start order, and gives a run a row for the time nothing covers", () => {
    const trace: Trace = {
      trace: "t", started_at: T0, duration_ms: 10_000, truncated: false,
      transactions: [txn({})],
      spans: [span("tool", "tool", 4000, 3000), span("model", "model", 500, 3000), span("wait", "wait", 4100, 2000, "tool")],
      model_calls: [{ span: "model", provider: "anthropic-api", model: "claude", tokens_in: 100, cache_read: 900, cache_write: 0, tokens_out: 50, cost: 0.01 } as TraceModelCall],
    };
    const rows = waterfall(trace);
    expect(rows.map((row) => [row.kind, row.name, row.depth])).toEqual([
      ["run", "owner-chat", 0], ["untracked", "no span covers this", 1], ["model", "model", 1], ["tool", "tool", 1], ["wait", "wait", 2],
    ]);
    const untracked = rows[1]!;
    // 0–500, 3500–4000 and 7000–10000 in milliseconds from the run's start.
    expect(untracked.segments!.map(([start, duration]) => [Math.round(start - T0 * 1000), Math.round(duration)])).toEqual([[0, 500], [3500, 500], [7000, 3000]]);
    expect(untracked.duration).toBe(4000);
    expect(rows[2]!.call?.model).toBe("claude");
  });

  it("says nothing of untracked time for a run with no spans, a request, or gaps too small to feel", () => {
    const base = { trace: "t", started_at: T0, duration_ms: 10_000, truncated: false, model_calls: [] };
    expect(waterfall({ ...base, transactions: [txn({})], spans: [] }).map((row) => row.kind)).toEqual(["run"]);
    expect(waterfall({ ...base, transactions: [txn({ kind: "request" })], spans: [span("sql", "sql", 0, 10)] }).map((row) => row.kind)).toEqual(["request", "sql"]);
    expect(waterfall({ ...base, transactions: [txn({})], spans: [span("model", "model", 5, 9990)] }).map((row) => row.kind)).toEqual(["run", "model"]);
  });

  it("hangs another app's request under the call that made it", () => {
    const trace: Trace = {
      trace: "t", started_at: T0, duration_ms: 10_000, truncated: false, model_calls: [],
      transactions: [txn({}), txn({ app: "hook", kind: "request", name: "McpController#handle", span: "hook-root", parent: "http", ts: T0 + 1.1, duration: 200 })],
      spans: [span("tool", "tool", 1000, 9000), span("http", "http", 1050, 300, "tool"), { ...span("sql", "sql", 1120, 50, "hook-root"), app: "hook" }],
    };
    expect(waterfall(trace).filter((row) => row.kind !== "untracked").map((row) => [row.app, row.kind, row.depth])).toEqual([
      ["aio", "run", 0], ["aio", "tool", 1], ["aio", "http", 2], ["hook", "request", 3], ["hook", "sql", 4],
    ]);
  });
});
