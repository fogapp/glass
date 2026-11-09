import type { BarListRow } from "@/components/charts/BarList";
import { num } from "@/lib/format";
import type { TableResult } from "@/types";

type Row = Record<string, unknown>;

/**
 * A table answer as a `BarList`'s rows: one bar per row, sized by
 * `measure`. The row's label is its `key` column ("(none)" when null)
 * unless `label` says otherwise; `href` is where the bar leads — the rows
 * behind the figure.
 */
export function tableToBars(
  result: TableResult | undefined,
  options: {
    /** The column that names the row, or how to name it. */
    key: string | ((row: Row) => string);
    /** The column the bar is sized by. */
    measure: string;
    format: (value: number) => string;
    label?: (row: Row) => string;
    /** The bar's size, when it is not the shown figure's (`display`). */
    value?: (row: Row) => number;
    /** The figure shown, when it is not `measure`'s. */
    display?: (row: Row) => string;
    secondary?: (row: Row) => string | undefined;
    color?: (row: Row) => string | undefined;
    href?: (row: Row) => string | undefined;
    onClick?: (row: Row) => (() => void) | undefined;
  },
): BarListRow[] {
  const { key, measure, format } = options;
  return (result?.rows ?? []).map((row) => {
    const named = typeof key === "string" ? row[key] : key(row);
    return {
      key: String(named),
      label: options.label ? options.label(row) : named === null || named === undefined ? "(none)" : String(named),
      value: options.value ? options.value(row) : num(row[measure]),
      display: options.display ? options.display(row) : format(num(row[measure])),
      secondary: options.secondary?.(row),
      color: options.color?.(row),
      href: options.href?.(row),
      onClick: options.onClick?.(row),
    };
  });
}
