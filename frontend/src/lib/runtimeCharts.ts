import type { MetricInfo } from "@/types";

export interface RuntimeChart {
  title: string;
  metric: string;
  compute: string;
}

const RUBY: RuntimeChart[] = [
  { title: "Resident memory", metric: "ruby.memory.rss_bytes", compute: "max" },
  { title: "Heap live slots", metric: "ruby.heap.live_slots", compute: "max" },
  { title: "GC runs", metric: "ruby.gc.count", compute: "rate" },
  { title: "GC time", metric: "ruby.gc.time_ms", compute: "sum" },
  { title: "Threads", metric: "ruby.threads", compute: "max" },
  { title: "Puma busy threads", metric: "puma.busy_threads", compute: "max" },
  { title: "Puma backlog", metric: "puma.backlog", compute: "max" },
  { title: "Connection pool busy", metric: "active_record.pool.busy", compute: "max" },
  { title: "Jobs ready", metric: "solid_queue.ready", compute: "max" },
  { title: "Oldest ready job", metric: "solid_queue.oldest_ready_age_s", compute: "max" },
];

/** Event-loop delay leads: everything in a Node process shares one thread, and this is what waiting for it looks like. */
const NODE: RuntimeChart[] = [
  { title: "Event-loop delay", metric: "node.eventloop.delay_ms", compute: "max" },
  { title: "Event-loop delay, p99", metric: "node.eventloop.delay_p99_ms", compute: "max" },
  { title: "Event-loop delay, worst", metric: "node.eventloop.delay_max_ms", compute: "max" },
  { title: "Resident memory", metric: "node.memory.rss_bytes", compute: "max" },
  { title: "Heap used", metric: "node.heap.used_bytes", compute: "max" },
  { title: "GC time", metric: "node.gc.time_ms", compute: "sum" },
  { title: "CPU, user", metric: "node.cpu.user_ms", compute: "sum" },
  { title: "Open handles", metric: "node.handles", compute: "max" },
];

const CONTAINER: RuntimeChart[] = [
  { title: "Container CPU", metric: "fog.container.cpu_pct", compute: "avg" },
  { title: "Container memory", metric: "fog.container.memory_bytes", compute: "max" },
];

const KNOWN = [...RUBY, ...NODE, ...CONTAINER];
/** Metrics that have pages of their own, or are the agent talking about itself. */
const ELSEWHERE = /^(ai\.|rails\.|http\.server\.|glass\.|fog\.|node\.|ruby\.|puma\.|active_record\.|solid_queue\.)/;
const MAX_OWN = 12;

/**
 * The charts of an app's Runtime tab: built from the metrics it reports, so
 * a Rails process gets Ruby's vitals, a Node process gets Node's, and
 * whatever gauges the app reports about itself (a harness's fleet depth, its
 * pending approvals) get a chart each with nothing to configure. Until the
 * catalog has loaded, or for an app that reports none of them, the Ruby set
 * stands in, as it always did.
 */
export function runtimeCharts(metrics: MetricInfo[] | undefined, slug: string): RuntimeChart[] {
  const reported = (metrics ?? []).filter((metric) => metric.apps.includes(slug));
  const names = new Set(reported.map((metric) => metric.name));
  const known = KNOWN.filter((chart) => names.has(chart.metric));
  if (known.length === 0 && reported.every((metric) => ELSEWHERE.test(metric.name))) return [...RUBY, ...CONTAINER];
  const own = reported
    .filter((metric) => !ELSEWHERE.test(metric.name))
    .slice(0, MAX_OWN)
    .map((metric) => ({ title: metric.name, metric: metric.name, compute: metric.kind === "counter" ? "sum" : metric.kind === "dist" ? "p95" : "max" }));
  return [...known, ...own];
}
