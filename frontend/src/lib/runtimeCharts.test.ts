import { describe, expect, it } from "vitest";
import { runtimeCharts } from "@/lib/runtimeCharts";
import type { MetricInfo } from "@/types";

const metric = (name: string, apps: string[], kind: MetricInfo["kind"] = "gauge"): MetricInfo => ({ name, kind, unit: null, series: 1, apps, tags: [] });

describe("an app's runtime charts", () => {
  const metrics = [
    metric("ruby.memory.rss_bytes", ["hook"]), metric("puma.backlog", ["hook"]), metric("fog.container.cpu_pct", ["hook", "aio"]),
    metric("node.eventloop.delay_ms", ["aio"]), metric("node.memory.rss_bytes", ["aio"]), metric("node.gc.time_ms", ["aio"], "counter"),
    metric("aio.fleet.running", ["aio"]), metric("aio.approvals.pending", ["aio"]), metric("ai.cost", ["aio"], "counter"), metric("http.server.duration", ["aio"], "dist"),
    metric("wants.created", ["hook"], "counter"), metric("import.verify", ["hook"], "dist"),
  ];

  it("are the vitals of the runtime the app reports, then its own gauges", () => {
    expect(runtimeCharts(metrics, "aio").map((chart) => chart.metric)).toEqual([
      "node.eventloop.delay_ms", "node.memory.rss_bytes", "node.gc.time_ms", "fog.container.cpu_pct", "aio.fleet.running", "aio.approvals.pending",
    ]);
    expect(runtimeCharts(metrics, "hook").map((chart) => [chart.metric, chart.compute])).toEqual([
      ["ruby.memory.rss_bytes", "max"], ["puma.backlog", "max"], ["fog.container.cpu_pct", "avg"], ["wants.created", "sum"], ["import.verify", "p95"],
    ]);
  });

  it("fall back to the Ruby set before the catalog loads and for an app that reports none", () => {
    expect(runtimeCharts(undefined, "hook")).toHaveLength(12);
    expect(runtimeCharts(metrics, "silent")).toHaveLength(12);
    expect(runtimeCharts([metric("ai.cost", ["x"])], "x")[0]!.metric).toBe("ruby.memory.rss_bytes");
  });
});
