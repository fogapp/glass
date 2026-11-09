import type { ReactNode } from "react";

/**
 * The sorting half of the table primitive, kept out of the component so it can
 * be tested without rendering — and so a caller can pre-sort rows for an export
 * without going through React at all.
 */

export type SortDirection = "asc" | "desc";

export interface SortState {
  key: string;
  direction: SortDirection;
}

/**
 * `null` means absent, not smallest: it sinks to the bottom whichever way the
 * column is pointed. A source that has never been fetched must not lead the
 * "oldest fetch first" view — it has no fetch to be old.
 */
export type SortValue = string | number | boolean | null;

/**
 * The narrowest screen a fluid table's column appears on: a phone gets its
 * "phone" columns, a tablet (md) adds "tablet", a desktop (xl) adds the rest.
 * A column with no tier is always shown.
 */
export type ColumnTier = "phone" | "tablet" | "desktop";

export interface Column<Row> {
  key: string;
  header: ReactNode;
  cell: (row: Row) => ReactNode;
  /** Supplying this is what makes a column sortable. */
  sortValue?: (row: Row) => SortValue;
  /** Applied to the header cell and to every body cell in the column. */
  className?: string;
  /** Accessible name for a column whose header renders as an icon, or empty. */
  srHeader?: string;
  /** Only in a `fluid` table: the narrowest screen the column is shown on. */
  tier?: ColumnTier;
}

/** The columns a fluid table shows at this width (see `ColumnTier`). */
export function visibleColumns<Row>(columns: readonly Column<Row>[], { md, xl }: { md: boolean; xl: boolean }): Column<Row>[] {
  return columns.filter(
    (column) => column.tier === undefined || column.tier === "phone" || (md && column.tier === "tablet") || (xl && column.tier === "desktop"),
  );
}

/** Clicking a new column starts ascending; clicking the current one flips it. */
export function nextSort(current: SortState, key: string): SortState {
  if (current.key !== key) return { key, direction: "asc" };
  return { key, direction: current.direction === "asc" ? "desc" : "asc" };
}

export function sortRows<Row>(
  rows: readonly Row[],
  columns: readonly Column<Row>[],
  sort: SortState,
): Row[] {
  const sortValue = columns.find((column) => column.key === sort.key)?.sortValue;
  if (!sortValue) return [...rows];

  // Array#sort is stable, so rows that tie keep the order they arrived in —
  // which for /sources is the server's `ORDER BY name`. Every column therefore
  // breaks its ties alphabetically without any column having to say so.
  return [...rows].sort((a, b) => {
    const left = sortValue(a);
    const right = sortValue(b);
    if (left === null) return right === null ? 0 : 1;
    if (right === null) return -1;
    const result = compare(left, right);
    return sort.direction === "asc" ? result : -result;
  });
}

export interface RowGroup<Row> {
  key: string;
  rows: Row[];
}

/**
 * Partitions already-sorted rows into groups, each keeping its rows in the
 * order they arrived. Groups are ordered by first appearance, so a table
 * sorted newest-first also puts the group with the newest row first.
 */
export function groupRows<Row>(rows: readonly Row[], of: (row: Row) => string): RowGroup<Row>[] {
  const buckets = new Map<string, Row[]>();
  for (const row of rows) {
    const key = of(row);
    const bucket = buckets.get(key);
    if (bucket) bucket.push(row);
    else buckets.set(key, [row]);
  }
  return [...buckets].map(([key, members]) => ({ key, rows: members }));
}

function compare(a: Exclude<SortValue, null>, b: Exclude<SortValue, null>): number {
  if (typeof a === "string" && typeof b === "string") {
    return a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" });
  }
  return Number(a) - Number(b);
}
