import { Panel, QueryBody } from "@/components/charts/Panel";
import { BatchTimeseries } from "@/components/charts/BatchTimeseries";
import { StatusStrip } from "@/components/charts/StatusStrip";
import { statusRuns } from "@/components/charts/statusRuns";
import { Failures } from "@/components/ui/Failures";
import { Kpi } from "@/components/ui/Kpi";
import { useGlassBatch, type BatchSpec } from "@/lib/glassQuery";
import { useScope } from "@/lib/scope";
import { ScopedLink } from "@/components/scope/ScopedLink";
import { absoluteRange } from "@/lib/timeRange";
import { useExploreHref } from "@/lib/explore";
import { formatBytes, formatDateTime, formatMs, formatPercent } from "@/lib/format";
import type { App, TableResult, TimeseriesResult } from "@/types";

/** What fog reports of the app's container: CPU, memory, network, and whether it was up. */

const CONTAINER_CHARTS = [
  { title: "CPU", subtitle: "percent, mean", metric: "fog.container.cpu_pct", compute: "avg" },
  { title: "Memory", subtitle: "in use, peak", metric: "fog.container.memory_bytes", compute: "max" },
  { title: "Network in", subtitle: "bytes per second", metric: "fog.container.net_in_bps", compute: "avg" },
  { title: "Network out", subtitle: "bytes per second", metric: "fog.container.net_out_bps", compute: "avg" },
  { title: "Disk read", subtitle: "bytes per second", metric: "fog.container.disk_read_bps", compute: "avg" },
  { title: "Disk write", subtitle: "bytes per second", metric: "fog.container.disk_write_bps", compute: "avg" },
] as const;

const UP_METRIC = "fog.container.up";

// Fog is read once a minute, so a bucket narrower than two readings would
// be mostly gaps: the engine's own ladder, started at two minutes.
const CONTAINER_STEPS = [120, 300, 900, 1_800, 3_600, 10_800, 21_600, 43_200, 86_400];
const containerStep = (span: number) => CONTAINER_STEPS.find((step) => span / step <= 180) ?? 86_400;

/**
 * What fog says of the app's container: whether it was up, and how busy.
 * For an image with no agent this is the whole page — uptime and activity
 * with nothing installed in it.
 */
