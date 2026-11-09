import { useCallback, useState } from "react";
import { useSearchParams } from "react-router-dom";

/** Older links' params that mean a filter term (`?transaction=X` → `transaction:"X"`), read when `name` is absent. */
export type LegacyTerms = Record<string, (value: string) => string>;

/**
 * A page's own filter text, kept in the URL under `name`, and the draft the
 * query bar edits until it is submitted. `?app=` is the scope bar's
 * (`lib/scope.tsx`): it is never read into the filter nor dropped by
 * `apply` — the scope adds its term with `withScope`.
 */
export function useFilterParam(name: string, legacy: LegacyTerms = {}) {
  const [params, setParams] = useSearchParams();
  const legacyKeys = Object.keys(legacy);
  const filter =
    params.get(name) ??
    legacyKeys
      .map((key) => {
        const value = params.get(key);
        return value ? legacy[key]!(value) : "";
      })
      .filter(Boolean)
      .join(" ");

  // The draft follows the URL when it changes underneath (back, a link).
  const [draft, setDraft] = useState(filter);
  const [synced, setSynced] = useState(filter);
  if (synced !== filter) {
    setSynced(filter);
    setDraft(filter);
  }

  const legacyKey = legacyKeys.join(",");
  const apply = useCallback(
    (text: string) =>
      setParams(
        (current) => {
          const next = new URLSearchParams(current);
          if (text.trim()) next.set(name, text.trim());
          else next.delete(name);
          for (const key of legacyKey ? legacyKey.split(",") : []) next.delete(key);
          return next;
        },
        { replace: true },
      ),
    [name, legacyKey, setParams],
  );

  return { filter, draft, setDraft, apply };
}
