import { useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { Panel, QueryBody } from "@/components/charts/Panel";
import { BatchTimeseries } from "@/components/charts/BatchTimeseries";
import { useGlassBatch } from "@/lib/glassQuery";
import { DataTable } from "@/components/ui/DataTable";
import { Failures } from "@/components/ui/Failures";
import { useScope, withScope } from "@/lib/scope";
import { formatCount, formatMs, num } from "@/lib/format";
import { cn } from "@/lib/cn";
import { term, useExploreHref } from "@/lib/explore";
import type { Column, SortState } from "@/lib/dataTable";
import type { CellValue, TableResult } from "@/types";

interface VitalsRow {
  route: CellValue;
  lcp: number;
  inp: number;
  cls: number;
  ttfb: number;
  pages: number;
}

const grade = (value: number, good: number, poor: number) => (value <= good ? "text-positive" : value <= poor ? "text-warning" : "text-negative");

/** How fast pages feel: the web vitals at p75, by device and by route. */
export function VitalsTab() {
  const scope = useScope();
  const glass = useGlassBatch(
    {
      routes: { source: "page_events", shape: "table", filter: withScope(scope, "kind:vital"), compute: ["p75(lcp)", "p75(inp)", "p75(cls)", "p75(ttfb)", "count"], group_by: ["route"], limit: 30 },
      lcp: { source: "page_events", shape: "timeseries", filter: withScope(scope, "kind:vital"), compute: ["p75(lcp)"], group_by: ["device"], limit: 3 },
      inp: { source: "page_events", shape: "timeseries", filter: withScope(scope, "kind:vital"), compute: ["p75(inp)"], group_by: ["device"], limit: 3 },
    },
    { live: scope.live },
  );
  const { batch, answer, failures } = glass;
  const table = answer<TableResult>("routes");
  return (
    <div className="space-y-3">
      <Failures messages={failures} />
      <div className="grid gap-3 lg:grid-cols-2">
        <Panel title="Largest contentful paint" subtitle="p75, by device — good under 2.5 s">
          <BatchTimeseries batch={glass} answer="lcp" height={140} />
        </Panel>
        <Panel title="Interaction to next paint" subtitle="p75, by device — good under 200 ms">
          <BatchTimeseries batch={glass} answer="inp" height={140} />
        </Panel>
      </div>
      <Panel title="By route" subtitle="p75 of each vital" bodyClassName="p-0">
        <QueryBody query={batch} height={200} isEmpty={() => (table?.rows.length ?? 0) === 0}>
          {() => <VitalsTable rows={table?.rows ?? []} />}
        </QueryBody>
      </Panel>
    </div>
  );
}

/** Each route's vitals at p75; a route opens its vital events in the Explorer. */
function VitalsTable({ rows }: { rows: TableResult["rows"] }) {
  const explore = useExploreHref();
  const [sort, setSort] = useState<SortState>({ key: "pages", direction: "desc" });
  const vitals = useMemo<VitalsRow[]>(
    () =>
      rows.map((row) => ({
        route: row.route ?? null,
        lcp: num(row["p75(lcp)"]),
        inp: num(row["p75(inp)"]),
        cls: num(row["p75(cls)"]),
        ttfb: num(row["p75(ttfb)"]),
        pages: num(row.count),
      })),
    [rows],
  );
  const columns = useMemo<Column<VitalsRow>[]>(
    () => [
      {
        key: "route",
        header: "Route",
        sortValue: (row) => (row.route === null ? null : String(row.route)),
        cell: (row) => (
          <Link to={explore({ source: "page_events", shape: "list", filter: `kind:vital ${term("route", row.route)}` })} className="block truncate font-mono text-[13px] text-foreground hover:text-primary">
            {String(row.route ?? "(none)")}
          </Link>
        ),
      },
      { key: "lcp", header: "LCP", className: "w-20 text-right", sortValue: (row) => row.lcp, cell: (row) => <span className={cn("tabular font-mono", grade(row.lcp, 2500, 4000))}>{formatMs(row.lcp)}</span> },
      { key: "inp", header: "INP", className: "w-20 text-right", sortValue: (row) => row.inp, cell: (row) => <span className={cn("tabular font-mono", grade(row.inp, 200, 500))}>{formatMs(row.inp)}</span> },
      { key: "cls", header: "CLS", className: "w-20 text-right", tier: "tablet", sortValue: (row) => row.cls, cell: (row) => <span className={cn("tabular font-mono", grade(row.cls, 0.1, 0.25))}>{row.cls.toFixed(3)}</span> },
      { key: "ttfb", header: "TTFB", className: "w-20 text-right", tier: "tablet", sortValue: (row) => row.ttfb, cell: (row) => <span className="tabular font-mono">{formatMs(row.ttfb)}</span> },
      { key: "pages", header: "Pages", className: "w-20 text-right", sortValue: (row) => row.pages, cell: (row) => <span className="tabular font-mono text-muted">{formatCount(row.pages)}</span> },
    ],
    [explore],
  );
  return <DataTable caption="Web vitals by route, p75" columns={columns} rows={vitals} rowKey={(row) => String(row.route)} sort={sort} onSortChange={setSort} fluid />;
}
