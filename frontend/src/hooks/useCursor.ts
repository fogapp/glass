import { useCallback, useState } from "react";

/**
 * A list's `before` cursor, which falls back to the newest page whenever
 * `resetKey` (the spec it pages through) changes — derived during render,
 * so the stale cursor is never asked for.
 */
export function useCursor(resetKey: string) {
  const [state, setState] = useState<{ key: string; before: number | null }>({ key: resetKey, before: null });
  const before = state.key === resetKey ? state.before : null;
  const setBefore = useCallback((next: number | null) => setState({ key: resetKey, before: next }), [resetKey]);
  return { before, setBefore };
}
