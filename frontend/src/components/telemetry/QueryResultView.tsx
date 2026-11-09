import { useNavigate } from "react-router-dom";
import { Timeseries } from "@/components/charts/Timeseries";
import { Heatmap } from "@/components/charts/Heatmap";
import { Histogram } from "@/components/charts/Histogram";
import { BarList } from "@/components/charts/BarList";
import { ScopedLink } from "@/components/scope/ScopedLink";
import { useApps } from "@/hooks/useApps";
import { LogLines } from "@/components/telemetry/LogLines";
import { TransactionList } from "@/components/telemetry/TransactionList";
import { VisitList, type VisitRow } from "@/pages/visitors/Live";
import { useNow } from "@/hooks/useNow";
import { tableToBars } from "@/lib/bars";
import { cn } from "@/lib/cn";
import { narrow, rangeParam, useExploreHref, type ExploreState } from "@/lib/explore";
import { formatDateTime, formatUnit } from "@/lib/format";
import { useMarkers } from "@/lib/markers";
import { useScope } from "@/lib/scope";
import { useScopedNavigate } from "@/lib/scopeHref";
import { absoluteRange } from "@/lib/timeRange";
import type { CellValue, LogRow, QueryResult, QuerySource, TableResult, TransactionRow } from "@/types";

/**
 * An Explorer query's answer drawn — in the Explorer and on a dashboard
 * alike. Every number leads to its rows: a point, a bar, a cell or a bucket
 * opens the Explorer with exactly that filter and range; brushing asks the
 * scope for a new range. `fill` sizes it to its box (a dashboard cell).
 */
export function QueryResultView({ state, data, height, fill = false }: { state: ExploreState; data: QueryResult; height: number; fill?: boolean }) {
  const scope = useScope();
  const apps = useApps();
  const markers = useMarkers(scope.range, scope.app, scope.live);
  const explore = useExploreHref();
  const navigate = useNavigate();
  // A metric has no rows to list; its narrowed chart is as close as it gets.
  const rowsOf = (next: ExploreState): ExploreState => (next.source === "metrics" ? next : { ...next, shape: "list" });
  const between = (low: number, high: number) => ({ ...rowsOf(state), filter: `${state.filter} ${state.field}:${low.toFixed(1)}..${high.toFixed(1)}`.trim() });

  switch (data.shape) {
    case "timeseries":
      return (
        <Timeseries
          result={data}
          apps={apps.data}
          markers={markers.data}
          height={height}
          fill={fill}
          onBrush={(from, to) => scope.setRange(absoluteRange(from, to))}
          onPoint={(time, step, series) => void navigate(explore(rowsOf(narrow(state, series.group)), rangeParam(time, time + step)))}
          fromZero={data.kind !== "gauge"}
        />
      );
    case "table":
      return <ResultTable data={data} fill={fill} rowsHref={explore(rowsOf(state))} groupHref={(group) => explore(narrow(state, group))} />;
    case "heatmap":
      return <Heatmap result={data} height={height} onCell={(from, to, low, high) => void navigate(explore(between(low, high), rangeParam(from, to)))} />;
    case "histogram":
      return <Histogram result={data} height={height} onBucket={(low, high) => void navigate(explore(between(low, high)))} />;
    case "list":
      return (
        <div className={cn(fill && "h-full overflow-y-auto")}>
          <ResultList source={state.source} rows={data.rows} />
        </div>
      );
  }
}

function ResultTable({
  data,
  fill,
  rowsHref,
  groupHref,
}: {
  data: TableResult;
  fill: boolean;
  rowsHref: string;
  groupHref: (group: Record<string, CellValue>) => string;
}) {
  const dimensions = data.columns.filter((column) => column.kind === "dimension");
  const measures = data.columns.filter((column) => column.kind === "measure");
  const groupOf = (row: Record<string, unknown>) => Object.fromEntries(dimensions.map((dimension) => [dimension.key, (row[dimension.key] ?? null) as CellValue]));
  if (dimensions.length === 0 && measures.length === 1 && data.rows.length <= 1) {
    const measure = measures[0]!;
    return (
      <ScopedLink to={rowsHref} className={cn("tabular flex items-center justify-center py-6 font-mono text-3xl text-foreground hover:text-primary", fill && "h-full py-0")}>
        {formatUnit(Number(data.rows[0]?.[measure.key] ?? 0), measure.unit)}
      </ScopedLink>
    );
  }
  if (dimensions.length === 1 && measures.length === 1) {
    const dimension = dimensions[0]!;
    const measure = measures[0]!;
    return (
      <BarList
        className={cn(fill && "h-full overflow-y-auto")}
        rows={tableToBars(data, { key: dimension.key, measure: measure.key, format: (value) => formatUnit(value, measure.unit), href: (row) => groupHref(groupOf(row)) })}
      />
    );
  }
  return (
    <div className={cn("overflow-x-auto", fill && "h-full overflow-y-auto")}>
      <table className="w-full text-[13px]">
        <thead>
          <tr className="text-left text-[11px] uppercase tracking-wider text-muted">
            {data.columns.map((column) => (
              <th key={column.key} className={cn("px-2 py-1 font-semibold", column.kind === "measure" && "text-right")}>
                {column.key}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {data.rows.map((row, index) => (
            <tr key={index} className="border-t border-border hover:bg-surface-raised">
              {data.columns.map((column) => (
                <td key={column.key} className={cn("px-2 py-1", column.kind === "measure" ? "tabular text-right font-mono" : "font-mono")}>
                  <ScopedLink to={groupHref(groupOf(row))} className="text-foreground hover:text-primary">
                    {column.kind === "measure" ? formatUnit(Number(row[column.key] ?? 0), column.unit) : row[column.key] === null ? "(none)" : String(row[column.key])}
                  </ScopedLink>
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** Rows drawn the way their source's own page draws them. */
function ResultList({ source, rows }: { source: QuerySource; rows: Record<string, unknown>[] }) {
  const apps = useApps();
  const navigate = useScopedNavigate();
  const now = useNow();
  switch (source) {
    case "transactions":
      return <TransactionList rows={rows as unknown as TransactionRow[]} apps={apps.data} />;
    case "logs":
      return <LogLines rows={rows as unknown as LogRow[]} apps={apps.data} />;
    case "visits":
      return <VisitList rows={rows as unknown as VisitRow[]} apps={apps.data} onOpen={(visit) => navigate(`/visitors/live/${visit}`)} now={now} />;
    default:
      return <RowTable rows={rows} />;
  }
}

function RowTable({ rows }: { rows: Record<string, unknown>[] }) {
  const first = rows[0];
  const columns = first ? Object.keys(first).filter((key) => key !== "attrs") : [];
  return (
    <div className="overflow-x-auto">
      <table className="w-full font-mono text-xs">
        <thead>
          <tr className="text-left text-[11px] uppercase tracking-wider text-muted">
            {columns.map((column) => (
              <th key={column} className="px-2 py-1 font-semibold">
                {column}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, index) => (
            <tr key={index} className="border-t border-border">
              {columns.map((column) => (
                <td key={column} className="max-w-72 truncate px-2 py-1 text-foreground">
                  {column === "ts" ? formatDateTime(Number(row.ts)) : String(row[column] ?? "")}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
