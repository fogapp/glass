import { useMemo, useState } from "react";
import { Panel, QueryBody } from "@/components/charts/Panel";
import { BatchTimeseries } from "@/components/charts/BatchTimeseries";
import { BarList } from "@/components/charts/BarList";
import { DataTable } from "@/components/ui/DataTable";
import { Failures } from "@/components/ui/Failures";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import type { Column, SortState } from "@/lib/dataTable";
import { useGlassBatch } from "@/lib/glassQuery";
import { useScope } from "@/lib/scope";
import { useScopedNavigate } from "@/lib/scopeHref";
import { ScopedLink } from "@/components/scope/ScopedLink";
import { useExploreHref, term } from "@/lib/explore";
import { formatCount, formatMs, formatPercent, formatUsd, num, optionalNum } from "@/lib/format";
import { tableToBars } from "@/lib/bars";
import { Meter } from "@/components/ui/Meter";
import { cn } from "@/lib/cn";
import type { App, TableResult } from "@/types";
import { figure, figureColumn, rankedRows, type Ranked } from "@/lib/ranked";

/** The model calls a harness made: by provider and model, their latency, tokens and spend. */

interface ModelRow extends Ranked {
  key: string;
  provider: string;
  model: string;
  calls: number;
  p50: number;
  p95: number;
  ttft: number | null;
  speed: number | null;
  cached: number | null;
  errorRate: number;
  tokensIn: number;
  tokensOut: number;
}

