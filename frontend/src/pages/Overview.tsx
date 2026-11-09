import { AlertTriangle, Rocket } from "lucide-react";
import { PageBody } from "@/components/layout/PageBody";
import { Panel, QueryBody } from "@/components/charts/Panel";
import { BatchTimeseries } from "@/components/charts/BatchTimeseries";
import { BarList } from "@/components/charts/BarList";
import { AppDot, appColor } from "@/components/scope/AppDot";
import { useApps, useAppsBySlug } from "@/hooks/useApps";
import { useGlassBatch } from "@/lib/glassQuery";
import { Failures } from "@/components/ui/Failures";
import { Kpi } from "@/components/ui/Kpi";
import { useMarkers } from "@/lib/markers";
import { useScope, withScope } from "@/lib/scope";
import { useExploreHref, term } from "@/lib/explore";
import { formatAgo, formatCount, formatMs, formatPercent, formatRate, num } from "@/lib/format";
import { tableToBars } from "@/lib/bars";
import { AppGrid } from "@/pages/overview/AppGrid";
import { TRAFFIC } from "@/pages/overview/lenses";
import type { App, Marker, TableResult, TimeseriesResult } from "@/types";

/**
 * Is anything wrong anywhere? One tile per app, read through a lens —
 * traffic, resources, jobs, visitors; the fleet's lines; what deployed;
 * what is slow.
 */
export function Overview() {
  const explore = useExploreHref();
  const scope = useScope();
  const apps = useApps();
  const bySlug = useAppsBySlug();
  const { range, live } = scope;

  // The Traffic lens's queries open the batch: its tiles and the fleet's charts read the same answers.
  const glass = useGlassBatch(
    {
      ...TRAFFIC.specs(scope),
      errors: { source: "transactions", shape: "timeseries", filter: withScope(scope, "kind:request"), compute: ["error_rate"], group_by: ["app"], limit: 8 },
      topEndpoints: { source: "transactions", shape: "table", filter: withScope(scope), compute: ["sum(duration)", "count", "p95(duration)"], group_by: ["app", "name"], limit: 8 },
      topErrors: { source: "transactions", shape: "table", filter: withScope(scope, "status:error"), compute: ["count"], group_by: ["app", "error"], limit: 6 },
    },
    { live },
  );
  const { batch, answer, failures } = glass;
  const markers = useMarkers(range, scope.app, live);

  const throughput = answer<TimeseriesResult>("throughput");
  const byApp = answer<TableResult>("byApp");
  const errors = answer<TimeseriesResult>("errors");
  const topEndpoints = answer<TableResult>("topEndpoints");
  const topErrors = answer<TableResult>("topErrors");

  const visibleApps = (apps.data ?? []).filter((app) => !scope.app || app.slug === scope.app);
  const fleet = byApp?.rows ?? [];
  const totals = {
    count: fleet.reduce((sum, row) => sum + num(row.count), 0),
    errors: fleet.reduce((sum, row) => sum + num(row.errors), 0),
  };

  return (
    <PageBody className="space-y-4 py-4">
      <Failures messages={failures} />
      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <Kpi
          label="Requests, jobs and runs"
          value={formatCount(totals.count)}
          hint={`${formatRate(totals.count / Math.max(range.to - range.from, 1))} over the range`}
          spark={sum(throughput)}
          to={explore({ compute: ["rate"], group_by: ["app"] })}
        />
        <Kpi
          label="Error rate"
          value={formatPercent(totals.count ? totals.errors / totals.count : 0)}
          hint={`${formatCount(totals.errors)} errors`}
          tone={totals.count && totals.errors / totals.count > 0.02 ? "negative" : undefined}
          spark={avg(errors)}
          to={explore({ filter: "status:error", shape: "list" })}
        />
        <Kpi
          label="Apps reporting"
          value={`${visibleApps.filter((app) => app.reporting).length}/${visibleApps.length}`}
          hint={visibleApps.filter((app) => !app.reporting).map((app) => app.name).join(", ") || "all reporting"}
          tone={visibleApps.some((app) => !app.reporting) ? "warning" : undefined}
          to="/fleet"
        />
        <Kpi
          label="Deploys"
          value={String(markers.data?.filter((marker) => marker.kind === "deploy").length ?? "—")}
          hint={latestDeploy(markers.data)}
          to="/fleet"
        />
      </div>

      <div className="grid gap-3 lg:grid-cols-3">
        <Panel title="Throughput" subtitle="requests per second, by app">
          <BatchTimeseries batch={glass} answer="throughput" apps={apps.data} stacked />
        </Panel>
        <Panel title="Latency" subtitle="p95 request time, by app">
          <BatchTimeseries batch={glass} answer="latency" apps={apps.data} />
        </Panel>
        <Panel title="Errors" subtitle="share of requests that failed, by app">
          <BatchTimeseries batch={glass} answer="errors" apps={apps.data} />
        </Panel>
      </div>

      <AppGrid apps={apps.data} loadFailed={apps.isError} traffic={glass} markers={markers.data ?? []} />

      <div className="grid gap-3 lg:grid-cols-3">
        <Panel title="Where the time goes" subtitle="endpoints and jobs by total time" className="lg:col-span-2">
          <QueryBody query={batch} height={120} isEmpty={() => !topEndpoints || topEndpoints.rows.length === 0}>
            {() => (
              <BarList
                rows={tableToBars(topEndpoints, {
                  key: (row) => `${row.app}:${row.name}`,
                  measure: "sum(duration)",
                  format: formatMs,
                  label: (row) => `${row.name}`,
                  secondary: (row) => `p95 ${formatMs(num(row["p95(duration)"]))}`,
                  color: (row) => appColor(bySlug.get(String(row.app))),
                  href: (row) => `/apps/${row.app}/endpoints/${encodeURIComponent(String(row.name))}`,
                })}
              />
            )}
          </QueryBody>
        </Panel>
        <Panel title="Recent errors" subtitle="by class">
          <QueryBody query={batch} height={120} isEmpty={() => !topErrors || topErrors.rows.length === 0}>
            {() => (
              <BarList
                rows={tableToBars(topErrors, {
                  key: (row) => `${row.app}:${row.error}`,
                  measure: "count",
                  format: formatCount,
                  label: (row) => String(row.error ?? "(unknown)"),
                  secondary: (row) => String(row.app ?? ""),
                  color: (row) => appColor(bySlug.get(String(row.app))),
                  href: (row) => explore({ shape: "list", filter: `status:error ${term("app", row.app as string)} ${term("error", row.error as string)}` }),
                })}
              />
            )}
          </QueryBody>
        </Panel>
      </div>

      <Panel title="Timeline" subtitle="deploys and events in range">
        <MarkerList markers={markers.data ?? []} apps={apps.data ?? []} />
      </Panel>
    </PageBody>
  );
}

