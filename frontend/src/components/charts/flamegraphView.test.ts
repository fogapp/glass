import { describe, expect, it } from "vitest";
import { HOME, MAX_SCALE, ROW, clampView, fitScale, panBy, rowHeight, treeSize, zoomAt } from "@/components/charts/flamegraphView";

// A frame 1000 × 360 holding a tree 40 rows deep: twice as tall as the frame.
const deep = { width: 1000, height: 360, rows: 40 };
const shallow = { width: 1000, height: 360, rows: 10 };

describe("flamegraphView", () => {
  it("fits a tree deeper than the frame by shrinking its rows", () => {
    expect(fitScale(deep)).toBe(0.5);
    expect(rowHeight(0.5)).toBe(ROW / 2);
    expect(treeSize(0.5, deep)).toEqual({ width: 1000, height: 360 });
  });

  it("has nothing to zoom out to when the tree already fits", () => {
    expect(fitScale(shallow)).toBe(1);
    expect(clampView({ scale: 0.2, x: 0, y: 0 }, shallow)).toEqual(HOME);
  });

  it("never shrinks rows past what can be seen", () => {
    expect(rowHeight(fitScale({ width: 1000, height: 360, rows: 5000 }))).toBe(3);
  });

  it("stretches sideways above 100% and leaves the rows alone", () => {
    expect(treeSize(4, deep)).toEqual({ width: 4000, height: 40 * ROW });
  });

  it("stops panning at the tree's edges", () => {
    expect(panBy(HOME, deep, -50, -50)).toEqual(HOME);
    expect(panBy(HOME, deep, 50, 5000)).toEqual({ scale: 1, x: 0, y: 360 });
    expect(panBy({ scale: 2, x: 0, y: 0 }, deep, 5000, 0)).toEqual({ scale: 2, x: 1000, y: 0 });
  });

  it("returns the same view when there is nothing to clamp", () => {
    const view = { scale: 2, x: 100, y: 100 };
    expect(clampView(view, deep)).toBe(view);
  });

  it("keeps the point under the cursor where it is", () => {
    const view = zoomAt(HOME, deep, 2, 750, 0);
    // 750px was three quarters across the tree; it still is.
    expect((view.x + 750) / treeSize(view.scale, deep).width).toBeCloseTo(0.75);
    expect(view).toEqual({ scale: 2, x: 750, y: 0 });

    const row = { scale: 1, x: 0, y: 360 };
    const out = zoomAt(row, deep, 0.5, 500, 360);
    expect(out).toEqual({ scale: 0.5, x: 0, y: 0 });
  });

  it("holds the scale inside its range", () => {
    expect(zoomAt(HOME, deep, 1e9, 0, 0).scale).toBe(MAX_SCALE);
    expect(zoomAt(HOME, deep, 0, 0, 0).scale).toBe(0.5);
  });
});
