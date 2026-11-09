import { formatBytes, formatCount, formatMs, formatPercent, formatRate, formatUsd, optionalNum } from "@/lib/format";
import { withScope, type Scope } from "@/lib/scope";
import type { BatchSpec } from "@/lib/glassQuery";
import type { App, QueryAnswer, TableResult, TimeseriesResult } from "@/types";

/**
 * The Overview's app tiles read through one lens at a time: the same tile —
 * four figures, two lines, the deploys — asked a different question. A lens
 * is its batch and how one app's tile reads it, so a new slice is an entry
 * here and nothing else.
 */

export type LensKey = "traffic" | "resources" | "jobs" | "visitors";

interface Figure {
  label: string;
  value: string;
  tone?: "negative" | "warning";
}

interface Trend {
  /** What the line is, said on hover: the tile has no axes. */
  label: string;
  values: (number | null)[] | undefined;
}

/** One app's tile through a lens: null when the app has nothing to show in it. */
export interface Tile {
  figures: Figure[];
  /** Wears the app's colour. */
  primary: Trend;
  /** Drawn muted beside it. */
  secondary: Trend;
}

/** One answer of the lens's batch, by the name its spec was given. */
export type Read = <T extends QueryAnswer>(key: string) => T | undefined;

export interface Lens {
  key: LensKey;
  label: string;
  /** What the tile is missing when the app reports nothing here. */
  empty: string;
  /** Its batch, keyed; asked over the scope's range. */
  specs: (scope: Scope) => Record<string, BatchSpec>;
  tile: (app: App, read: Read) => Tile | null;
  /** Where the tile leads: the app's page on the tab that tells the rest. */
  href: (app: App) => string;
}

const rowOf = (table: TableResult | undefined, app: App) => table?.rows.find((row) => row.app === app.slug);
const seriesOf = (result: TimeseriesResult | undefined, app: App) => result?.series.find((series) => series.group.app === app.slug)?.values;

const transactions = (scope: Scope, shape: "table" | "timeseries", filter: string, compute: string[], limit = 50): BatchSpec => ({
  source: "transactions",
  shape,
  filter: withScope(scope, filter),
  compute,
  group_by: ["app"],
  limit,
});

const metric = (scope: Scope, shape: "table" | "timeseries", name: string, compute: string, step?: number): BatchSpec => ({
  source: "metrics",
  shape,
  filter: withScope(scope),
  metric: name,
  compute: [compute],
  group_by: ["app"],
  ...(step ? { step } : {}),
});

// Fog is read once a minute: a bucket narrower than two readings is mostly gaps (as on the Container tab).
const CONTAINER_STEPS = [120, 300, 900, 1_800, 3_600, 10_800, 21_600, 43_200, 86_400];
const containerStep = (scope: Scope) => CONTAINER_STEPS.find((step) => (scope.range.to - scope.range.from) / step <= 180) ?? 86_400;

/**
 * Requests: how many, how fast, how many failed. Its batch opens the
 * Overview's own, which draws the fleet's charts from the same answers. An
 * agent harness says what its runs took and cost instead. (`satisfies`, so
 * the Overview's batch knows the names of its answers.)
 */
