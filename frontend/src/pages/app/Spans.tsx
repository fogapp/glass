import { useMemo, useState } from "react";
import { DataTable } from "@/components/ui/DataTable";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import type { Column, SortState } from "@/lib/dataTable";
import { useGlassQuery } from "@/lib/glassQuery";
import { useScope } from "@/lib/scope";
import { useScopedNavigate } from "@/lib/scopeHref";
import { useExploreHref, term } from "@/lib/explore";
import { formatCount, formatMs, formatPercent, num } from "@/lib/format";
import { figureColumn, rankedRows, type Ranked } from "@/lib/ranked";
import type { App, TableResult } from "@/types";

/** An app's queries or outbound calls, from the traces it kept. */

interface SpanRow extends Ranked {
  key: string;
  count: number;
  avg: number;
  p95: number;
  errorRate: number;
}

export function SpansTab({ app, kind }: { app: App; kind: "sql" | "http" }) {
  const explore = useExploreHref();
  const scope = useScope();
  const navigate = useScopedNavigate();
  const [sort, setSort] = useState<SortState>({ key: "total", direction: "desc" });
  const query = useGlassQuery<TableResult>(
    {
      source: "spans",
      shape: "table",
      from: scope.range.from,
      to: scope.range.to,
      filter: `app:${app.slug} kind:${kind}`,
      compute: ["count", "avg(duration)", "p95(duration)", "sum(duration)", "error_rate"],
      group_by: kind === "sql" ? ["resource"] : ["name"],
      limit: 200,
    },
    { live: scope.live },
  );
  const rows = useMemo<SpanRow[]>(
    () =>
      rankedRows(query.data?.rows, "sum(duration)", (row) => ({
        key: String(row.resource ?? row.name ?? ""),
        count: num(row.count),
        avg: num(row["avg(duration)"]),
        p95: num(row["p95(duration)"]),
        errorRate: num(row.error_rate),
      })),
    [query.data],
  );
  const columns = useMemo<Column<SpanRow>[]>(() => [
    { key: "key", header: kind === "sql" ? "Statement" : "Call", cell: (row) => <span className="line-clamp-2 break-all font-mono text-xs text-foreground">{row.key}</span>, sortValue: (row) => row.key },
    figureColumn("total", "Time consumed", (row) => row.total, formatMs, { width: "w-28" }),
    figureColumn("count", "Calls", (row) => row.count, formatCount),
    figureColumn("avg", "Mean", (row) => row.avg, formatMs),
    figureColumn("p95", "p95", (row) => row.p95, formatMs),
    figureColumn("errors", "Errors", (row) => row.errorRate, formatPercent, { tone: (row) => row.errorRate > 0 && "text-negative" }),
  ], [kind]);
  return (
    <QueryState
      query={query}
      errorMessage="Couldn't load the list."
      isEmpty={() => rows.length === 0}
      empty={<EmptyState title="Nothing in kept traces for this range" description="Spans come from traces the agent kept: errors, slow outliers, and a sample of the rest." />}
    >
      {() => (
        <div className="space-y-2">
          <p className="text-xs text-muted">From kept traces only — a sample, ranked by total time. Click a row to see the traces it appears in.</p>
          <DataTable
            caption={kind === "sql" ? "SQL statements by time consumed" : "Outbound calls by time consumed"}
            columns={columns}
            rows={rows}
            rowKey={(row) => row.key}
            sort={sort}
            onSortChange={setSort}
            fluid
            detail={(row) => (
              <button
                type="button"
                className="text-xs text-primary hover:underline"
                onClick={() => navigate(explore({ source: "spans", shape: "list", filter: `app:${app.slug} kind:${kind} ${term(kind === "sql" ? "resource" : "name", row.key)}` }))}
              >
                Show these spans
              </button>
            )}
          />
        </div>
      )}
    </QueryState>
  );
}