export function ContainerTab({ app }: { app: App }) {
  const explore = useExploreHref();
  const scope = useScope();
  const { range, live } = scope;
  const filter = `app:${app.slug}`;
  const step = containerStep(range.to - range.from);
  const metrics = { source: "metrics", filter } as const;
  const glass = useGlassBatch(
    {
      up: { ...metrics, shape: "timeseries", metric: UP_METRIC, compute: ["min", "avg"], step },
      uptime: { ...metrics, shape: "table", metric: UP_METRIC, compute: ["avg"] },
      cpu: { ...metrics, shape: "table", metric: "fog.container.cpu_pct", compute: ["avg"] },
      memory: { ...metrics, shape: "table", metric: "fog.container.memory_bytes", compute: ["max"] },
      netIn: { ...metrics, shape: "table", metric: "fog.container.net_in_bps", compute: ["avg"] },
      // Each chart's answer is named by its metric.
      ...(Object.fromEntries(CONTAINER_CHARTS.map((chart) => [chart.metric, { ...metrics, shape: "timeseries", metric: chart.metric, compute: [chart.compute], step }])) as Record<(typeof CONTAINER_CHARTS)[number]["metric"], BatchSpec>),
    },
    { live },
  );
  const { batch, answer, failures } = glass;
  const figure = (key: "uptime" | "cpu" | "memory" | "netIn", column: string) => {
    const value = answer<TableResult>(key)?.rows[0]?.[column];
    return typeof value === "number" ? value : null;
  };

  const up = answer<TimeseriesResult>("up");
  const every = up ? statusRuns(up.times, up.step, up.series[0]?.values ?? [], up.series[1]?.values) : [];
  // The first bucket starts before the range, and a coarse tier may hold
  // nothing for the part of it inside: that is not a gap in the readings.
  const runs = up && every[0]?.status === "unknown" && up.times[0] < up.from && every[0].to <= up.times[0] + up.step ? every.slice(1) : every;
  const outages = runs.filter((run) => run.status === "down").reverse();
  const uptime = figure("uptime", "avg");
  const cpu = figure("cpu", "avg");
  const netIn = figure("netIn", "avg");
  const fog = app.fog;
  const isUp = fog?.state === "running" && fog.healthy !== false;

  return (
    <div className="space-y-4">
      <Failures messages={failures} />
      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-5">
        <Kpi label="Uptime" value={formatPercent(uptime, 2)} tone={uptime !== null && uptime < 0.99 ? "warning" : undefined} to={explore({ source: "metrics", metric: UP_METRIC, compute: ["min"], filter })} />
        <Kpi label="Now" value={fog?.state ? (fog.healthy === false ? "unhealthy" : fog.state) : "—"} tone={fog?.state && !isUp ? "negative" : undefined} />
        <Kpi label="CPU, mean" value={cpu === null ? "—" : `${cpu.toFixed(1)}%`} to={explore({ source: "metrics", metric: "fog.container.cpu_pct", compute: ["avg"], filter })} />
        <Kpi label="Memory, peak" value={formatBytes(figure("memory", "max"))} to={explore({ source: "metrics", metric: "fog.container.memory_bytes", compute: ["max"], filter })} />
        <Kpi label="Network in, mean" value={netIn === null ? "—" : `${formatBytes(netIn)}/s`} to={explore({ source: "metrics", metric: "fog.container.net_in_bps", compute: ["avg"], filter })} />
      </div>
      <Panel
        title="Up and down"
        subtitle="fog's reading of the container and its health check, once a minute"
        actions={
          <ScopedLink to={explore({ source: "metrics", metric: UP_METRIC, compute: ["min"], filter })} className="text-xs text-primary hover:underline">
            Explore
          </ScopedLink>
        }
      >
        <QueryBody query={batch} height={60} isEmpty={() => runs.every((run) => run.status === "unknown")}>
          {() => (
            <div className="space-y-3">
              <StatusStrip runs={runs} />
              {outages.length === 0 ? (
                <p className="text-xs text-muted">No outages in this range.</p>
              ) : (
                <ul className="divide-y divide-border text-sm">
                  {outages.slice(0, 8).map((outage) => (
                    <li key={outage.from} className="flex flex-wrap items-center gap-3 py-1.5">
                      <span className="inline-block h-2 w-2 rounded-full bg-negative" aria-hidden />
                      <span className="text-foreground">Down {formatMs(outage.downSeconds * 1000)}</span>
                      <span className="tabular font-mono text-xs text-muted">
                        {step > 120 ? "around" : "from"} {formatDateTime(outage.from)}
                      </span>
                      <button
                        type="button"
                        className="ml-auto text-xs text-primary hover:underline"
                        onClick={() => scope.setRange(absoluteRange(outage.from - Math.max(outage.to - outage.from, 600), outage.to + Math.max(outage.to - outage.from, 600)))}
                      >
                        Frame it
                      </button>
                    </li>
                  ))}
                </ul>
              )}
              {outages.length > 8 ? <p className="text-xs text-muted">And {outages.length - 8} earlier.</p> : null}
            </div>
          )}
        </QueryBody>
      </Panel>
      <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
        {CONTAINER_CHARTS.map((chart) => (
          <Panel
            key={chart.metric}
            title={chart.title}
            subtitle={chart.subtitle}
            actions={
              <ScopedLink to={explore({ source: "metrics", metric: chart.metric, compute: [chart.compute], filter })} className="text-xs text-primary hover:underline">
                Explore
              </ScopedLink>
            }
          >
            <BatchTimeseries batch={glass} answer={chart.metric} markersFor={app.slug} height={120} fromZero />
          </Panel>
        ))}
      </div>
    </div>
  );
}