function MarkerList({ markers, apps }: { markers: Marker[]; apps: App[] }) {
  if (markers.length === 0) return <p className="py-2 text-center text-xs text-muted">Nothing deployed or happened in this range</p>;
  return (
    <ul className="divide-y divide-border">
      {markers.slice(0, 12).map((marker, index) => (
        <li key={`${marker.ts}-${index}`} className="flex items-center gap-3 py-1.5 text-sm">
          {marker.kind === "incident" ? <AlertTriangle className="h-3.5 w-3.5 text-negative" aria-hidden /> : <Rocket className="h-3.5 w-3.5 text-primary" aria-hidden />}
          <AppDot app={apps.find((app) => app.slug === marker.app)} />
          <span className="text-foreground">{marker.title}</span>
          <span className="ml-auto text-xs text-muted">{formatAgo(marker.ts)}</span>
        </li>
      ))}
    </ul>
  );
}

function sum(result: TimeseriesResult | undefined): (number | null)[] | undefined {
  if (!result) return undefined;
  return result.times.map((_, index) => result.series.reduce((total, series) => total + (series.values[index] ?? 0), 0));
}

function avg(result: TimeseriesResult | undefined): (number | null)[] | undefined {
  if (!result || result.series.length === 0) return undefined;
  return result.times.map((_, index) => {
    const values = result.series.map((series) => series.values[index]).filter((value): value is number => value !== null && value !== undefined);
    return values.length ? values.reduce((total, value) => total + value, 0) / values.length : null;
  });
}

function latestDeploy(markers: Marker[] | undefined): string {
  const deploy = markers?.find((marker) => marker.kind === "deploy");
  return deploy ? `${deploy.app ?? "fleet"} ${formatAgo(deploy.ts)}` : "none in range";
}
