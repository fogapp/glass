import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { useSearchParams } from "react-router-dom";
import { DEFAULT_RANGE, parseRange, serializeRange, type TimeRange } from "@/lib/timeRange";

/**
 * The scope bar's state — which app, which time range, whether the view is
 * live, whether charts draw their marker lines — kept in the URL
 * (`?app=hook&range=1h&live=1&markers=0`) so every page obeys
 * it and any screen can be pasted to someone. Relative ranges are
 * re-evaluated on a clock while live, so charts advance.
 */
export interface Scope {
  /** An app slug, or null for the whole fleet. */
  app: string | null;
  range: TimeRange;
  live: boolean;
  /** Whether charts draw deploy and incident lines; a long range can carry too many. */
  markers: boolean;
  setApp: (slug: string | null) => void;
  setRange: (range: TimeRange) => void;
  setLive: (live: boolean) => void;
  setMarkers: (markers: boolean) => void;
  /** The filter term the scope adds to every query: "app:hook" or "". */
  filter: string;
}

const ScopeContext = createContext<Scope | null>(null);

/** The live heartbeat: how often a live view re-evaluates its window and its queries re-ask. */
export const LIVE_TICK_MS = 10_000;

export function ScopeProvider({ children }: { children: ReactNode }) {
  const [params, setParams] = useSearchParams();
  const app = params.get("app");
  const rawRange = params.get("range") ?? DEFAULT_RANGE;
  const live = params.get("live") === "1";
  const markers = params.get("markers") !== "0";

  // A relative range moves with the clock; the tick is what moves it.
  const [tick, setTick] = useState(0);
  useEffect(() => {
    if (!live) return;
    const timer = window.setInterval(() => setTick((value) => value + 1), LIVE_TICK_MS);
    return () => window.clearInterval(timer);
  }, [live]);

  // eslint-disable-next-line react-hooks/exhaustive-deps -- `tick` is the clock
  const range = useMemo(() => parseRange(rawRange), [rawRange, tick]);

  const update = useCallback(
    (mutate: (next: URLSearchParams) => void) => {
      setParams(
        (current) => {
          const next = new URLSearchParams(current);
          mutate(next);
          return next;
        },
        { replace: true },
      );
    },
    [setParams],
  );

  const value = useMemo<Scope>(
    () => ({
      app,
      range,
      live,
      markers,
      filter: app ? `app:${app}` : "",
      setApp: (slug) => update((next) => (slug ? next.set("app", slug) : next.delete("app"))),
      setRange: (next) =>
        update((query) => {
          const serialized = serializeRange(next);
          if (serialized === DEFAULT_RANGE) query.delete("range");
          else query.set("range", serialized);
          // An absolute range cannot be live: there is no "now" in it.
          if (!next.relative) query.delete("live");
        }),
      setLive: (on) => update((next) => (on ? next.set("live", "1") : next.delete("live"))),
      setMarkers: (on) => update((next) => (on ? next.delete("markers") : next.set("markers", "0"))),
    }),
    [app, range, live, markers, update],
  );

  return <ScopeContext.Provider value={value}>{children}</ScopeContext.Provider>;
}

export function useScope(): Scope {
  const scope = useContext(ScopeContext);
  if (!scope) throw new Error("useScope must be used inside ScopeProvider");
  return scope;
}

/** `scope.filter` joined with a page's own terms. */
export function withScope(scope: Pick<Scope, "filter">, ...terms: (string | null | undefined)[]): string {
  return [scope.filter, ...terms].filter((term) => term && term.trim() !== "").join(" ");
}
