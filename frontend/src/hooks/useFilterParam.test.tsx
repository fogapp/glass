import type { ReactNode } from "react";
import { describe, expect, it } from "vitest";
import { act, renderHook } from "@testing-library/react";
import { MemoryRouter, useSearchParams } from "react-router-dom";
import { useFilterParam } from "@/hooks/useFilterParam";
import { useCursor } from "@/hooks/useCursor";

const at = (url: string) =>
  function Router({ children }: { children: ReactNode }) {
    return <MemoryRouter initialEntries={[url]}>{children}</MemoryRouter>;
  };

function useBoth(legacy?: Parameters<typeof useFilterParam>[1]) {
  const [params] = useSearchParams();
  return { ...useFilterParam("q", legacy), params };
}

describe("useFilterParam", () => {
  it("leaves the scope's app out of the filter", () => {
    const { result } = renderHook(() => useBoth(), { wrapper: at("/traces?app=hook&range=1h") });
    expect(result.current.filter).toBe("");
    expect(result.current.draft).toBe("");
  });

  it("keeps the scope's app when the filter is applied", () => {
    const { result } = renderHook(() => useBoth(), { wrapper: at("/traces?app=hook&range=1h&q=old") });
    act(() => result.current.apply("  status:error "));
    expect(result.current.params.get("app")).toBe("hook");
    expect(result.current.params.get("range")).toBe("1h");
    expect(result.current.filter).toBe("status:error");
    expect(result.current.draft).toBe("status:error");

    act(() => result.current.apply(""));
    expect(result.current.params.get("q")).toBeNull();
    expect(result.current.params.get("app")).toBe("hook");
  });

  it("reads a legacy param into the filter and drops it on apply", () => {
    const legacy = { transaction: (name: string) => `transaction:"${name}"` };
    const { result } = renderHook(() => useBoth(legacy), { wrapper: at("/profiles?app=hook&transaction=Wants%23index") });
    expect(result.current.filter).toBe('transaction:"Wants#index"');
    act(() => result.current.apply('transaction:"Wants#show"'));
    expect(result.current.params.get("transaction")).toBeNull();
    expect(result.current.params.get("app")).toBe("hook");
  });
});

describe("useCursor", () => {
  it("falls back to the newest page when the key changes", () => {
    const { result, rerender } = renderHook(({ key }) => useCursor(key), { initialProps: { key: "a" } });
    act(() => result.current.setBefore(100));
    expect(result.current.before).toBe(100);
    rerender({ key: "b" });
    expect(result.current.before).toBeNull();
  });
});
