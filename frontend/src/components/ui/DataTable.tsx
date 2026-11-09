import { Fragment, useMemo, useState, type ReactNode } from "react";
import { ArrowDown, ArrowUp, ChevronsUpDown } from "lucide-react";
import { BREAKPOINTS, useMediaQuery } from "@/hooks/useMediaQuery";
import { cn } from "@/lib/cn";
import { DisclosureButton } from "./DisclosureButton";
import {
  groupRows,
  nextSort,
  sortRows,
  visibleColumns,
  type Column,
  type SortDirection,
  type SortState,
} from "@/lib/dataTable";

interface Grouping<Row> {
  /** Rows sharing a key sit together under one header row. Groups appear in
   *  the order the sorted rows introduce them, so the active sort orders the
   *  groups too. */
  of: (row: Row) => string;
  /** Content of the group's header row, spanning every column. */
  header: (key: string, rows: readonly Row[]) => ReactNode;
}

interface DataTableProps<Row> {
  columns: Column<Row>[];
  rows: readonly Row[];
  rowKey: (row: Row) => string;
  sort: SortState;
  onSortChange: (sort: SortState) => void;
  /** Omit entirely for a flat, ungrouped table. */
  group?: Grouping<Row>;
  /** Extra classes for a row that should read differently — dimmed, flagged. */
  rowClassName?: (row: Row) => string | undefined;
  /** Panel behind each row's disclosure control. Return null for a row with
   *  nothing more to say and it simply gets no control. */
  detail?: (row: Row) => ReactNode;
  /** Screen-reader description of what the table holds. */
  caption: string;
  /**
   * Fit the viewport instead of scrolling sideways. Columns then take the
   * widths their `className` asks for and the rest goes to whatever asked for
   * none, so every fluid table needs one column that truncates. Use it where
   * a row is a summary a person scans; leave it off where
   * a row is a record whose columns each need their full width.
   *
   * A fluid table also honours each column's `tier`: `display: none` can't
   * give a `table-fixed` column's width back, so a column too wide for the
   * screen is left out of the table instead of hidden in it.
   */
  fluid?: boolean;
}

/**
 * A sortable table. Deliberately not a table *library*: sorting, grouping and
 * row disclosure are the three things the console actually needs, and each is a
 * few lines here against a dependency that would arrive with its own opinions
 * about styling — which the cardinal color rule doesn't leave room for.
 */
export function DataTable<Row>({
  columns: allColumns,
  rows,
  rowKey,
  sort,
  onSortChange,
  group,
  detail,
  caption,
  rowClassName,
  fluid = false,
}: DataTableProps<Row>) {
  const [expanded, setExpanded] = useState<string[]>([]);
  const md = useMediaQuery(BREAKPOINTS.md);
  const xl = useMediaQuery(BREAKPOINTS.xl);
  const columns = useMemo(
    () => (fluid ? visibleColumns(allColumns, { md, xl }) : allColumns),
    [fluid, allColumns, md, xl],
  );

  // Sorted on every column, shown or not: a sort chosen on a wide screen
  // holds when the window narrows past its column.
  const sorted = useMemo(() => sortRows(rows, allColumns, sort), [rows, allColumns, sort]);
  const groups = useMemo(
    () => (group ? groupRows(sorted, group.of) : [{ key: "", rows: sorted }]),
    [group, sorted],
  );
  const columnCount = columns.length + (detail ? 1 : 0);

  return (
    <div className={fluid ? undefined : "overflow-x-auto"}>
      <table
        className={cn(
          "w-full border-collapse text-left text-sm",
          fluid ? "table-fixed" : "min-w-4xl",
        )}
      >
        <caption className="sr-only">{caption}</caption>
        <thead>
          <tr className="border-b border-border bg-surface-raised">
            {detail ? (
              <th scope="col" className="w-9 px-1 py-2.5">
                <span className="sr-only">Details</span>
              </th>
            ) : null}
            {columns.map((column) => {
              const active = sort.key === column.key;
              return (
                <th
                  key={column.key}
                  scope="col"
                  aria-sort={
                    active ? (sort.direction === "asc" ? "ascending" : "descending") : "none"
                  }
                  className={cn(
                    "px-3 py-2.5 text-xs font-medium uppercase tracking-wide text-muted",
                    column.className,
                  )}
                >
                  {column.srHeader ? <span className="sr-only">{column.srHeader}</span> : null}
                  {column.sortValue ? (
                    <button
                      type="button"
                      onClick={() => onSortChange(nextSort(sort, column.key))}
                      className={cn(
                        "inline-flex items-center gap-1 transition-colors hover:text-foreground",
                        active && "text-foreground",
                      )}
                    >
                      {column.header}
                      <SortIcon active={active} direction={sort.direction} />
                    </button>
                  ) : (
                    column.header
                  )}
                </th>
              );
            })}
          </tr>
        </thead>

        {groups.map((section) => (
          <tbody key={section.key || "all"}>
            {group ? (
              <tr className="border-b border-border bg-surface-raised/80">
                <th
                  scope="rowgroup"
                  colSpan={columnCount}
                  className="px-3 py-2 text-left text-sm font-medium text-foreground"
                >
                  {group.header(section.key, section.rows)}
                </th>
              </tr>
            ) : null}
            {section.rows.map((row) => {
              const id = rowKey(row);
              const panel = detail ? detail(row) : null;
              const open = expanded.includes(id);

              return (
                <Fragment key={id}>
                  <tr
                    className={cn(
                      "border-b border-border transition-colors",
                      "hover:bg-surface-raised/60",
                      rowClassName?.(row),
                    )}
                  >
                    {detail ? (
                      <td className="px-1 py-2.5 align-top">
                        {panel ? (
                          <DisclosureButton
                            open={open}
                            onToggle={() =>
                              setExpanded((current) =>
                                current.includes(id)
                                  ? current.filter((each) => each !== id)
                                  : [...current, id],
                              )
                            }
                          />
                        ) : null}
                      </td>
                    ) : null}
                    {columns.map((column) => (
                      <td
                        key={column.key}
                        className={cn("px-3 py-2.5 align-top text-foreground", column.className)}
                      >
                        {column.cell(row)}
                      </td>
                    ))}
                  </tr>

                  {open && panel ? (
                    <tr className="border-b border-border bg-surface-raised/50">
                      <td colSpan={columnCount} className="px-5 py-4">
                        {panel}
                      </td>
                    </tr>
                  ) : null}
                </Fragment>
              );
            })}
          </tbody>
        ))}
      </table>
    </div>
  );
}

function SortIcon({ active, direction }: { active: boolean; direction: SortDirection }) {
  if (!active) return <ChevronsUpDown className="h-3 w-3 opacity-40" aria-hidden />;
  return direction === "asc" ? (
    <ArrowUp className="h-3 w-3" aria-hidden />
  ) : (
    <ArrowDown className="h-3 w-3" aria-hidden />
  );
}
