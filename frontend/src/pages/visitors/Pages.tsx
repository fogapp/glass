import { useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { Panel, QueryBody } from "@/components/charts/Panel";
import { BatchTimeseries } from "@/components/charts/BatchTimeseries";
import { BarList } from "@/components/charts/BarList";
import { useGlassBatch } from "@/lib/glassQuery";
import { DataTable } from "@/components/ui/DataTable";
import { Failures } from "@/components/ui/Failures";
import { useScope, withScope } from "@/lib/scope";
import { useExploreHref, term } from "@/lib/explore";
import { formatCount, num } from "@/lib/format";
import { tableToBars } from "@/lib/bars";
import type { Column, SortState } from "@/lib/dataTable";
import type { CellValue, TableResult } from "@/types";

interface PageRow {
  route: CellValue;
  views: number;
  visits: number;
  visitors: number;
}

/** The pages visitors saw, by route. */
export function PagesTab() {
  const scope = useScope();
  const glass = useGlassBatch(
    {
      routes: { source: "page_events", shape: "table", filter: withScope(scope, "kind:pageview"), compute: ["count", "uniq(visit)", "uniq(visitor)"], group_by: ["route"], limit: 50 },
      entries: { source: "visits", shape: "table", filter: withScope(scope), compute: ["count"], group_by: ["entry_route"], limit: 10 },
      exits: { source: "visits", shape: "table", filter: withScope(scope), compute: ["count"], group_by: ["exit_path"], limit: 10 },
      trend: { source: "page_events", shape: "timeseries", filter: withScope(scope, "kind:pageview"), compute: ["count"], group_by: ["route"], limit: 6 },
    },
    { live: scope.live },
  );
  const { batch, answer, failures } = glass;
  const pages = answer<TableResult>("routes");
  return (
    <div className="space-y-3">
      <Failures messages={failures} />
      <Panel title="Pageviews over time" subtitle="by route">
        <BatchTimeseries batch={glass} answer="trend" stacked />
      </Panel>
      <div className="grid gap-3 lg:grid-cols-3">
        <Panel title="Pages" className="lg:col-span-2" bodyClassName="p-0">
          <QueryBody query={batch} height={200} isEmpty={() => (pages?.rows.length ?? 0) === 0}>
            {() => <PagesTable rows={pages?.rows ?? []} />}
          </QueryBody>
        </Panel>
        <div className="space-y-3">
          <Panel title="Entry pages">
            <QueryBody query={batch} height={100}>
              {() => <BarList rows={tableToBars(answer<TableResult>("entries"), { key: "entry_route", measure: "count", format: formatCount })} />}
            </QueryBody>
          </Panel>
          <Panel title="Exit pages">
            <QueryBody query={batch} height={100}>
              {() => <BarList rows={tableToBars(answer<TableResult>("exits"), { key: "exit_path", measure: "count", format: formatCount })} />}
            </QueryBody>
          </Panel>
        </div>
      </div>
    </div>
  );
}

/** Each route's views, visits and visitors; a route opens its pageviews in the Explorer. */
function PagesTable({ rows }: { rows: TableResult["rows"] }) {
  const explore = useExploreHref();
  const [sort, setSort] = useState<SortState>({ key: "views", direction: "desc" });
  const pages = useMemo<PageRow[]>(
    () => rows.map((row) => ({ route: row.route ?? null, views: num(row.count), visits: num(row["uniq(visit)"]), visitors: num(row["uniq(visitor)"]) })),
    [rows],
  );
  const columns = useMemo<Column<PageRow>[]>(
    () => [
      {
        key: "route",
        header: "Route",
        sortValue: (row) => (row.route === null ? null : String(row.route)),
        cell: (row) => (
          <Link
            to={explore({ source: "page_events", shape: "list", filter: `kind:pageview ${term("route", row.route)}` })}
            className="block truncate font-mono text-[13px] text-foreground hover:text-primary"
          >
            {String(row.route ?? "(none)")}
          </Link>
        ),
      },
      { key: "views", header: "Views", className: "w-24 text-right", sortValue: (row) => row.views, cell: (row) => <span className="tabular font-mono">{formatCount(row.views)}</span> },
      { key: "visits", header: "Visits", className: "w-24 text-right", tier: "tablet", sortValue: (row) => row.visits, cell: (row) => <span className="tabular font-mono">{formatCount(row.visits)}</span> },
      { key: "visitors", header: "Visitors", className: "w-24 text-right", sortValue: (row) => row.visitors, cell: (row) => <span className="tabular font-mono">{formatCount(row.visitors)}</span> },
    ],
    [explore],
  );
  return <DataTable caption="Pages by route" columns={columns} rows={pages} rowKey={(row) => String(row.route)} sort={sort} onSortChange={setSort} fluid />;
}
