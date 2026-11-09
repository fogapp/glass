import { describe, expect, it } from "vitest";
import { tableToBars } from "@/lib/bars";
import { formatCount, formatMs, num, optionalNum } from "@/lib/format";
import type { TableResult } from "@/types";

const table = (rows: Record<string, unknown>[]) => ({ rows }) as unknown as TableResult;

describe("tableToBars", () => {
  it("sizes each bar by the measure, names it by the key column, and leads to its rows", () => {
    const bars = tableToBars(table([{ route: "/wants", count: 12 }, { route: null, count: null }]), {
      key: "route",
      measure: "count",
      format: formatCount,
      href: (row) => `/explore?filter=route:${String(row.route)}`,
    });
    expect(bars).toEqual([
      { key: "/wants", label: "/wants", value: 12, display: "12", secondary: undefined, color: undefined, href: "/explore?filter=route:/wants", onClick: undefined },
      { key: "null", label: "(none)", value: 0, display: "0", secondary: undefined, color: undefined, href: "/explore?filter=route:null", onClick: undefined },
    ]);
  });

  it("shows another figure than the one the bar is sized by", () => {
    const [bar] = tableToBars(table([{ "@status": "approved", "sum(duration)": 9000, "p50(duration)": 1200 }]), {
      key: "@status",
      measure: "sum(duration)",
      format: formatMs,
      display: (row) => formatMs(num(row["p50(duration)"])),
    });
    expect(bar).toMatchObject({ value: 9000, display: "1.20s" });
  });

  it("is empty for a missing answer", () => {
    expect(tableToBars(undefined, { key: "name", measure: "count", format: formatCount })).toEqual([]);
  });
});

describe("num and optionalNum", () => {
  it("read a missing cell as zero, or as missing", () => {
    expect(num(undefined)).toBe(0);
    expect(num("4.5")).toBe(4.5);
    expect(optionalNum(null)).toBeNull();
    expect(optionalNum(0)).toBe(0);
  });
});
