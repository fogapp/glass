import { describe, expect, it } from "vitest";
import { compact, moveCell, nudgeCell, resizeCell, rows, sameLayout, type Cell } from "@/lib/dashboardLayout";

const cell = (id: string, x: number, y: number, w = 4, h = 6): Cell => ({ id, x, y, w, h });
const place = (layout: Cell[], id: string) => {
  const found = layout.find((each) => each.id === id)!;
  return [found.x, found.y, found.w, found.h];
};

describe("compact", () => {
  it("floats every widget up into the holes and keeps it inside the grid", () => {
    const layout = compact([cell("a", 0, 3), cell("b", 10, 20, 6, 2), cell("c", 0, 30)]);
    expect(place(layout, "a")).toEqual([0, 0, 4, 6]);
    expect(place(layout, "b")).toEqual([6, 0, 6, 4]);
    expect(place(layout, "c")).toEqual([0, 6, 4, 6]);
    expect(rows(layout)).toBe(12);
  });
});

describe("moveCell", () => {
  const stack = [cell("a", 0, 0), cell("b", 0, 6)];

  it("stays put until its leading edge passes the next widget's middle", () => {
    expect(place(moveCell(stack, "a", 0, 2.5), "a")).toEqual([0, 0, 4, 6]);
    const swapped = moveCell(stack, "a", 0, 3.5);
    expect(place(swapped, "b")).toEqual([0, 0, 4, 6]);
    expect(place(swapped, "a")).toEqual([0, 6, 4, 6]);
  });

  it("goes above a widget once its top passes that widget's middle", () => {
    expect(place(moveCell(stack, "b", 0, 3.5), "b")).toEqual([0, 6, 4, 6]);
    expect(place(moveCell(stack, "b", 0, 2.5), "b")).toEqual([0, 0, 4, 6]);
  });

  it("pushes down what it lands on and lets the rest close up", () => {
    const row = [cell("a", 0, 0), cell("b", 4, 0), cell("c", 8, 0)];
    const moved = moveCell(row, "c", 0, 0);
    expect(place(moved, "c")).toEqual([0, 0, 4, 6]);
    expect(place(moved, "a")).toEqual([0, 6, 4, 6]);
    expect(place(moved, "b")).toEqual([4, 0, 4, 6]);
  });

  it("only orders itself against widgets in the columns it lands in", () => {
    const layout = [cell("a", 0, 0), cell("tall", 6, 0, 6, 20), cell("b", 0, 6)];
    const moved = moveCell(layout, "a", 0, 4);
    expect(place(moved, "b")).toEqual([0, 0, 4, 6]);
    expect(place(moved, "a")).toEqual([0, 6, 4, 6]);
    expect(place(moved, "tall")).toEqual([6, 0, 6, 20]);
  });

  it("keeps to the grid's edges", () => {
    expect(place(moveCell(stack, "a", 11, -4), "a")).toEqual([8, 0, 4, 6]);
  });
});

describe("resizeCell", () => {
  it("pushes what it grows into and lets what it leaves rise", () => {
    const layout = [cell("a", 0, 0), cell("b", 4, 0), cell("c", 0, 6)];
    const wider = resizeCell(layout, "a", 8, 6);
    expect(place(wider, "a")).toEqual([0, 0, 8, 6]);
    expect(place(wider, "b")).toEqual([4, 6, 4, 6]);
    expect(place(wider, "c")).toEqual([0, 6, 4, 6]);
    expect(place(resizeCell(layout, "a", 4, 4), "c")).toEqual([0, 4, 4, 6]);
  });

  it("holds its place when it grows into a widget that started above it", () => {
    const layout = [cell("top", 0, 0, 6), cell("side", 6, 0, 6, 20), cell("a", 0, 6, 6)];
    const wider = resizeCell(layout, "a", 8, 6);
    expect(place(wider, "a")).toEqual([0, 6, 8, 6]);
    expect(place(wider, "side")).toEqual([6, 12, 6, 20]);
  });

  it("keeps to the sizes a widget may take", () => {
    const layout = [cell("a", 8, 0)];
    expect(place(resizeCell(layout, "a", 12, 1), "a")).toEqual([8, 0, 4, 4]);
    expect(place(resizeCell(layout, "a", 0, 99), "a")).toEqual([8, 0, 2, 20]);
    expect(place(resizeCell([{ ...cell("header", 0, 0, 12, 2), minH: 1 }], "header", 12, 0), "header")).toEqual([0, 0, 12, 1]);
  });
});

describe("nudgeCell", () => {
  const stack = [cell("a", 0, 0), cell("b", 0, 6), cell("c", 4, 0)];

  it("moves past the nearest widget above or below in its columns", () => {
    expect(place(nudgeCell(stack, "a", 0, 1), "a")).toEqual([0, 6, 4, 6]);
    expect(place(nudgeCell(stack, "b", 0, -1), "b")).toEqual([0, 0, 4, 6]);
    expect(sameLayout(nudgeCell(stack, "c", 0, 1), stack)).toBe(true);
  });

  it("steps a column sideways, keeping its row and pushing down a neighbour it steps into", () => {
    expect(place(nudgeCell(stack, "c", 1, 0), "c")).toEqual([5, 0, 4, 6]);
    const row = [cell("a", 0, 0), cell("b", 4, 0)];
    const nudged = nudgeCell(row, "a", 1, 0);
    expect(place(nudged, "a")).toEqual([1, 0, 4, 6]);
    expect(place(nudged, "b")).toEqual([4, 6, 4, 6]);
  });
});
