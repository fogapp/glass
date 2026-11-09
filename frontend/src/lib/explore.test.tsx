import type { ReactNode } from "react";
import { describe, expect, it } from "vitest";
import { renderHook } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { DEFAULT_EXPLORE, exploreHref, narrow, parseExplore, specFor, term, useExploreHref, withDefaults } from "@/lib/explore";

const at = (url: string) =>
  function Router({ children }: { children: ReactNode }) {
    return <MemoryRouter initialEntries={[url]}>{children}</MemoryRouter>;
  };

const paramsOf = (href: string) => new URL(`http://x${href}`).searchParams;

describe("explore", () => {
  it("writes only what differs from the default into the URL, and reads it back", () => {
    expect(exploreHref({})).toBe("/explore");
    const href = exploreHref({ source: "logs", shape: "list", filter: "app:hook level:error", compute: ["count"], group_by: ["level"] }, { range: "1h" });
    const state = parseExplore(paramsOf(href));
    expect(state).toMatchObject({ source: "logs", shape: "list", filter: "app:hook level:error", group_by: ["level"] });
    expect(href).toContain("range=1h");
  });

  it("reads a key that is present but undefined as its default", () => {
    // A saved widget's spec leaves out what it never set; spreading it would put undefined over the defaults.
    const spec = { source: "logs" as const, shape: undefined, compute: undefined, group_by: undefined, filter: undefined, metric: undefined, field: undefined };
    expect(withDefaults(spec)).toEqual({ ...DEFAULT_EXPLORE, source: "logs" });
    expect(exploreHref(spec)).toBe("/explore?source=logs");
  });

  it("builds one query from a state, with the Explorer's limits unless a widget saved its own", () => {
    const scope = { range: { from: 100, to: 200 }, filter: "app:hook" } as Parameters<typeof specFor>[1];
    expect(specFor({ ...DEFAULT_EXPLORE, shape: "table", group_by: ["name"], filter: "status:error" }, scope)).toEqual({
      source: "transactions", shape: "table", from: 100, to: 200, filter: "app:hook status:error", compute: ["count"], group_by: ["name"], metric: undefined, field: undefined, limit: 50,
    });
    expect(specFor({ ...DEFAULT_EXPLORE }, scope)?.limit).toBe(10);
    expect(specFor({ ...DEFAULT_EXPLORE, shape: "list" }, scope)).toMatchObject({ limit: 100, compute: undefined, group_by: undefined });
    expect(specFor({ ...DEFAULT_EXPLORE, shape: "table", limit: 6 }, scope)?.limit).toBe(6);
    expect(specFor({ ...DEFAULT_EXPLORE, source: "metrics" }, scope)).toBeNull();
    expect(specFor({ ...DEFAULT_EXPLORE, source: "metrics", metric: "rss", shape: "histogram" }, scope)).toMatchObject({ shape: "timeseries", metric: "rss", field: undefined });
  });

  it("narrows to one group: its values become terms and stop being grouped by", () => {
    const state = { ...DEFAULT_EXPLORE, filter: "kind:job", group_by: ["name", "app"] };
    expect(narrow(state, { name: "Daily digest", app: null })).toMatchObject({ filter: 'kind:job name:"Daily digest" -app:*', group_by: [] });
  });

  it("quotes filter values that need it", () => {
    expect(term("name", "Api::V1::WantsController#index")).toBe("name:Api::V1::WantsController#index");
    expect(term("error", "connection timed out")).toBe('error:"connection timed out"');
    expect(term("error", null)).toBe("-error:*");
  });
});

describe("useExploreHref", () => {
  it("carries the scope — app, range, live, markers — into every link, and nothing else of the page's", () => {
    const { result } = renderHook(() => useExploreHref(), { wrapper: at("/apps/hook/jobs?app=hook&range=24h&live=1&markers=0&tab=x") });
    const params = paramsOf(result.current({ shape: "list", filter: "status:error" }));
    expect(Object.fromEntries(params)).toEqual({ shape: "list", filter: "status:error", app: "hook", range: "24h", live: "1", markers: "0" });
  });

  it("keeps a link's own range, which is then not live", () => {
    const { result } = renderHook(() => useExploreHref(), { wrapper: at("/?range=24h&live=1&markers=0") });
    const params = paramsOf(result.current({ shape: "list" }, { range: "100-200" }));
    expect(params.get("range")).toBe("100-200");
    expect(params.has("live")).toBe(false);
    expect(params.get("markers")).toBe("0");
  });

  it("adds nothing when the scope is the default", () => {
    const { result } = renderHook(() => useExploreHref(), { wrapper: at("/") });
    expect(result.current({})).toBe("/explore");
  });

  it("is the same builder until the scope changes", () => {
    const { result, rerender } = renderHook(() => useExploreHref(), { wrapper: at("/?range=1h") });
    const first = result.current;
    rerender();
    expect(result.current).toBe(first);
  });
});
