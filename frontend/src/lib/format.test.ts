import { describe, expect, it } from "vitest";
import { formatBytes, formatClock, formatCount, formatMs, formatPercent, formatRate, formatUnit, shortSha } from "@/lib/format";

describe("format", () => {
  it("compacts counts past a thousand", () => {
    expect(formatCount(0)).toBe("0");
    expect(formatCount(999)).toBe("999");
    expect(formatCount(1284)).toBe("1.3K");
    expect(formatCount(4_200_000)).toBe("4.2M");
    expect(formatCount(null)).toBe("—");
  });

  it("reads durations the way people say them", () => {
    expect(formatMs(0.42)).toBe("0.42ms");
    expect(formatMs(842)).toBe("842ms");
    expect(formatMs(1200)).toBe("1.20s");
    expect(formatMs(184_000)).toBe("3m 04s");
  });

  it("formats by unit", () => {
    expect(formatUnit(0.074, "ratio")).toBe("7.4%");
    expect(formatUnit(1536, "bytes")).toBe("1.5 KB");
    expect(formatUnit(2.5, "per_second")).toBe("2.5/s");
    expect(formatUnit(0.05, "per_second")).toBe("3.0/min");
    expect(formatUnit(12.3, null)).toBe("12.3");
    expect(formatBytes(3.7e9)).toBe("3.4 GB");
    expect(formatPercent(0.0004)).toBe("0.04%");
    expect(formatRate(0.0001)).toBe("0.4/h");
  });

  it("shows money with the digits a small sum needs", () => {
    expect(formatUnit(0.0042, "usd")).toBe("$0.0042");
    expect(formatUnit(0.004, "usd")).toBe("$0.004");
    expect(formatUnit(1.284, "usd")).toBe("$1.28");
    expect(formatUnit(412.6, "usd")).toBe("$413");
    expect(formatUnit(0, "usd")).toBe("$0");
  });

  it("shortens a sha", () => {
    expect(shortSha("3df7786abcdef")).toBe("3df7786");
    expect(shortSha(null)).toBe("—");
  });

  it("reads a time of day without the locale's separators", () => {
    const at = new Date(2026, 10, 8, 21, 4, 5).getTime() / 1000;
    expect(formatClock(at, "en-GB")).toBe("21:04:05");
    expect(formatClock(at, "de-DE")).toBe("21:04:05");
    expect(formatClock(at, "en-US")).toBe("09:04:05 PM");
    expect(formatClock(new Date(2026, 10, 8, 9, 4, 5).getTime() / 1000, "en-US")).toBe("09:04:05 AM");
    expect(formatClock(null)).toBe("—");
  });
});
