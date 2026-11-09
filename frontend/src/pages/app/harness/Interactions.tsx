import { useMemo, useState } from "react";
import { Panel, QueryBody } from "@/components/charts/Panel";
import { Heatmap } from "@/components/charts/Heatmap";
import { BarList } from "@/components/charts/BarList";
import { PhaseBar } from "@/components/charts/PhaseBar";
import { RunList } from "@/components/telemetry/RunList";
import { DataTable } from "@/components/ui/DataTable";
import { Failures } from "@/components/ui/Failures";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import type { Column, SortState } from "@/lib/dataTable";
import { useGlassBatch } from "@/lib/glassQuery";
import { useScope } from "@/lib/scope";
import { useScopedNavigate } from "@/lib/scopeHref";
import { useExploreHref, term } from "@/lib/explore";
import { formatCount, formatMs, formatPercent, formatUsd, num, optionalNum } from "@/lib/format";
import { tableToBars } from "@/lib/bars";
import { PHASE_COMPUTES } from "@/lib/runs";
import type { App, HeatmapResult, ListResult, TableResult, TransactionRow } from "@/types";
import { figureColumn } from "@/lib/ranked";
import { phasesOf } from "@/pages/app/harness/shared";

/** A harness's runs by agent and channel: how long they take, what they cost, which stopped short or waited longest on a person. */

interface AgentRow {
  key: string;
  name: string;
  channel: string | null;
  trigger: string | null;
  count: number;
  p50: number;
  p95: number;
  ttft: number | null;
  wait: number;
  cost: number;
  errorRate: number;
  untracked: number;
  phases: ReturnType<typeof phasesOf>;
}

