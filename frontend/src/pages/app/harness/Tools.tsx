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
import { formatCount, formatMs, formatPercent, num } from "@/lib/format";
import { tableToBars } from "@/lib/bars";
import { Meter } from "@/components/ui/Meter";
import type { App, TableResult } from "@/types";
import { figure, figureColumn, rankedRows, type Ranked } from "@/lib/ranked";

/** The tools a harness's runs called, and what they waited on: a person's approval, a cold sandbox, the turn ahead. */

interface ToolRow extends Ranked {
  name: string;
  count: number;
  errorRate: number;
  p50: number;
  p95: number;
}

export function ToolsTab({ app }: { app: App }) {
  const explore = useExploreHref();
  const scope = useScope();
  const { live } = scope;
  const navigate = useScopedNavigate();
  const [sort, setSort] = useState<SortState>({ key: "total", direction: "desc" });
  const base = `app:${app.slug}`;
  const glass = useGlassBatch(
    {
      tools: { source: "spans", shape: "table", filter: `${base} kind:tool`, group_by: ["name"], limit: 200, compute: ["count", "error_rate", "p50(duration)", "p95(duration)", "sum(duration)"] },
      waits: { source: "spans", shape: "table", filter: `${base} kind:wait`, group_by: ["@status"], compute: ["count", "p50(duration)", "p95(duration)", "sum(duration)"], limit: 6 },
      cold: { source: "spans", shape: "table", filter: `${base} kind:sandbox name:start`, compute: ["count", "p50(duration)", "p95(duration)", "sum(duration)"] },
      calls: { source: "spans", shape: "timeseries", filter: `${base} kind:tool`, compute: ["count", "errors"] },
      queued: { source: "spans", shape: "table", filter: `${base} kind:queue`, compute: ["count", "p50(duration)", "p95(duration)"], group_by: ["@behind"], limit: 4 },
    },
    { live },
  );
  const { batch, answer, failures } = glass;
  const rows = useMemo<ToolRow[]>(
    () =>
      rankedRows(answer<TableResult>("tools")?.rows, "sum(duration)", (row) => ({
        name: String(row.name),
        count: num(row.count),
        errorRate: num(row.error_rate),
        p50: num(row["p50(duration)"]),
        p95: num(row["p95(duration)"]),
      })),
    [answer],
  );
  const cold = answer<TableResult>("cold")?.rows[0];

  const columns = useMemo<Column<ToolRow>[]>(() => [
    { key: "name", header: "Tool", cell: (row) => <span className="font-mono text-[13px] text-foreground">{row.name}</span>, sortValue: (row) => row.name },
    {
      key: "total",
      header: "Time consumed",
      cell: (row) => (
        <span className="flex items-center gap-2">
          <Meter value={row.share} floor={0.01} className="hidden md:block" />
          <span className={figure}>{formatMs(row.total)}</span>
        </span>
      ),
      sortValue: (row) => row.total,
      className: "md:w-48",
    },
    figureColumn("count", "Calls", (row) => row.count, formatCount),
    figureColumn("p50", "p50", (row) => row.p50, formatMs, { tier: "tablet" }),
    figureColumn("p95", "p95", (row) => row.p95, formatMs),
    figureColumn("errors", "Failed", (row) => row.errorRate, formatPercent, { tone: (row) => row.errorRate > 0.05 && "text-negative" }),
  ], []);

  return (
    <QueryState
      query={batch}
      errorMessage="Couldn't load the tool calls."
      isEmpty={() => rows.length === 0}
      empty={failures.length > 0 ? <Failures messages={failures} /> : <EmptyState title="No tool calls in this range" description="Tool calls are the tool spans of runs; widen the range, or check the harness is reporting." />}
    >
      {() => (
        <div className="space-y-4">
          <Failures messages={failures} />
          <p className="text-xs text-muted">A tool's time here includes its gate — a reviewer, an approval, a container starting. The panels below take those apart.</p>
          <DataTable
            caption="Tools ranked by time consumed"
            columns={columns}
            rows={rows}
            rowKey={(row) => row.name}
            sort={sort}
            onSortChange={setSort}
            fluid
            detail={(row) => (
              <div className="flex gap-4">
                <button type="button" className="text-xs text-primary hover:underline" onClick={() => navigate(explore({ source: "spans", shape: "list", filter: `${base} kind:tool ${term("name", row.name)}` }))}>
                  Every call
                </button>
                <button type="button" className="text-xs text-primary hover:underline" onClick={() => navigate(explore({ source: "spans", shape: "list", filter: `${base} kind:tool status:error ${term("name", row.name)}` }))}>
                  Failures
                </button>
              </div>
            )}
          />
          <div className="grid gap-3 lg:grid-cols-3">
            <Panel title="Waiting on a person" subtitle="approvals, by how they ended">
              <QueryBody query={batch} height={110}>
                {() => (
                  <BarList
                    rows={tableToBars(answer<TableResult>("waits"), {
                      key: "@status",
                      measure: "sum(duration)",
                      format: formatMs,
                      label: (row) => String(row["@status"] ?? "(unanswered)"),
                      display: (row) => formatMs(num(row["p50(duration)"])),
                      secondary: (row) => `${formatCount(num(row.count))}×`,
                      href: (row) => explore({ source: "spans", shape: "list", filter: `${base} kind:wait ${term("@status", row["@status"] as string)}` }),
                    })}
                    emptyLabel="Nothing waited on a person"
                  />
                )}
              </QueryBody>
            </Panel>
            <Panel title="Cold containers" subtitle="the first shell of a conversation starts its sandbox">
              <QueryBody query={batch} height={110}>
                {() =>
                  num(cold?.count) === 0 ? (
                    <p className="py-4 text-center text-xs text-muted">No container started in this range</p>
                  ) : (
                    <dl className="tabular grid grid-cols-3 gap-2 text-xs">
                      {[
                        ["starts", formatCount(num(cold?.count))],
                        ["p50", formatMs(num(cold?.["p50(duration)"]))],
                        ["p95", formatMs(num(cold?.["p95(duration)"]))],
                      ].map(([label, value]) => (
                        <div key={label}>
                          <dt className="text-muted">{label}</dt>
                          <dd className="font-mono text-lg text-foreground">{value}</dd>
                        </div>
                      ))}
                      <dd className="col-span-3">
                        <ScopedLink className="text-primary hover:underline" to={explore({ source: "spans", shape: "list", filter: `${base} kind:sandbox name:start` })}>
                          Every start
                        </ScopedLink>
                      </dd>
                    </dl>
                  )
                }
              </QueryBody>
            </Panel>
            <Panel title="Waiting for the conversation" subtitle="turns that queued, by what they were behind">
              <QueryBody query={batch} height={110}>
                {() => (
                  <BarList
                    rows={tableToBars(answer<TableResult>("queued"), {
                      key: "@behind",
                      measure: "count",
                      format: formatCount,
                      label: (row) => `behind a ${row["@behind"] ?? "turn"}`,
                      display: (row) => formatMs(num(row["p50(duration)"])),
                      secondary: (row) => `${formatCount(num(row.count))}×`,
                      href: () => explore({ source: "spans", shape: "list", filter: `${base} kind:queue` }),
                    })}
                    emptyLabel="Nothing queued in this range"
                  />
                )}
              </QueryBody>
            </Panel>
          </div>
          <Panel title="Tool calls" subtitle="calls and failures per bucket">
            <BatchTimeseries batch={glass} answer="calls" markersFor={app.slug} height={120} />
          </Panel>
        </div>
      )}
    </QueryState>
  );
}