export function ModelsTab({ app }: { app: App }) {
  const explore = useExploreHref();
  const scope = useScope();
  const { live } = scope;
  const navigate = useScopedNavigate();
  const [sort, setSort] = useState<SortState>({ key: "cost", direction: "desc" });
  const filter = `app:${app.slug} -origin:eval`;
  const glass = useGlassBatch(
    {
      models: { source: "model_calls", shape: "table", filter, group_by: ["provider", "model"], limit: 50, compute: ["count", "sum(cost)", "p50(duration)", "p95(duration)", "p95(ttft)", "avg(tokens_per_s)", "ratio(cache_read, input_total)", "error_rate", "sum(input_total)", "sum(tokens_out)"] },
      spend: { source: "model_calls", shape: "timeseries", filter, compute: ["sum(cost)"], group_by: ["model"], limit: 6 },
      cache: { source: "model_calls", shape: "timeseries", filter: `${filter} cost_source:estimated,reported`, compute: ["ratio(cache_read, input_total)"], group_by: ["model"], limit: 6 },
      ttft: { source: "model_calls", shape: "timeseries", filter: `${filter} purpose:turn`, compute: ["p95(ttft)"], group_by: ["model"], limit: 6 },
      purposes: { source: "model_calls", shape: "table", filter, group_by: ["purpose"], compute: ["sum(cost)", "count", "sum(duration)"], limit: 12 },
      failed: { source: "model_calls", shape: "table", filter: `${filter} status:error`, group_by: ["error", "model"], compute: ["count"], limit: 8 },
      evals: { source: "model_calls", shape: "table", filter: `app:${app.slug} origin:eval`, compute: ["count", "sum(cost)"] },
    },
    { live },
  );
  const { batch, answer, failures } = glass;
  // Ranked by spend: `total` is USD.
  const rows = useMemo<ModelRow[]>(
    () =>
      rankedRows(answer<TableResult>("models")?.rows, "sum(cost)", (row) => ({
        key: `${row.provider}|${row.model}`,
        provider: String(row.provider),
        model: String(row.model),
        calls: num(row.count),
        p50: num(row["p50(duration)"]),
        p95: num(row["p95(duration)"]),
        ttft: optionalNum(row["p95(ttft)"]),
        speed: optionalNum(row["avg(tokens_per_s)"]),
        cached: optionalNum(row["ratio(cache_read, input_total)"]),
        errorRate: num(row.error_rate),
        tokensIn: num(row["sum(input_total)"]),
        tokensOut: num(row["sum(tokens_out)"]),
      })),
    [answer],
  );
  const evals = answer<TableResult>("evals")?.rows[0];

  const columns = useMemo<Column<ModelRow>[]>(() => [
    {
      key: "model",
      header: "Model",
      cell: (row) => (
        <span className="font-mono text-[13px] text-foreground">
          {row.model} <span className="text-muted">· {row.provider}</span>
        </span>
      ),
      sortValue: (row) => row.model,
    },
    {
      key: "cost",
      header: "Spent",
      cell: (row) => (
        <span className="flex items-center gap-2">
          <Meter value={row.share} floor={row.total > 0 ? 0.01 : 0} className="hidden md:block" />
          <span className={figure}>{formatUsd(row.total)}</span>
        </span>
      ),
      sortValue: (row) => row.total,
      className: "md:w-44",
    },
    figureColumn("calls", "Calls", (row) => row.calls, formatCount, { tier: "tablet" }),
    { key: "tokens", header: "Tokens in → out", cell: (row) => <span className={cn(figure, "text-muted")}>{formatCount(row.tokensIn)} → {formatCount(row.tokensOut)}</span>, sortValue: (row) => row.tokensIn, className: "text-right w-36", tier: "desktop" },
    figureColumn("cached", "From cache", (row) => row.cached, (value) => formatPercent(value, 0), { width: "w-24", tier: "tablet" }),
    figureColumn("ttft", "First token p95", (row) => row.ttft, formatMs, { width: "w-28", tier: "tablet" }),
    figureColumn("p95", "p95", (row) => row.p95, formatMs),
    figureColumn("speed", "Tokens/s", (row) => row.speed, (value) => value.toFixed(0), { muted: true, tier: "desktop" }),
    figureColumn("errors", "Errors", (row) => row.errorRate, formatPercent, { tier: "tablet", tone: (row) => row.errorRate > 0.02 && "text-negative" }),
  ], []);

  return (
    <QueryState
      query={batch}
      errorMessage="Couldn't load the model calls."
      isEmpty={() => rows.length === 0}
      empty={failures.length > 0 ? <Failures messages={failures} /> : <EmptyState title="No model calls in this range" description="Every call is kept — none is sampled — so an empty list is an idle harness." />}
    >
      {() => (
        <div className="space-y-4">
          <Failures messages={failures} />
          <p className="text-xs text-muted">
            Every call is counted; none is sampled. Calls made by evals are left out
            {num(evals?.count) > 0 ? (
              <>
                {" "}
                (<ScopedLink className="text-primary hover:underline" to={explore({ source: "model_calls", shape: "table", filter: `app:${app.slug} origin:eval`, compute: ["sum(cost)", "count"], group_by: ["model"] })}>
                  {formatCount(num(evals?.count))} in range, {formatUsd(num(evals?.["sum(cost)"]))}
                </ScopedLink>
                )
              </>
            ) : null}
            .
          </p>
          <DataTable
            caption="Models ranked by spend"
            columns={columns}
            rows={rows}
            rowKey={(row) => row.key}
            sort={sort}
            onSortChange={setSort}
            fluid
            detail={(row) => (
              <div className="flex gap-4">
                <button type="button" className="text-xs text-primary hover:underline" onClick={() => navigate(explore({ source: "model_calls", shape: "list", filter: `${filter} ${term("model", row.model)} ${term("provider", row.provider)}` }))}>
                  Every call
                </button>
                <button type="button" className="text-xs text-primary hover:underline" onClick={() => navigate(explore({ source: "model_calls", shape: "table", filter: `${filter} ${term("model", row.model)}`, compute: ["sum(cost)", "count", "p95(ttft)"], group_by: ["purpose"] }))}>
                  By purpose
                </button>
              </div>
            )}
          />
          <div className="grid gap-3 lg:grid-cols-3">
            <Panel title="Spend" subtitle="USD per bucket, by model">
              <BatchTimeseries batch={glass} answer="spend" markersFor={app.slug} stacked />
            </Panel>
            <Panel title="Prompt cache" subtitle="share of input read from cache, metered models">
              <BatchTimeseries batch={glass} answer="cache" markersFor={app.slug} />
            </Panel>
            <Panel title="Time to first token" subtitle="p95, calls that answer a person">
              <BatchTimeseries batch={glass} answer="ttft" markersFor={app.slug} />
            </Panel>
          </div>
          <div className="grid gap-3 lg:grid-cols-2">
            <Panel title="Spend by purpose" subtitle="why a model was called — the overhead a turn does not show">
              <QueryBody query={batch} height={120}>
                {() => (
                  <BarList
                    rows={tableToBars(answer<TableResult>("purposes"), {
                      key: "purpose",
                      measure: "sum(cost)",
                      format: formatUsd,
                      label: (row) => String(row.purpose),
                      // An unmetered purpose still gets a sliver, by the time it took.
                      value: (row) => num(row["sum(cost)"]) || num(row["sum(duration)"]) / 1e9,
                      secondary: (row) => `${formatCount(num(row.count))}×`,
                      href: (row) => explore({ source: "model_calls", shape: "list", filter: `${filter} ${term("purpose", row.purpose as string)}` }),
                    })}
                  />
                )}
              </QueryBody>
            </Panel>
            <Panel title="Failed calls" subtitle="by class and model">
              <QueryBody query={batch} height={120}>
                {() => (
                  <BarList
                    rows={tableToBars(answer<TableResult>("failed"), {
                      key: (row) => `${row.error}|${row.model}`,
                      measure: "count",
                      format: formatCount,
                      label: (row) => `${row.error ?? "(unknown)"} · ${row.model ?? ""}`,
                      href: (row) => explore({ source: "model_calls", shape: "list", filter: `${filter} status:error ${term("error", row.error as string)}` }),
                    })}
                    emptyLabel="No call failed in this range"
                  />
                )}
              </QueryBody>
            </Panel>
          </div>
        </div>
      )}
    </QueryState>
  );
}
