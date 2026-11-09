import { useMemo, useState } from "react";
import { DataTable } from "@/components/ui/DataTable";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import type { Column, SortState } from "@/lib/dataTable";
import { useGlassQuery } from "@/lib/glassQuery";
import { Meter } from "@/components/ui/Meter";
import { useScope } from "@/lib/scope";
import { useScopedNavigate } from "@/lib/scopeHref";
import { formatCount, formatMs, formatPercent, formatRate, num } from "@/lib/format";
import { figure, figureColumn, rankedRows, type Ranked } from "@/lib/ranked";
import type { App, TableResult } from "@/types";
import { SHEET_PATHS } from "@/pages/app/shared";


/** An app's endpoints or jobs as a table; a row opens its detail beside the list. */

interface TxnRow extends Ranked {
  name: string;
  count: number;
  rate: number;
  p50: number;
  p95: number;
  errorRate: number;
  db: number;
}

export function TransactionsTab({ app, kind }: { app: App; kind: "request" | "job" }) {
  const scope = useScope();
  const navigate = useScopedNavigate();
  const [sort, setSort] = useState<SortState>({ key: "total", direction: "desc" });
  const query = useGlassQuery<TableResult>(
    {
      source: "transactions",
      shape: "table",
      from: scope.range.from,
      to: scope.range.to,
      filter: `app:${app.slug} kind:${kind}`,
      compute: ["count", "rate", "p50(duration)", "p95(duration)", "error_rate", "sum(duration)", "avg(db)", "sum(db_count)"],
      group_by: ["name"],
      limit: 200,
    },
    { live: scope.live },
  );
  const rows = useMemo<TxnRow[]>(
    () =>
      rankedRows(query.data?.rows, "sum(duration)", (row) => ({
        name: String(row.name),
        count: num(row.count),
        rate: num(row.rate),
        p50: num(row["p50(duration)"]),
        p95: num(row["p95(duration)"]),
        errorRate: num(row.error_rate),
        db: num(row["avg(db)"]),
      })),
    [query.data],
  );

  const columns = useMemo<Column<TxnRow>[]>(() => [
    { key: "name", header: kind === "request" ? "Endpoint" : "Job", cell: (row) => <span className="font-mono text-[13px] text-foreground">{row.name}</span>, sortValue: (row) => row.name },
    {
      key: "total",
      header: "Time consumed",
      cell: (row) => (
        <span className="flex items-center gap-2">
          <Meter value={row.share} floor={0.01} />
          <span className={figure}>{formatMs(row.total)}</span>
          <span className="tabular text-xs text-muted">{formatPercent(row.share, 0)}</span>
        </span>
      ),
      sortValue: (row) => row.total,
      className: "w-56",
    },
    figureColumn("count", kind === "request" ? "Requests" : "Runs", (row) => row.count, formatCount, { width: "w-24" }),
    figureColumn("rate", "Rate", (row) => row.rate, formatRate, { width: "w-24" }),
    figureColumn("p50", "p50", (row) => row.p50, formatMs),
    figureColumn("p95", "p95", (row) => row.p95, formatMs),
    figureColumn("errors", "Errors", (row) => row.errorRate, formatPercent, { tone: (row) => row.errorRate > 0.02 && "text-negative" }),
    figureColumn("db", "DB", (row) => row.db, formatMs, { muted: true }),
  ], [kind]);

  return (
    <QueryState
      query={query}
      errorMessage="Couldn't load the list."
      isEmpty={() => rows.length === 0}
      empty={<EmptyState title={kind === "request" ? "No requests in this range" : "No jobs in this range"} description="Widen the time range, or check the app is reporting." />}
    >
      {() => (
        <DataTable
          caption={kind === "request" ? "Endpoints ranked by time consumed" : "Jobs ranked by time consumed"}
          columns={columns}
          rows={rows}
          rowKey={(row) => row.name}
          sort={sort}
          onSortChange={setSort}
          fluid
          rowClassName={() => "cursor-pointer hover:bg-surface-raised"}
          detail={(row) => (
            <button type="button" className="text-xs text-primary hover:underline" onClick={() => navigate(`/apps/${app.slug}/${SHEET_PATHS[kind]}/${encodeURIComponent(row.name)}`)}>
              Open {row.name}
            </button>
          )}
        />
      )}
    </QueryState>
  );
}
