import { useCallback } from "react";
import { useSearchParams } from "react-router-dom";

export interface SearchParamStateOptions<T> {
  /** The value a raw param means, or null when it means nothing valid. */
  parse: (raw: string) => T | null;
  /**
   * What an absent (or invalid) param means. It may be computed — a want's
   * default tab depends on its status — so the param is dropped only when the
   * choice equals the fallback *at the time of choosing*, never because the
   * choice happens to be some fixed "home" value.
   */
  fallback: T;
  /** How a value is written to the URL. Defaults to `String(value)`. */
  serialize?: (value: T) => string;
}

/**
 * One piece of page state kept in the query string, so a refresh stays put
 * and a view can be linked to. Other params are left alone, and the history
 * entry is replaced rather than pushed: flipping a tab is not a navigation.
 */
export function useSearchParamState<T>(
  name: string,
  { parse, fallback, serialize = String }: SearchParamStateOptions<T>,
): [T, (next: T) => void] {
  const [params, setParams] = useSearchParams();
  const raw = params.get(name);
  const parsed = raw === null ? null : parse(raw);
  const value = parsed ?? fallback;

  const setValue = useCallback(
    (next: T) => {
      setParams(
        (current) => {
          const updated = new URLSearchParams(current);
          if (Object.is(next, fallback)) updated.delete(name);
          else updated.set(name, serialize(next));
          return updated;
        },
        { replace: true },
      );
    },
    [fallback, name, serialize, setParams],
  );

  return [value, setValue];
}

/**
 * One of a closed vocabulary kept in the URL — a filter, a view. A param
 * outside `values` means the fallback, and choosing the fallback drops it.
 */
export function useUrlEnum<K extends string>(name: string, values: readonly K[], fallback: K): [K, (next: K) => void] {
  const parse = useCallback((raw: string) => values.find((value) => value === raw) ?? null, [values]);
  return useSearchParamState<K>(name, { parse, fallback });
}
