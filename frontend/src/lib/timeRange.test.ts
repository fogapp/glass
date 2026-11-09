import { describe, expect, it } from "vitest";
import { describeRange, parseRange, previousRange, serializeRange, shiftRange, zoomOut } from "@/lib/timeRange";

describe("timeRange", () => {
  const now = 1_790_000_000;

  it("parses relative windows against the clock", () => {
    expect(parseRange("1h", now)).toEqual({ relative: "1h", from: now - 3600, to: now });
    expect(parseRange("7d", now).from).toBe(now - 7 * 86_400);
    expect(parseRange("nonsense", now).relative).toBe("3h");
    expect(parseRange(null, now).relative).toBe("3h");
  });

  it("round-trips absolute windows", () => {
    const range = parseRange(`${now - 100}-${now}`, now);
    expect(range).toEqual({ relative: null, from: now - 100, to: now });
    expect(serializeRange(range)).toBe(`${now - 100}-${now}`);
    expect(parseRange(`${now}-${now - 1}`, now).relative).toBe("3h");
  });

  it("steps, zooms and looks back", () => {
    const range = parseRange("1h", now);
    expect(shiftRange(range, -1)).toEqual({ relative: null, from: now - 7200, to: now - 3600 });
    expect(zoomOut(range)).toEqual({ relative: null, from: now - 5400, to: now + 1800 });
    expect(previousRange(range)).toEqual({ relative: null, from: now - 7200, to: now - 3600 });
    expect(describeRange(range)).toBe("Last 1 hour");
  });
});
