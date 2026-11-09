import { describe, expect, it } from "vitest";
import { JOBS, LENSES, RESOURCES, TRAFFIC, VISITORS, lensFor } from "@/pages/overview/lenses";
import type { App, QueryAnswer, TableResult, TimeseriesResult } from "@/types";

const app = (slug: string, kinds: string[] = ["request"]) => ({ slug, name: slug, kinds }) as unknown as App;
const table = (rows: Record<string, string | number>[]): TableResult => ({ shape: "table", from: 0, to: 60, columns: [], rows });
const series = (slug: string, values: number[]): TimeseriesResult => ({ shape: "timeseries", from: 0, to: 60, step: 30, times: [0, 30], series: [{ key: slug, group: { app: slug }, unit: null, values }] });
const reader = (answers: Record<string, QueryAnswer | undefined>) => <T extends QueryAnswer>(key: string) => answers[key] as T | undefined;

describe("the Overview's lenses", () => {
  it("fall back to Traffic for a missing or unknown key", () => {
    expect(lensFor(null)).toBe(TRAFFIC);
    expect(lensFor("nonsense")).toBe(TRAFFIC);
    expect(lensFor("jobs")).toBe(JOBS);
    expect(LENSES.length).toBeGreaterThanOrEqual(3);
  });

  it("read requests for an app, and runs for a harness", () => {
    const answers = { throughput: series("hook", [1, 2]), latency: series("hook", [80, 90]), byApp: table([{ app: "hook", rate: 2, "p95(duration)": 120, error_rate: 0.05 }]), runsByApp: table([{ app: "aio", count: 4, "p95(active)": 900, "sum(cost)": 1.2, error_rate: 0 }]) };
    const hook = TRAFFIC.tile(app("hook"), reader(answers))!;
    expect(hook.figures.map((figure) => figure.label)).toEqual(["req/s", "p95", "errors"]);
    expect(hook.figures[2]!.tone).toBe("negative");
    expect(hook.primary.values).toEqual([1, 2]);
    expect(TRAFFIC.tile(app("aio", ["run"]), reader(answers))!.figures.map((figure) => figure.label)).toEqual(["runs", "p95 active", "spent", "errors"]);
  });

  it("say an app has nothing to show rather than a row of zeros", () => {
    const none = reader(Object.fromEntries(["jobs", "visits", "bounced", "lcp", "cpu", "memory", "rubyRss", "nodeRss"].map((key) => [key, table([])])));
    expect(JOBS.tile(app("hook"), none)).toBeNull();
    expect(VISITORS.tile(app("hook"), none)).toBeNull();
    expect(RESOURCES.tile(app("hook"), none)).toBeNull();
  });

  it("read a process's resident memory when fog has no container for it", () => {
    const answers = { cpu: table([]), memory: table([]), netIn: table([]), uptime: table([]), rubyRss: table([]), nodeRss: table([{ app: "aio", max: 300_000_000 }]) };
    const tile = RESOURCES.tile(app("aio"), reader(answers))!;
    expect(tile.figures.map((figure) => [figure.label, figure.value])).toContainEqual(["rss", "286 MB"]);
    expect(RESOURCES.href(app("aio"))).toBe("/apps/aio/runtime");
  });

  it("name every answer they read in their batch", () => {
    const scope = { filter: "", range: { from: 0, to: 3600 } } as unknown as Parameters<typeof TRAFFIC.specs>[0];
    for (const lens of LENSES) {
      const keys = Object.keys(lens.specs(scope));
      const asked: string[] = [];
      lens.tile(app("aio", ["request", "run"]), <T extends QueryAnswer>(key: string) => {
        asked.push(key);
        return undefined as T | undefined;
      });
      expect(keys).toEqual(expect.arrayContaining(asked));
    }
  });
});
