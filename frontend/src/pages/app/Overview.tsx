import { Panel, QueryBody } from "@/components/charts/Panel";
import { BatchTimeseries } from "@/components/charts/BatchTimeseries";
import { BarList } from "@/components/charts/BarList";
import { Failures } from "@/components/ui/Failures";
import { Kpi } from "@/components/ui/Kpi";
import { useGlassBatch } from "@/lib/glassQuery";
import { tableToBars } from "@/lib/bars";
import { useScope } from "@/lib/scope";
import { ScopedLink } from "@/components/scope/ScopedLink";
import { useExploreHref } from "@/lib/explore";
import { formatCount, formatMs, formatPercent, num, optionalNum } from "@/lib/format";
import type { App, TableResult } from "@/types";
import { SHEET_PATHS } from "@/pages/app/shared";

/** An app at a glance: throughput, errors and latency, where a request spends its time, what consumes it, and memory by process. */
export function OverviewTab({ app }: { app: App }) {
  const explore = useExploreHref();
  const { live } = useScope();
  const base = `app:${app.slug}`;
  const glass = useGlassBatch(
    {
      throughput: { source: "transactions", shape: "timeseries", filter: `${base} kind:request`, compute: ["rate", "errors"] },
      latency: { source: "transactions", shape: "timeseries", filter: `${base} kind:request`, compute: ["p50(duration)", "p95(duration)", "p99(duration)"] },
      breakdown: { source: "transactions", shape: "timeseries", filter: `${base} kind:request`, compute: ["avg(db)", "avg(view)", "avg(ext)", "avg(app_time)"] },
      endpoints: { source: "transactions", shape: "table", filter: `${base} kind:request`, compute: ["sum(duration)", "count", "p95(duration)", "error_rate"], group_by: ["name"], limit: 8 },
      jobs: { source: "transactions", shape: "table", filter: `${base} kind:job`, compute: ["sum(duration)", "count", "p95(duration)", "error_rate"], group_by: ["name"], limit: 6 },
      queries: { source: "spans", shape: "table", filter: `${base} kind:sql`, compute: ["sum(duration)", "count", "avg(duration)"], group_by: ["resource"], limit: 6 },
      summary: { source: "transactions", shape: "table", filter: base, compute: ["count", "error_rate", "p95(duration)", "apdex", "uniq(user)"] },
      memory: { source: "metrics", shape: "timeseries", filter: base, metric: "ruby.memory.rss_bytes", compute: ["max"], group_by: ["process"] },
    },
    { live },
  );
  const { batch, answer, failures } = glass;
  const summary = answer<TableResult>("summary")?.rows[0];
  const apdex = optionalNum(summary?.apdex);
  const toList = (key: "endpoints" | "jobs", kind: "request" | "job") =>
    tableToBars(answer<TableResult>(key), {
      key: "name",
      measure: "sum(duration)",
      format: formatMs,
      label: (row) => String(row.name),
      secondary: (row) => `${formatCount(num(row.count))} · p95 ${formatMs(num(row["p95(duration)"]))}`,
      href: (row) => `/apps/${app.slug}/${SHEET_PATHS[kind]}/${encodeURIComponent(String(row.name))}`,
    });

  return (
    <div className="space-y-4">
      <Failures messages={failures} />
      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-5">
        <Kpi label="Requests + jobs" value={formatCount(num(summary?.count))} to={explore({ filter: base, compute: ["count"], group_by: ["kind"] })} />
        <Kpi
          label="Error rate"
          value={formatPercent(num(summary?.error_rate))}
          tone={num(summary?.error_rate) > 0.02 ? "negative" : undefined}
          to={explore({ shape: "list", filter: `${base} status:error` })}
        />
        <Kpi label="p95 latency" value={formatMs(num(summary?.["p95(duration)"]))} to={explore({ shape: "list", filter: summary ? `${base} duration:>${Math.floor(num(summary["p95(duration)"]))}ms` : base })} />
        <Kpi
          label="Apdex (500ms)"
          value={apdex === null ? "—" : apdex.toFixed(2)}
          tone={(apdex ?? 1) < 0.85 ? "warning" : undefined}
          to={explore({ shape: "list", filter: `${base} duration:>500ms` })}
        />
        <Kpi label="Distinct users" value={formatCount(num(summary?.["uniq(user)"]))} to={explore({ shape: "table", filter: base, compute: ["count"], group_by: ["user"] })} />
      </div>
      <div className="grid gap-3 lg:grid-cols-3">
        <Panel title="Throughput and errors" subtitle="requests per second · errors per bucket">
          <BatchTimeseries batch={glass} answer="throughput" markersFor={app.slug} />
        </Panel>
        <Panel title="Latency" subtitle="p50 · p95 · p99">
          <BatchTimeseries batch={glass} answer="latency" markersFor={app.slug} />
        </Panel>
        <Panel title="Where a request spends its time" subtitle="mean per request: database · views · external · app">
          <BatchTimeseries batch={glass} answer="breakdown" markersFor={app.slug} stacked />
        </Panel>
      </div>
      <div className="grid gap-3 lg:grid-cols-3">
        <Panel title="Endpoints by time consumed" actions={<ScopedLink to={`/apps/${app.slug}/endpoints`} className="text-xs text-primary hover:underline">All</ScopedLink>}>
          <QueryBody query={batch} height={120}>{() => <BarList rows={toList("endpoints", "request")} />}</QueryBody>
        </Panel>
        <Panel title="Jobs by time consumed" actions={<ScopedLink to={`/apps/${app.slug}/jobs`} className="text-xs text-primary hover:underline">All</ScopedLink>}>
          <QueryBody query={batch} height={120}>{() => <BarList rows={toList("jobs", "job")} emptyLabel="No jobs in range" />}</QueryBody>
        </Panel>
        <Panel title="Queries by time consumed" subtitle="from kept traces" actions={<ScopedLink to={`/apps/${app.slug}/queries`} className="text-xs text-primary hover:underline">All</ScopedLink>}>
          <QueryBody query={batch} height={120}>
            {() => (
              <BarList
                rows={tableToBars(answer<TableResult>("queries"), { key: "resource", measure: "sum(duration)", format: formatMs, label: (row) => String(row.resource ?? "?"), secondary: (row) => `${formatCount(num(row.count))}×` })}
                emptyLabel="No kept traces in range"
              />
            )}
          </QueryBody>
        </Panel>
      </div>
      <Panel title="Memory" subtitle="resident set, by process">
        <BatchTimeseries batch={glass} answer="memory" markersFor={app.slug} height={120} fromZero />
      </Panel>
    </div>
  );
}
