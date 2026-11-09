import { useCallback } from "react";
import { useNavigate, useSearchParams, type NavigateOptions } from "react-router-dom";

/*
 * In-app links that keep the scope bar's state (`lib/scope.tsx`): opening
 * an endpoint, a tab, another section, arrives in the app, range, live and
 * markers the page was read in. `ScopedLink` / `ScopedNavLink`
 * (components/scope/ScopedLink) are the same for elements.
 */

/** The scope bar's state as the URL carries it. */
export const SCOPE_PARAMS = ["app", "range", "live", "markers"] as const;

/**
 * The scope bar's params to carry into a link. A link that sets its own
 * range (a bucket, a cell) keeps it, and is then not live: there is no
 * "now" in a window it picked. A link's own params win over the scope's.
 */
export function scopeParams(current: URLSearchParams, extra: Record<string, string> = {}): Record<string, string> {
  const carried: Record<string, string> = {};
  for (const key of SCOPE_PARAMS) {
    if (key === "live" && "range" in extra) continue;
    const value = current.get(key);
    if (value !== null && value !== "") carried[key] = value;
  }
  return { ...carried, ...extra };
}

/** `to` (a path, perhaps with its own query) with the scope of `current` carried into it. */
export function scopedHref(to: string, current: URLSearchParams, extra: Record<string, string> = {}): string {
  const at = to.indexOf("?");
  const pathname = at === -1 ? to : to.slice(0, at);
  const own = at === -1 ? {} : Object.fromEntries(new URLSearchParams(to.slice(at + 1)));
  const merged = scopeParams(current, { ...own, ...extra });
  // The scope's params first, in one order, so carrying the scope into a link that has it is no change.
  const ordered = [...SCOPE_PARAMS.filter((key) => key in merged), ...Object.keys(merged).filter((key) => !(SCOPE_PARAMS as readonly string[]).includes(key))];
  const search = new URLSearchParams(ordered.map((key) => [key, merged[key]!])).toString();
  return search ? `${pathname}?${search}` : pathname;
}

/**
 * A link builder that keeps the scope: opening an endpoint, a tab, another
 * section, keeps the app, range, live and markers the page was read in.
 * Every in-app link between scoped pages is built with this.
 */
export function useScopedHref(): (to: string, extra?: Record<string, string>) => string {
  const [params] = useSearchParams();
  // The scope's own params, as one string: the builder changes when the scope does, not with every param.
  const scope = new URLSearchParams(SCOPE_PARAMS.flatMap((key) => (params.has(key) ? [[key, params.get(key) ?? ""]] : []))).toString();
  return useCallback((to, extra = {}) => scopedHref(to, new URLSearchParams(scope), extra), [scope]);
}

/** `navigate` that keeps the scope. */
export function useScopedNavigate(): (to: string, options?: NavigateOptions) => void {
  const navigate = useNavigate();
  const href = useScopedHref();
  return useCallback((to, options) => void navigate(href(to), options), [navigate, href]);
}
