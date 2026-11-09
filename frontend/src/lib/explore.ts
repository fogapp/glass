import { useCallback } from "react";
import { useScopedHref } from "@/lib/scopeHref";
import { withScope, type Scope } from "@/lib/scope";
import { QUERY_SHAPES, QUERY_SOURCES, type QueryResult, type QuerySource, type QueryShape, type QuerySpec } from "@/types";

/** The Explorer's state, as the URL carries it. */
export interface ExploreState {
  source: QuerySource;
  shape: QueryShape;
  filter: string;
  compute: string[];
  group_by: string[];
  metric: string;
  field: string;
}

export const DEFAULT_EXPLORE: ExploreState = {
  source: "transactions",
  shape: "timeseries",
  filter: "",
  compute: ["count"],
  group_by: [],
  metric: "",
  field: "duration",
};

/**
 * This much of the Explorer's state, the rest its defaults. A key that is
 * present but undefined (a saved widget's spec leaves out what it never
 * set) is a default too, not a hole.
 */
export function withDefaults(state: Partial<ExploreState>): ExploreState {
  const set = Object.fromEntries(Object.entries(state).filter(([, value]) => value !== undefined)) as Partial<ExploreState>;
  return { ...DEFAULT_EXPLORE, ...set };
}

/** A link into the Explorer with this much of its state set. */
export function exploreHref(state: Partial<ExploreState>, extra: Record<string, string> = {}): string {
  const params = new URLSearchParams();
  const merged = withDefaults(state);
  if (merged.source !== DEFAULT_EXPLORE.source) params.set("source", merged.source);
  if (merged.shape !== DEFAULT_EXPLORE.shape) params.set("shape", merged.shape);
  if (merged.filter) params.set("filter", merged.filter);
  if (merged.compute.join(",") !== DEFAULT_EXPLORE.compute.join(",")) params.set("compute", merged.compute.join(","));
  if (merged.group_by.length > 0) params.set("group_by", merged.group_by.join(","));
  if (merged.metric) params.set("metric", merged.metric);
  if (merged.field !== DEFAULT_EXPLORE.field) params.set("field", merged.field);
  for (const [key, value] of Object.entries(extra)) params.set(key, value);
  const query = params.toString();
  return query ? `/explore?${query}` : "/explore";
}

/**
 * `exploreHref` that keeps the scope (`useScopedHref`): every number leads
 * to its rows with the same app, range, live and markers the page was read
 * in. Every link into the Explorer is built with this.
 */
export function useExploreHref(): (state: Partial<ExploreState>, extra?: Record<string, string>) => string {
  const href = useScopedHref();
  return useCallback((state, extra = {}) => href(exploreHref(state), extra), [href]);
}

/** The shapes a metric can be drawn as; anything else is drawn over time. */
export const METRIC_SHAPES: readonly QueryShape[] = ["timeseries", "table"];

/** How many rows, series or bars a shape asks for, unless a saved widget says otherwise. */
export function limitFor(shape: QueryShape): number {
  return shape === "list" ? 100 : shape === "table" ? 50 : 10;
}

/**
 * The query an Explorer state asks, in a scope — the one builder, so a
 * chart pinned to a dashboard asks what the Explorer asked. Null while a
 * metric is still to be picked. A saved widget's own `limit` wins.
 */
export function specFor(state: ExploreState & { limit?: number }, scope: Pick<Scope, "range" | "filter">): QuerySpec | null {
  if (state.source === "metrics" && !state.metric) return null;
  const shape = state.source === "metrics" && !METRIC_SHAPES.includes(state.shape) ? "timeseries" : state.shape;
  const bucketed = shape === "heatmap" || shape === "histogram";
  return {
    source: state.source,
    shape,
    from: scope.range.from,
    to: scope.range.to,
    filter: withScope(scope, state.filter),
    compute: shape === "list" ? undefined : state.compute,
    group_by: shape === "list" || bucketed ? undefined : state.group_by,
    metric: state.source === "metrics" ? state.metric : undefined,
    field: bucketed ? state.field : undefined,
    limit: state.limit ?? limitFor(shape),
  };
}

export function parseExplore(params: URLSearchParams): ExploreState {
  const list = (key: string, fallback: string[]) => {
    const raw = params.get(key);
    return raw === null ? fallback : raw.split(",").map((item) => item.trim()).filter(Boolean);
  };
  const source = params.get("source") as QuerySource | null;
  const shape = params.get("shape") as QueryShape | null;
  return {
    source: source && (QUERY_SOURCES as readonly string[]).includes(source) ? source : DEFAULT_EXPLORE.source,
    shape: shape && (QUERY_SHAPES as readonly string[]).includes(shape) ? shape : DEFAULT_EXPLORE.shape,
    filter: params.get("filter") ?? "",
    compute: list("compute", DEFAULT_EXPLORE.compute),
    group_by: list("group_by", []),
    metric: params.get("metric") ?? "",
    field: params.get("field") ?? DEFAULT_EXPLORE.field,
  };
}

/** A value as a filter term, quoted when it needs it. */
export function term(key: string, value: string | number | boolean | null): string {
  if (value === null) return `-${key}:*`;
  const text = String(value);
  return /[\s"]/.test(text) ? `${key}:"${text.replaceAll('"', '\\"')}"` : `${key}:${text}`;
}

/**
 * The state narrowed to one group of an answer — a bar, a row, a series:
 * its values become filter terms and stop being grouped by.
 */
export function narrow(state: ExploreState, group: Record<string, string | number | boolean | null>): ExploreState {
  const terms = Object.entries(group).map(([key, value]) => term(key, value));
  return { ...state, filter: [state.filter, ...terms].filter(Boolean).join(" "), group_by: state.group_by.filter((key) => !(key in group)) };
}

/** A window of seconds as the `range` a link carries (whole seconds, covering it). */
export function rangeParam(from: number, to: number): { range: string } {
  return { range: `${Math.floor(from)}-${Math.ceil(to)}` };
}

/** Whether an answer has nothing to draw: a failed or empty query is never an empty chart. */
export function isEmptyResult(data: QueryResult): boolean {
  switch (data.shape) {
    case "timeseries":
      return data.series.length === 0 || data.series.every((series) => series.values.every((value) => value === null || value === 0));
    case "table":
    case "list":
      return data.rows.length === 0;
    case "heatmap":
      return data.cells.length === 0;
    case "histogram":
      return data.counts.every((count) => count === 0);
  }
}