export const TRAFFIC = {
  key: "traffic",
  label: "Traffic",
  empty: "nothing in range",
  specs: (scope) => ({
    throughput: transactions(scope, "timeseries", "kind:request", ["rate"], 8),
    latency: transactions(scope, "timeseries", "kind:request", ["p95(duration)"], 8),
    byApp: transactions(scope, "table", "", ["count", "rate", "error_rate", "p95(duration)", "errors"]),
    runsByApp: transactions(scope, "table", "kind:run", ["count", "p95(active)", "sum(cost)", "error_rate"]),
    runs: transactions(scope, "timeseries", "kind:run", ["count"], 8),
  }),
  tile: (app, read) => {
    const latency = { label: "p95 request time", values: seriesOf(read<TimeseriesResult>("latency"), app) };
    if (app.kinds.includes("run")) {
      const runs = rowOf(read<TableResult>("runsByApp"), app) ?? {};
      return {
        figures: [
          { label: "runs", value: formatCount(optionalNum(runs.count) ?? 0) },
          { label: "p95 active", value: formatMs(optionalNum(runs["p95(active)"])) },
          { label: "spent", value: formatUsd(optionalNum(runs["sum(cost)"])) },
          errorsFigure(optionalNum(runs.error_rate)),
        ],
        primary: { label: "runs", values: seriesOf(read<TimeseriesResult>("runs"), app) },
        secondary: latency,
      };
    }
    const row = rowOf(read<TableResult>("byApp"), app);
    return {
      figures: [
        { label: "req/s", value: formatRate(optionalNum(row?.rate) ?? 0) },
        { label: "p95", value: formatMs(optionalNum(row?.["p95(duration)"])) },
        errorsFigure(optionalNum(row?.error_rate) ?? 0),
      ],
      primary: { label: "requests per second", values: seriesOf(read<TimeseriesResult>("throughput"), app) },
      secondary: latency,
    };
  },
  href: (app) => `/apps/${app.slug}`,
} satisfies Lens;

/**
 * What the app costs the machine: fog's reading of its container, and for
 * an app fog does not run, the resident memory its agent reports.
 */
export const RESOURCES: Lens = {
  key: "resources",
  label: "Resources",
  empty: "no container or process readings",
  specs: (scope) => ({
    cpu: metric(scope, "table", "fog.container.cpu_pct", "avg"),
    memory: metric(scope, "table", "fog.container.memory_bytes", "max"),
    netIn: metric(scope, "table", "fog.container.net_in_bps", "avg"),
    uptime: metric(scope, "table", "fog.container.up", "avg"),
    rubyRss: metric(scope, "table", "ruby.memory.rss_bytes", "max"),
    nodeRss: metric(scope, "table", "node.memory.rss_bytes", "max"),
    cpuTrend: metric(scope, "timeseries", "fog.container.cpu_pct", "avg", containerStep(scope)),
    memoryTrend: metric(scope, "timeseries", "fog.container.memory_bytes", "max", containerStep(scope)),
    rubyRssTrend: metric(scope, "timeseries", "ruby.memory.rss_bytes", "max"),
    nodeRssTrend: metric(scope, "timeseries", "node.memory.rss_bytes", "max"),
  }),
  tile: (app, read) => {
    const figure = (answer: string, key: string) => optionalNum(rowOf(read<TableResult>(answer), app)?.[key]);
    const cpu = figure("cpu", "avg");
    const container = figure("memory", "max");
    const rss = figure("rubyRss", "max") ?? figure("nodeRss", "max");
    const uptime = figure("uptime", "avg");
    if (cpu === null && container === null && rss === null) return null;
    return {
      figures: [
        // Fog's percent is of one core, as the Container tab shows it: past 100 is more than one.
        { label: "cpu", value: cpu === null ? "—" : `${cpu.toFixed(1)}%` },
        { label: container === null ? "rss" : "memory", value: formatBytes(container ?? rss) },
        { label: "net in", value: figure("netIn", "avg") === null ? "—" : `${formatBytes(figure("netIn", "avg"))}/s` },
        { label: "uptime", value: formatPercent(uptime, 2), tone: uptime !== null && uptime < 0.99 ? "warning" : undefined },
      ],
      primary: { label: "container CPU", values: seriesOf(read<TimeseriesResult>("cpuTrend"), app) },
      secondary: {
        label: container === null ? "resident memory" : "container memory",
        values: seriesOf(read<TimeseriesResult>("memoryTrend"), app) ?? seriesOf(read<TimeseriesResult>("rubyRssTrend"), app) ?? seriesOf(read<TimeseriesResult>("nodeRssTrend"), app),
      },
    };
  },
  href: (app) => `/apps/${app.slug}/${app.fog ? "container" : "runtime"}`,
};

