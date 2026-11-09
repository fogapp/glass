import type { ListResult } from "@/types";

/**
 * A list answer's rows as the row type its source returns. The query engine
 * answers every list with untyped rows (`Record<string, unknown>`); which
 * shape they have follows from the spec's `source`, which TypeScript cannot
 * see. This is the one place that trust is written down, instead of an
 * `as unknown as` at every call site. A missing answer is no rows.
 */
export function listRows<T>(result: Pick<ListResult, "rows"> | null | undefined): T[] {
  return (result?.rows ?? []) as unknown as T[];
}