export function InteractionsTab({ app }: { app: App }) {
  const explore = useExploreHref();
  const scope = useScope();
  const { live } = scope;
  const navigate = useScopedNavigate();
  const [sort, setSort] = useState<SortState>({ key: "count", direction: "desc" });
  const filter = `app:${app.slug} kind:run`;
  const { batch, answer, failures } = useGlassBatch(
    {
      agents: { source: "transactions", shape: "table", filter, group_by: ["name", "channel", "trigger"], limit: 100, compute: ["count", "p50(active)", "p95(active)", "p95(ttft)", "avg(wait)", "sum(cost)", "error_rate", "ratio(untracked, duration)", ...PHASE_COMPUTES] },
      heatmap: { source: "transactions", shape: "heatmap", filter, field: "active" },
      slowest: { source: "transactions", shape: "list", filter, order: "-active", limit: 15 },
      stopped: { source: "transactions", shape: "table", filter: `${filter} -stop:ok`, group_by: ["stop"], compute: ["count"], limit: 8 },
      waits: { source: "transactions", shape: "list", filter: `${filter} wait:>0`, order: "-wait", limit: 8 },
    },
    { live },
  );
  const rows = useMemo<AgentRow[]>(
    () =>
      (answer<TableResult>("agents")?.rows ?? []).map((row) => ({
        key: `${row.name}|${row.channel}|${row.trigger}`,
        name: String(row.name),
        channel: (row.channel as string | null) ?? null,
        trigger: (row.trigger as string | null) ?? null,
        count: num(row.count),
        p50: num(row["p50(active)"]),
        p95: num(row["p95(active)"]),
        ttft: optionalNum(row["p95(ttft)"]),
        wait: num(row["avg(wait)"]),
        cost: num(row["sum(cost)"]),
        errorRate: num(row.error_rate),
        untracked: num(row["ratio(untracked, duration)"]),
        phases: phasesOf(row),
      })),
    [answer],
  );
  const rowsFilter = (row: AgentRow) => [filter, term("name", row.name), term("channel", row.channel), term("trigger", row.trigger)].join(" ");

  const columns = useMemo<Column<AgentRow>[]>(() => [
    {
      key: "name",
      header: "Agent",
      cell: (row) => (
        <span className="whitespace-nowrap font-mono text-[13px] text-foreground">
          {row.name}
          {/* On a phone the "where" column is folded in here. */}
          <span className="block font-sans text-xs text-muted md:hidden">{row.channel ?? row.trigger ?? ""}</span>
        </span>
      ),
      sortValue: (row) => row.name,
    },
    { key: "channel", header: "Where", cell: (row) => <span className="text-xs text-muted">{row.channel ?? row.trigger ?? "—"}</span>, sortValue: (row) => row.channel ?? row.trigger, className: "w-24", tier: "tablet" },
    { key: "phases", header: "Where the time goes", cell: (row) => <PhaseBar parts={row.phases} format={formatMs} legend={false} height="h-2" />, className: "w-56", tier: "tablet" },
    figureColumn("count", "Runs", (row) => row.count, formatCount),
    figureColumn("p50", "p50", (row) => row.p50, formatMs, { tier: "tablet" }),
    figureColumn("p95", "p95", (row) => row.p95, formatMs),
    figureColumn("ttft", "First text p95", (row) => row.ttft, formatMs, { muted: true, width: "w-28", tier: "desktop" }),
    figureColumn("wait", "Waiting", (row) => row.wait, (value) => (value > 0 ? formatMs(value) : "—"), { muted: true, width: "w-24", tier: "desktop" }),
    figureColumn("cost", "Spent", (row) => row.cost, formatUsd),
    figureColumn("errors", "Errors", (row) => row.errorRate, formatPercent, { tier: "tablet", tone: (row) => row.errorRate > 0.05 && "text-negative" }),
    figureColumn("untracked", "Untracked", (row) => row.untracked, formatPercent, { width: "w-24", tier: "desktop", tone: (row) => (row.untracked > 0.1 ? "text-warning" : "text-muted") }),
  ], []);

  return (
    <QueryState
      query={batch}
      errorMessage="Couldn't load the runs."
      isEmpty={() => rows.length === 0}
      empty={failures.length > 0 ? <Failures messages={failures} /> : <EmptyState title="No runs in this range" description="Widen the time range, or check the harness is reporting." />}
    >
      {() => (
        <div className="space-y-4">
          <Failures messages={failures} />
          <p className="text-xs text-muted">Durations are active time: a run's duration less the time it spent waiting on a person. Phases are means per run.</p>
          <DataTable
            caption="Runs by agent and where they came from"
            columns={columns}
            rows={rows}
            rowKey={(row) => row.key}
            sort={sort}
            onSortChange={setSort}
            fluid
            detail={(row) => (
              <div className="flex flex-wrap items-center gap-4">
                <PhaseBar parts={row.phases} format={formatMs} className="min-w-64 flex-1" />
                <button type="button" className="text-xs text-primary hover:underline" onClick={() => navigate(explore({ shape: "list", filter: rowsFilter(row) }))}>
                  Every run
                </button>
                <button type="button" className="text-xs text-primary hover:underline" onClick={() => navigate(explore({ shape: "list", filter: `${rowsFilter(row)} status:error` }))}>
                  Errors
                </button>
              </div>
            )}
          />
          <div className="grid gap-3 lg:grid-cols-3">
            <Panel title="How long a run takes, over time" subtitle="active time — click a cell for the runs in it" className="lg:col-span-2">
              <QueryBody query={batch} height={180} isEmpty={() => (answer<HeatmapResult>("heatmap")?.cells.length ?? 0) === 0}>
                {() => {
                  const result = answer<HeatmapResult>("heatmap");
                  return result ? (
                    <Heatmap result={result} height={180} onCell={(from, to, low, high) => navigate(explore({ shape: "list", filter: `${filter} active:${low.toFixed(1)}..${high.toFixed(1)}` }, { range: `${Math.floor(from)}-${Math.ceil(to)}` }))} />
                  ) : null;
                }}
              </QueryBody>
            </Panel>
            <Panel title="Stopped short" subtitle="runs that did not end with an answer">
              <QueryBody query={batch} height={120}>
                {() => (
                  <BarList
                    rows={tableToBars(answer<TableResult>("stopped"), {
                      key: "stop",
                      measure: "count",
                      format: formatCount,
                      label: (row) => String(row.stop ?? "(unknown)"),
                      href: (row) => explore({ shape: "list", filter: `${filter} ${term("stop", row.stop as string)}` }),
                    })}
                    emptyLabel="Every run ended with an answer"
                  />
                )}
              </QueryBody>
            </Panel>
          </div>
          <div className="grid gap-3 lg:grid-cols-2">
            <Panel title="Slowest" subtitle="by active time">
              <QueryBody query={batch} height={120}>{() => <RunList rows={(answer<ListResult>("slowest")?.rows ?? []) as unknown as TransactionRow[]} />}</QueryBody>
            </Panel>
            <Panel title="Longest waits on a person" subtitle="an approval, a question — not the harness's time, but somebody's">
              <QueryBody query={batch} height={120}>{() => <RunList rows={(answer<ListResult>("waits")?.rows ?? []) as unknown as TransactionRow[]} emptyLabel="Nothing waited on a person in this range" />}</QueryBody>
            </Panel>
          </div>
        </div>
      )}
    </QueryState>
  );
}
