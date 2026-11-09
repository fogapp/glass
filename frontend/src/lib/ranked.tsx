import type { Column, ColumnTier } from "@/lib/dataTable";
import { num } from "@/lib/format";
import { cn } from "@/lib/cn";
import type { CellValue } from "@/types";

/** A figure in a table cell: tabular, monospaced, a size under the body text. */
export const figure = "tabular font-mono text-[13px]";

/** What every ranked row carries: its part of the measure, and that part's share of the whole. */
export interface Ranked {
  total: number;
  share: number;
}

/**
 * The rows of a table answer ranked by what they consume — time, spend —
 * each with its `total` of `measure` and its `share` of all the rows' total
 * (the meter beside it). The answer comes ordered; this does not re-sort.
 */
export function rankedRows<R>(rows: readonly Record<string, CellValue>[] | undefined, measure: string, build: (row: Record<string, CellValue>) => R): (R & Ranked)[] {
  const list = rows ?? [];
  const grand = list.reduce((sum, row) => sum + num(row[measure]), 0) || 1;
  return list.map((row) => ({ ...build(row), total: num(row[measure]), share: num(row[measure]) / grand }));
}

/**
 * A right-aligned, sortable column of one figure. `tone` colours a cell
 * (`text-negative` past a threshold, `text-muted` for a quieter figure);
 * a null value sorts last and reads "—" unless `format` says otherwise.
 */
export function figureColumn<Row>(
  key: string,
  header: string,
  value: (row: Row) => number | null,
  format: (value: number) => string,
  options: { width?: string; tier?: ColumnTier; tone?: (row: Row) => string | false | null | undefined; muted?: boolean } = {},
): Column<Row> {
  return {
    key,
    header,
    cell: (row) => {
      const figureValue = value(row);
      return <span className={cn(figure, options.muted && "text-muted", options.tone?.(row))}>{figureValue === null ? "—" : format(figureValue)}</span>;
    },
    sortValue: value,
    className: `text-right ${options.width ?? "w-20"}`,
    ...(options.tier ? { tier: options.tier } : {}),
  };
}
