import type { ReactNode } from "react";
import { describe, expect, it } from "vitest";
import { fireEvent, render, renderHook, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom";
import { scopeParams, scopedHref, useScopedHref, useScopedNavigate } from "@/lib/scopeHref";
import { ScopedLink } from "@/components/scope/ScopedLink";

const at = (url: string) =>
  function Router({ children }: { children: ReactNode }) {
    return <MemoryRouter initialEntries={[url]}>{children}</MemoryRouter>;
  };

const paramsOf = (href: string) => Object.fromEntries(new URL(`http://x${href}`).searchParams);

describe("scopeParams", () => {
  it("drops empty values", () => {
    expect(scopeParams(new URLSearchParams("app=&range=1h"))).toEqual({ range: "1h" });
  });
});

describe("scopedHref", () => {
  const current = new URLSearchParams("app=hook&range=24h&live=1&markers=0&tab=x&filter=status:error");

  it("carries app, range, live and markers — and nothing else of the page's", () => {
    const href = scopedHref("/apps/hook/endpoints/Api%3A%3AWants", current);
    expect(href.startsWith("/apps/hook/endpoints/Api%3A%3AWants?")).toBe(true);
    expect(paramsOf(href)).toEqual({ app: "hook", range: "24h", live: "1", markers: "0" });
  });

  it("lets a link's own query win, and keeps the rest of it", () => {
    const href = scopedHref("/profiles?app=feed&transaction=Jobs%20run", current);
    expect(paramsOf(href)).toEqual({ app: "feed", range: "24h", live: "1", markers: "0", transaction: "Jobs run" });
  });

  it("is the bare path when the scope is the default", () => {
    expect(scopedHref("/logs", new URLSearchParams("tab=x"))).toBe("/logs");
  });

  it("is idempotent: a link built with the scope is not changed by carrying it again", () => {
    for (const href of ["/explore?shape=list&filter=a", "/apps/hook"]) {
      const once = scopedHref(href, current);
      expect(scopedHref(once, current)).toBe(once);
      const picked = scopedHref(href, current, { range: "100-200" });
      expect(scopedHref(picked, current)).toBe(picked);
    }
  });

  it("drops live when the link picks its own range", () => {
    expect(paramsOf(scopedHref("/traces", current, { range: "100-200" }))).toEqual({ app: "hook", range: "100-200", markers: "0" });
  });
});

describe("useScopedHref", () => {
  it("is the same builder until the scope changes", () => {
    const { result, rerender } = renderHook(() => useScopedHref(), { wrapper: at("/?range=1h") });
    const first = result.current;
    rerender();
    expect(result.current).toBe(first);
    expect(first("/apps/hook")).toBe("/apps/hook?range=1h");
  });
});

function Where() {
  const location = useLocation();
  return <p data-testid="where">{`${location.pathname}${location.search}`}</p>;
}

function Opener() {
  const navigate = useScopedNavigate();
  return (
    <button type="button" onClick={() => navigate("/apps/hook/jobs/Nightly")}>
      open
    </button>
  );
}

describe("in-app navigation", () => {
  it("opens a detail page in the range the list was read in", () => {
    render(
      <MemoryRouter initialEntries={["/apps/hook/jobs?range=7d&markers=0"]}>
        <Routes>
          <Route path="*" element={<><ScopedLink to="/apps/hook/endpoints">endpoints</ScopedLink><Opener /><Where /></>} />
        </Routes>
      </MemoryRouter>,
    );
    expect(screen.getByRole("link", { name: "endpoints" }).getAttribute("href")).toBe("/apps/hook/endpoints?range=7d&markers=0");
    fireEvent.click(screen.getByRole("button", { name: "open" }));
    expect(screen.getByTestId("where").textContent).toBe("/apps/hook/jobs/Nightly?range=7d&markers=0");
    // The first render of a file pays for the router's modules: generous on a loaded machine.
  }, 20_000);
});
