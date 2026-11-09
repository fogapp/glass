import { Flame } from "lucide-react";
import { Panel, QueryBody } from "@/components/charts/Panel";
import { BatchTimeseries } from "@/components/charts/BatchTimeseries";
import { Heatmap } from "@/components/charts/Heatmap";
import { BarList } from "@/components/charts/BarList";
import { PhaseBar } from "@/components/charts/PhaseBar";
import { Sparkline } from "@/components/charts/Sparkline";
import { Sheet } from "@/components/ui/Sheet";
import { Failures } from "@/components/ui/Failures";
import { Kpi } from "@/components/ui/Kpi";
import { useGlassBatch } from "@/lib/glassQuery";
import { tableToBars } from "@/lib/bars";
import { useScope } from "@/lib/scope";
import { useScopedNavigate } from "@/lib/scopeHref";
import { ScopedLink } from "@/components/scope/ScopedLink";
import { useExploreHref, term } from "@/lib/explore";
import { formatCount, formatMs, formatPercent, num } from "@/lib/format";
import type { App, HeatmapResult, ListResult, TableResult, TimeseriesResult, TransactionRow } from "@/types";
import { TransactionList } from "@/components/telemetry/TransactionList";

/** One endpoint or job, opened beside the list it was picked from. */
export function EndpointSheet({ app, kind, name, onClose }: { app: App; kind: "request" | "job"; name: string; onClose: () => void }) {
  const explore = useExploreHref();
  const scope = useScope();
  const { live } = scope;
  const filter = `app:${app.slug} kind:${kind} ${term("name", name)}`;
  const noun = kind === "request" ? { one: "endpoint", each: "request", every: "Every request" } : { one: "job", each: "run", every: "Every run" };
  const glass = useGlassBatch(
    {
      latency: { source: "transactions", shape: "timeseries", filter, compute: ["p50(duration)", "p95(duration)", "p99(duration)"] },
      throughput: { source: "transactions", shape: "timeseries", filter, compute: ["rate", "errors"] },
      heatmap: { source: "transactions", shape: "heatmap", filter, field: "duration" },
      summary: { source: "transactions", shape: "table", filter, compute: ["count", "error_rate", "p50(duration)", "p95(duration)", "avg(db)", "avg(view)", "avg(ext)", "avg(app_time)", "avg(db_count)", "uniq(user)"] },
      slowest: { source: "transactions", shape: "list", filter: `${filter} kept:true`, limit: 12, order: "-duration" },
      errors: { source: "transactions", shape: "table", filter: `${filter} status:error`, compute: ["count"], group_by: ["error"], limit: 5 },
      releases: { source: "transactions", shape: "timeseries", filter, compute: ["avg(duration)"], group_by: ["release"], limit: 6 },
    },
    { live },
  );
  const { batch, answer, failures } = glass;
  const navigate = useScopedNavigate();
  const summary = answer<TableResult>("summary")?.rows[0];
  const breakdown = [
    ["Database", num(summary?.["avg(db)"])],
    ["Views", num(summary?.["avg(view)"])],
    ["External", num(summary?.["avg(ext)"])],
    ["App", num(summary?.["avg(app_time)"])],
  ] as const;

  return (
    <Sheet open onClose={onClose} title={name} description={`${app.name} · ${formatCount(num(summary?.count))} in range`} size="lg">
      <div className="space-y-4">
        <Failures messages={failures} />
        <div className="flex flex-wrap gap-2 text-xs">
          <ScopedLink to={`/profiles?app=${app.slug}&transaction=${encodeURIComponent(name)}`} className="flex items-center gap-1 rounded-[var(--radius-control)] border border-border px-2 py-1 text-foreground hover:bg-surface-raised">
            <Flame className="h-3.5 w-3.5" aria-hidden /> Flamegraph of this {noun.one}
          </ScopedLink>
          <ScopedLink to={explore({ shape: "list", filter })} className="rounded-[var(--radius-control)] border border-border px-2 py-1 text-foreground hover:bg-surface-raised">
            {noun.every}
          </ScopedLink>
          <ScopedLink to={explore({ shape: "list", filter: `${filter} status:error` })} className="rounded-[var(--radius-control)] border border-border px-2 py-1 text-foreground hover:bg-surface-raised">
            Errors
          </ScopedLink>
        </div>
        <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
          <Kpi label="p50" value={formatMs(num(summary?.["p50(duration)"]))} />
          <Kpi label="p95" value={formatMs(num(summary?.["p95(duration)"]))} />
          <Kpi label="Errors" value={formatPercent(num(summary?.error_rate))} tone={num(summary?.error_rate) > 0.02 ? "negative" : undefined} />
          <Kpi label={`Queries / ${noun.each}`} value={num(summary?.["avg(db_count)"]).toFixed(1)} tone={num(summary?.["avg(db_count)"]) > 25 ? "warning" : undefined} />
        </div>
        <Panel title="Latency" subtitle="p50 · p95 · p99">
          <BatchTimeseries batch={glass} answer="latency" markersFor={app.slug} height={150} />
        </Panel>
        <Panel title="Latency distribution over time" subtitle={`click a cell for the ${noun.each}s in it`}>
          <QueryBody query={batch} height={180}>
            {() => {
              const result = answer<HeatmapResult>("heatmap");
              return result ? (
                <Heatmap
                  result={result}
                  height={180}
                  onCell={(from, to, low, high) =>
                    navigate(explore({ shape: "list", filter: `${filter} duration:${low.toFixed(1)}..${high.toFixed(1)}` }, { range: `${Math.floor(from)}-${Math.ceil(to)}` }))
                  }
                />
              ) : null;
            }}
          </QueryBody>
        </Panel>
        <Panel title="Throughput and errors">
          <BatchTimeseries batch={glass} answer="throughput" markersFor={app.slug} height={120} />
        </Panel>
        <Panel title="Where the time goes" subtitle={`mean per ${noun.each}`}>
          <QueryBody query={batch} height={52}>
            {() => <PhaseBar parts={breakdown.map(([label, value], index) => ({ key: label, label, value, color: `var(--color-series-${index + 1})` }))} format={formatMs} />}
          </QueryBody>
        </Panel>
        <Panel title="By release" subtitle="mean latency per release — did a deploy change it?">
          <BatchTimeseries batch={glass} answer="releases" markersFor={app.slug} height={120} />
        </Panel>
        <Panel title="Errors by class">
          <QueryBody query={batch} height={60} isEmpty={() => (answer<TableResult>("errors")?.rows.length ?? 0) === 0}>
            {() => (
              <BarList
                rows={tableToBars(answer<TableResult>("errors"), {
                  key: "error",
                  measure: "count",
                  format: formatCount,
                  label: (row) => String(row.error ?? "(unknown)"),
                  href: (row) => explore({ shape: "list", filter: `${filter} ${term("error", row.error as string)}` }),
                })}
              />
            )}
          </QueryBody>
        </Panel>
        <Panel title="Slowest kept traces">
          <QueryBody query={batch} height={100} isEmpty={() => (answer<ListResult>("slowest")?.rows.length ?? 0) === 0}>
            {() => <TransactionList rows={(answer<ListResult>("slowest")?.rows ?? []) as unknown as TransactionRow[]} apps={[app]} compact />}
          </QueryBody>
        </Panel>
        <p className="text-xs text-muted">
          Sparkline of throughput in range: <Sparkline values={answer<TimeseriesResult>("throughput")?.series[0]?.values ?? []} width={120} height={20} />
        </p>
      </div>
    </Sheet>
  );
}
