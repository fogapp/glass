import { useCallback, useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { LIVE_TICK_MS as LIVE_REFETCH_MS, useScope } from "@/lib/scope";
import type { QueryAnswer, QueryResult, QuerySpec } from "@/types";

/**
 * A telemetry query as a TanStack query: the spec is the key. Timestamps in
 * a relative range change every live tick, so the spec's `from`/`to` are
 * rounded to the step the server would pick anyway — otherwise every tick is
 * a new key and nothing is ever a cache hit.
 */
export function useGlassQuery<T extends QueryResult = QueryResult>(
  spec: QuerySpec | null,
  options: { live?: boolean; enabled?: boolean } = {},
) {
  const rounded = spec ? roundSpec(spec) : null;
  return useQuery<T>({
    queryKey: rounded ? keys.query.run(rounded) : [...keys.query.all, "disabled"],
    queryFn: ({ signal }) => api.post<T>("/query", rounded, { signal }),
    enabled: rounded !== null && options.enabled !== false,
    refetchInterval: options.live ? LIVE_REFETCH_MS : false,
    placeholderData: (previous) => previous,
    staleTime: 5_000,
  });
}

/** Several specs, one round trip, answers in order. */
export function useGlassQueries(specs: QuerySpec[], options: { live?: boolean; enabled?: boolean } = {}) {
  const rounded = specs.map(roundSpec);
  return useQuery<{ results: QueryAnswer[] }>({
    queryKey: keys.query.batch(rounded),
    queryFn: ({ signal }) => api.post<{ results: QueryAnswer[] }>("/query", { queries: rounded }, { signal }),
    enabled: rounded.length > 0 && options.enabled !== false,
    refetchInterval: options.live ? LIVE_REFETCH_MS : false,
    placeholderData: (previous) => previous,
    staleTime: 5_000,
  });
}

/** A spec of a page's batch: its range is the scope's unless it names one. */
export type BatchSpec = Omit<QuerySpec, "from" | "to"> & Partial<Pick<QuerySpec, "from" | "to">>;

/** A page's batch as `useGlassBatch` hands it over: the query, its answers by name, what failed. */
export interface GlassBatch<K extends string = string> {
  batch: ReturnType<typeof useGlassQueries>;
  /** The answer a spec was given, or undefined while loading or when that query failed. Stable until the answers change. */
  answer<T extends QueryAnswer = QueryAnswer>(key: K): T | undefined;
  failures: string[];
}

/**
 * A page's batch, keyed: `{ throughput: spec, latency: spec }` asks in one
 * round trip and reads back `answer("latency")`, so reordering the specs
 * never relabels a chart. A spec without `from`/`to` is asked over the
 * scope's range. One query of a batch can fail on its own; its figures
 * would read as zeros, so `failures` carries what it said, for the page to
 * show through `<Failures>`.
 */
export function useGlassBatch<K extends string>(specs: Record<K, BatchSpec>, options: { live?: boolean; enabled?: boolean } = {}): GlassBatch<K> {
  const { range } = useScope();
  const names = Object.keys(specs) as K[];
  const batch = useGlassQueries(
    names.map((name) => ({ from: range.from, to: range.to, ...specs[name] }) as QuerySpec),
    options,
  );
  // Keyed on the names, not on the record: a page that rebuilds its specs every render keeps one `answer`.
  const order = names.join("\u0000");
  const results = batch.data?.results;
  const answer = useCallback(
    <T extends QueryAnswer = QueryAnswer>(key: K): T | undefined => {
      const item = results?.[order.split("\u0000").indexOf(key)];
      return item && !isQueryError(item) ? (item as T) : undefined;
    },
    [results, order],
  );
  const failures = useMemo(() => [...new Set((results ?? []).flatMap((item) => (isQueryError(item) ? item.errors : [])))], [results]);
  return { batch, answer, failures };
}

export function isQueryError(answer: QueryAnswer): answer is { errors: string[] } {
  return "errors" in answer;
}

/**
 * A window rounded to a grain that keeps keys stable between live ticks:
 * anything keyed on a range (a spec, a facet's values, the journeys) asks
 * with this, or every tick is a new key.
 */
export function roundRange<R extends { from: number; to: number }>(range: R): { from: number; to: number } {
  const grain = grainFor(range.to - range.from);
  return { from: Math.floor(range.from / grain) * grain, to: Math.ceil(range.to / grain) * grain };
}

function roundSpec(spec: QuerySpec): QuerySpec {
  return { ...spec, ...roundRange(spec) };
}

function grainFor(spanSeconds: number): number {
  if (spanSeconds <= 3600) return 10;
  if (spanSeconds <= 86_400) return 60;
  return 300;
}