/** Background work: how much ran, how long it took, how long it waited for a worker, how much failed. */
export const JOBS: Lens = {
  key: "jobs",
  label: "Jobs",
  empty: "no jobs in range",
  specs: (scope) => ({
    jobs: transactions(scope, "table", "kind:job", ["count", "p95(duration)", "p95(queue_ms)", "error_rate"]),
    count: transactions(scope, "timeseries", "kind:job", ["count"], 8),
    wait: transactions(scope, "timeseries", "kind:job", ["p95(queue_ms)"], 8),
  }),
  tile: (app, read) => {
    const row = rowOf(read<TableResult>("jobs"), app);
    if (!row) return null;
    return {
      figures: [
        { label: "jobs", value: formatCount(optionalNum(row.count)) },
        { label: "p95", value: formatMs(optionalNum(row["p95(duration)"])) },
        { label: "p95 wait", value: formatMs(optionalNum(row["p95(queue_ms)"])) },
        errorsFigure(optionalNum(row.error_rate) ?? 0),
      ],
      primary: { label: "jobs", values: seriesOf(read<TimeseriesResult>("count"), app) },
      secondary: { label: "p95 queue wait", values: seriesOf(read<TimeseriesResult>("wait"), app) },
    };
  },
  href: (app) => `/apps/${app.slug}/jobs`,
};

/** The people on the other end: how many came, how much they read, how fast it drew, how many left at once. */
export const VISITORS: Lens = {
  key: "visitors",
  label: "Visitors",
  empty: "no visits in range",
  specs: (scope) => ({
    visits: { source: "visits", shape: "table", filter: withScope(scope), compute: ["count", "uniq(visitor)", "sum(pageviews)"], group_by: ["app"], limit: 50 },
    bounced: { source: "visits", shape: "table", filter: withScope(scope, "bounced:true"), compute: ["count"], group_by: ["app"], limit: 50 },
    lcp: { source: "page_events", shape: "table", filter: withScope(scope, "kind:vital"), compute: ["p75(lcp)"], group_by: ["app"], limit: 50 },
    visitTrend: { source: "visits", shape: "timeseries", filter: withScope(scope), compute: ["count"], group_by: ["app"], limit: 8 },
    lcpTrend: { source: "page_events", shape: "timeseries", filter: withScope(scope, "kind:vital"), compute: ["p75(lcp)"], group_by: ["app"], limit: 8 },
  }),
  tile: (app, read) => {
    const row = rowOf(read<TableResult>("visits"), app);
    const visits = optionalNum(row?.count) ?? 0;
    if (!visits) return null;
    const bounced = optionalNum(rowOf(read<TableResult>("bounced"), app)?.count) ?? 0;
    const lcp = optionalNum(rowOf(read<TableResult>("lcp"), app)?.["p75(lcp)"]);
    return {
      figures: [
        { label: "visitors", value: formatCount(optionalNum(row?.["uniq(visitor)"])) },
        { label: "pageviews", value: formatCount(optionalNum(row?.["sum(pageviews)"])) },
        // Web Vitals' own thresholds: 2.5s is good, past 4s is poor.
        { label: "p75 LCP", value: formatMs(lcp), tone: lcp === null ? undefined : lcp > 4000 ? "negative" : lcp > 2500 ? "warning" : undefined },
        { label: "bounced", value: formatPercent(bounced / visits) },
      ],
      primary: { label: "visits", values: seriesOf(read<TimeseriesResult>("visitTrend"), app) },
      secondary: { label: "p75 LCP", values: seriesOf(read<TimeseriesResult>("lcpTrend"), app) },
    };
  },
  href: (app) => `/visitors?app=${app.slug}`,
};

export const LENSES: readonly Lens[] = [TRAFFIC, RESOURCES, JOBS, VISITORS];

export function lensFor(key: string | null): Lens {
  return LENSES.find((lens) => lens.key === key) ?? TRAFFIC;
}

function errorsFigure(rate: number | null): Figure {
  return { label: "errors", value: formatPercent(rate), tone: rate !== null && rate > 0.02 ? "negative" : undefined };
}
