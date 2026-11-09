import { Panel, QueryBody } from "@/components/charts/Panel";
import { BatchTimeseries } from "@/components/charts/BatchTimeseries";
import { BarList } from "@/components/charts/BarList";
import { useAppsBySlug } from "@/hooks/useApps";
import { Kpi } from "@/components/ui/Kpi";
import { useGlassBatch } from "@/lib/glassQuery";
import { Failures } from "@/components/ui/Failures";
import { useScope, withScope } from "@/lib/scope";
import { useExploreHref, term } from "@/lib/explore";
import { formatCount, formatMs, formatPercent, num } from "@/lib/format";
import { tableToBars } from "@/lib/bars";
import type { TableResult, TimeseriesResult } from "@/types";

/** Visitors and visits in range: how many, from where, on what, to which pages and apps. */
export function OverviewTab() {
  const explore = useExploreHref();
  const scope = useScope();
  const bySlug = useAppsBySlug();
  const f = (extra?: string) => withScope(scope, extra);
  const glass = useGlassBatch(
    {
      totals: { source: "visits", shape: "table", filter: f(), compute: ["count", "uniq(visitor)", "sum(pageviews)", "avg(duration)", "avg(pageviews)"] },
      bounced: { source: "visits", shape: "table", filter: f("bounced:true"), compute: ["count"] },
      trend: { source: "visits", shape: "timeseries", filter: f(), compute: ["uniq(visitor)", "count"] },
      routes: { source: "page_events", shape: "table", filter: f("kind:pageview"), compute: ["count", "uniq(visit)"], group_by: ["route"], limit: 8 },
      referrers: { source: "visits", shape: "table", filter: f(), compute: ["count"], group_by: ["referrer"], limit: 6 },
      devices: { source: "visits", shape: "table", filter: f(), compute: ["count"], group_by: ["device"], limit: 4 },
      origins: { source: "visits", shape: "table", filter: f(), compute: ["count"], group_by: ["origin"], limit: 4 },
      apps: { source: "visits", shape: "table", filter: f(), compute: ["count", "sum(pageviews)"], group_by: ["app"], limit: 10 },
      users: { source: "visits", shape: "table", filter: f(), compute: ["count", "sum(pageviews)", "max(duration)"], group_by: ["user"], limit: 8 },
    },
    { live: scope.live },
  );
  const { batch, answer, failures } = glass;
  const totals = answer<TableResult>("totals")?.rows[0];
  const bounced = num(answer<TableResult>("bounced")?.rows[0]?.count);
  const visits = num(totals?.count);
  const series = answer<TimeseriesResult>("trend");
  const counts = (which: "referrers" | "devices" | "origins", key: string) => tableToBars(answer<TableResult>(which), { key, measure: "count", format: formatCount });

  return (
    <div className="space-y-4">
      <Failures messages={failures} />
      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-5">
        <Kpi label="Visitors" value={formatCount(num(totals?.["uniq(visitor)"]))} spark={series?.series[0]?.values} />
        <Kpi label="Visits" value={formatCount(visits)} spark={series?.series[1]?.values} />
        <Kpi label="Pageviews" value={formatCount(num(totals?.["sum(pageviews)"]))} hint={`${num(totals?.["avg(pageviews)"]).toFixed(1)} per visit`} />
        <Kpi label="Visit length" value={formatMs(num(totals?.["avg(duration)"]) * 1000)} hint="mean" />
        <Kpi label="Bounce" value={formatPercent(visits ? bounced / visits : 0, 0)} hint="one page, nothing clicked" />
      </div>
      <Panel title="Visitors and visits" subtitle="distinct visitors · visits, per bucket">
        <BatchTimeseries batch={glass} answer="trend" />
      </Panel>
      <div className="grid gap-3 lg:grid-cols-3">
        <Panel title="Top pages" subtitle="pageviews by route">
          <QueryBody query={batch} height={120}>
            {() => (
              <BarList
                rows={tableToBars(answer<TableResult>("routes"), {
                  key: "route",
                  measure: "count",
                  format: formatCount,
                  href: (row) => explore({ source: "page_events", shape: "list", filter: `kind:pageview ${term("route", String(row.route ?? ""))}` }),
                })}
              />
            )}
          </QueryBody>
        </Panel>
        <Panel title="By app">
          <QueryBody query={batch} height={120}>
            {() => (
              <BarList
                rows={tableToBars(answer<TableResult>("apps"), {
                  key: "app",
                  measure: "count",
                  format: formatCount,
                  label: (row) => String(row.app),
                  secondary: (row) => `${formatCount(num(row["sum(pageviews)"]))} views`,
                  color: (row) => `var(--color-series-${bySlug.get(String(row.app))?.color_slot ?? 1})`,
                  onClick: (row) => () => scope.setApp(String(row.app)),
                })}
              />
            )}
          </QueryBody>
        </Panel>
        <Panel title="People" subtitle="visits by user (per the app's identity mode)">
          <QueryBody query={batch} height={120}>
            {() => (
              <BarList
                rows={tableToBars(answer<TableResult>("users"), {
                  key: "user",
                  measure: "count",
                  format: formatCount,
                  label: (row) => (row.user === null ? "(anonymous)" : String(row.user)),
                  secondary: (row) => `${formatCount(num(row["sum(pageviews)"]))} views`,
                  href: (row) => (row.user === null ? undefined : explore({ source: "visits", shape: "list", filter: term("user", row.user as string) })),
                })}
              />
            )}
          </QueryBody>
        </Panel>
        <Panel title="Referrers" subtitle="where the visit came from">
          <QueryBody query={batch} height={100}>{() => <BarList rows={counts("referrers", "referrer")} emptyLabel="No referrers" />}</QueryBody>
        </Panel>
        <Panel title="Devices">
          <QueryBody query={batch} height={100}>{() => <BarList rows={counts("devices", "device")} />}</QueryBody>
        </Panel>
        <Panel title="Network origin" subtitle="on the LAN, over the VPN, through the tunnel">
          <QueryBody query={batch} height={100}>{() => <BarList rows={counts("origins", "origin")} />}</QueryBody>
        </Panel>
      </div>
    </div>
  );
}
