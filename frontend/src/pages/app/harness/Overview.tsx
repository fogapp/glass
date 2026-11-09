import { Panel, QueryBody } from "@/components/charts/Panel";
import { BatchTimeseries } from "@/components/charts/BatchTimeseries";
import { BarList } from "@/components/charts/BarList";
import { PhaseBar } from "@/components/charts/PhaseBar";
import { Kpi } from "@/components/ui/Kpi";
import { Failures } from "@/components/ui/Failures";
import { useGlassBatch } from "@/lib/glassQuery";
import { useScope } from "@/lib/scope";
import { ScopedLink } from "@/components/scope/ScopedLink";
import { useExploreHref, term } from "@/lib/explore";
import { formatCount, formatMs, formatPercent, formatRate, formatUsd, num, optionalNum } from "@/lib/format";
import { tableToBars } from "@/lib/bars";
import { PHASE_COMPUTES } from "@/lib/runs";
import type { App, TableResult } from "@/types";
import { noReadings, PHASE_SLOTS, phasesOf, relabel } from "@/pages/app/harness/shared";

/** A harness at a glance: its runs, what they cost, where their time went. */
export function HarnessOverview({ app }: { app: App }) {
  const explore = useExploreHref();
  const scope = useScope();
  const { range, live } = scope;
  const runs = `app:${app.slug} kind:run`;
  const calls = `app:${app.slug} -origin:eval`;
  const glass = useGlassBatch(
    {
      summary: { source: "transactions", shape: "table", filter: runs, compute: ["count", "error_rate", "p50(active)", "p95(active)", "p50(ttft)", "sum(cost)", "ratio(untracked, duration)", "sum(wait)", ...PHASE_COMPUTES] },
      phases: { source: "transactions", shape: "timeseries", filter: runs, compute: PHASE_COMPUTES },
      latency: { source: "transactions", shape: "timeseries", filter: runs, compute: ["p50(active)", "p95(active)", "p95(ttft)"] },
      spend: { source: "model_calls", shape: "timeseries", filter: calls, compute: ["sum(cost)"], group_by: ["model"], limit: 6 },
      agents: { source: "transactions", shape: "table", filter: runs, compute: ["sum(active)", "count", "p95(active)", "sum(cost)"], group_by: ["name"], limit: 6 },
      purposes: { source: "model_calls", shape: "table", filter: calls, compute: ["sum(cost)", "count"], group_by: ["purpose"], limit: 8 },
      tools: { source: "spans", shape: "table", filter: `app:${app.slug} kind:tool`, compute: ["sum(duration)", "count", "error_rate"], group_by: ["name"], limit: 6 },
      cache: { source: "model_calls", shape: "timeseries", filter: `${calls} cost_source:estimated,reported`, compute: ["ratio(cache_read, input_total)"] },
    },
    { live },
  );
  const { batch, answer, failures } = glass;
  const summary = answer<TableResult>("summary")?.rows[0];
  const untracked = num(summary?.["ratio(untracked, duration)"]);
  const ttft = optionalNum(summary?.["p50(ttft)"]);

  return (
    <div className="space-y-4">
      <Failures messages={failures} />
      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-6">
        <Kpi label="Runs" value={formatCount(num(summary?.count))} hint={`${formatRate(num(summary?.count) / Math.max(range.to - range.from, 1))}`} to={explore({ shape: "list", filter: runs })} />
        <Kpi
          label="p50 active"
          value={formatMs(num(summary?.["p50(active)"]))}
          hint={`p95 ${formatMs(num(summary?.["p95(active)"]))}`}
          to={explore({ filter: runs, compute: ["p50(active)", "p95(active)"] })}
        />
        <Kpi label="First text after" value={ttft === null ? "—" : formatMs(ttft)} hint="median, from taking the message" to={explore({ filter: runs, compute: ["p50(ttft)", "p95(ttft)"] })} />
        <Kpi
          label="Spent"
          value={formatUsd(num(summary?.["sum(cost)"]))}
          hint={`${formatUsd(num(summary?.["sum(cost)"]) / Math.max(num(summary?.count), 1))} a run`}
          to={explore({ source: "model_calls", shape: "table", filter: calls, compute: ["sum(cost)", "count"], group_by: ["model"] })}
        />
        <Kpi
          label="Error rate"
          value={formatPercent(num(summary?.error_rate))}
          tone={num(summary?.error_rate) > 0.05 ? "negative" : undefined}
          to={explore({ shape: "list", filter: `${runs} status:error` })}
        />
        <Kpi
          label="Untracked"
          value={formatPercent(untracked)}
          hint="of run time in no named step"
          tone={untracked > 0.1 ? "warning" : undefined}
          to={explore({ shape: "table", filter: runs, compute: ["ratio(untracked, duration)", "count"], group_by: ["name"] })}
        />
      </div>
      <Panel title="Where a run spends its time" subtitle="mean per run, from taking the message to handing over the reply">
        <QueryBody query={batch} height={52}>{() => <PhaseBar parts={phasesOf(summary)} format={formatMs} />}</QueryBody>
      </Panel>
      <div className="grid gap-3 lg:grid-cols-3">
        <Panel title="Time by step" subtitle="mean per run, stacked">
          {/* Relabelled once per answer, not per render: a fresh result would rebuild the chart every tick. */}
          <BatchTimeseries batch={glass} answer="phases" markersFor={app.slug} select={relabel} slots={PHASE_SLOTS} stacked />
        </Panel>
        <Panel title="How long it takes" subtitle="active p50 · p95 · first visible text p95">
          <BatchTimeseries batch={glass} answer="latency" markersFor={app.slug} />
        </Panel>
        <Panel title="Spend" subtitle="USD per bucket, by model">
          <BatchTimeseries batch={glass} answer="spend" markersFor={app.slug} stacked />
        </Panel>
      </div>
      <div className="grid gap-3 lg:grid-cols-3">
        <Panel title="Agents by time consumed" actions={<ScopedLink to={`/apps/${app.slug}/interactions`} className="text-xs text-primary hover:underline">All</ScopedLink>}>
          <QueryBody query={batch} height={120}>
            {() => (
              <BarList
                rows={tableToBars(answer<TableResult>("agents"), {
                  key: "name",
                  measure: "sum(active)",
                  format: formatMs,
                  label: (row) => String(row.name),
                  secondary: (row) => formatUsd(num(row["sum(cost)"])),
                  href: (row) => explore({ shape: "list", filter: `${runs} ${term("name", row.name as string)}` }),
                })}
                emptyLabel="No runs in range"
              />
            )}
          </QueryBody>
        </Panel>
        <Panel title="Spend by purpose" subtitle="why a model was called" actions={<ScopedLink to={`/apps/${app.slug}/models`} className="text-xs text-primary hover:underline">Models</ScopedLink>}>
          <QueryBody query={batch} height={120}>
            {() => (
              <BarList
                rows={tableToBars(answer<TableResult>("purposes"), {
                  key: "purpose",
                  measure: "sum(cost)",
                  format: formatUsd,
                  label: (row) => String(row.purpose),
                  secondary: (row) => `${formatCount(num(row.count))}×`,
                  href: (row) => explore({ source: "model_calls", shape: "list", filter: `${calls} ${term("purpose", row.purpose as string)}` }),
                })}
                emptyLabel="No model calls in range"
              />
            )}
          </QueryBody>
        </Panel>
        <Panel title="Tools by time consumed" actions={<ScopedLink to={`/apps/${app.slug}/tools`} className="text-xs text-primary hover:underline">All</ScopedLink>}>
          <QueryBody query={batch} height={120}>
            {() => (
              <BarList
                rows={tableToBars(answer<TableResult>("tools"), {
                  key: "name",
                  measure: "sum(duration)",
                  format: formatMs,
                  label: (row) => String(row.name),
                  secondary: (row) => `${formatCount(num(row.count))}×`,
                  href: (row) => explore({ source: "spans", shape: "list", filter: `app:${app.slug} kind:tool ${term("name", row.name as string)}` }),
                })}
                emptyLabel="No tool calls in range"
              />
            )}
          </QueryBody>
        </Panel>
      </div>
      <Panel title="Prompt cache" subtitle="share of input tokens read from cache, on metered models — a fall here is money">
        <BatchTimeseries batch={glass} answer="cache" markersFor={app.slug} height={110} legend={false} isEmpty={noReadings} />
      </Panel>
    </div>
  );
}
