import { describe, expect, it } from "vitest";
import { functionTotals } from "@/components/charts/Flamegraph";
import type { Flamegraph } from "@/types";

function graph(nodes: number[][]): Flamegraph {
  return { total_ms: 0, baseline_total_ms: null, samples: [], functions: [], nodes, diff: false };
}

/** The previous implementation, a set of ancestor functions per node: the reference. */
function reference(data: Flamegraph) {
  const self = new Map<number, number>();
  const total = new Map<number, number>();
  const baseSelf = new Map<number, number>();
  const baseTotal = new Map<number, number>();
  const ancestors: Set<number>[] = [];
  data.nodes.forEach((node, index) => {
    const [fn, parent, s, t, bs = 0, bt = 0] = node as number[];
    const set = new Set(parent !== undefined && parent >= 0 ? (ancestors[parent] ?? []) : []);
    ancestors[index] = set;
    if (fn === undefined) return;
    self.set(fn, (self.get(fn) ?? 0) + (s ?? 0));
    baseSelf.set(fn, (baseSelf.get(fn) ?? 0) + bs);
    if (!set.has(fn)) {
      total.set(fn, (total.get(fn) ?? 0) + (t ?? 0));
      baseTotal.set(fn, (baseTotal.get(fn) ?? 0) + bt);
    }
    set.add(fn);
  });
  return Array.from(total.keys())
    .filter((fn) => fn !== 0)
    .map((fn) => ({ fn, self: self.get(fn) ?? 0, total: total.get(fn) ?? 0, baseSelf: baseSelf.get(fn) ?? 0, baseTotal: baseTotal.get(fn) ?? 0 }));
}

const byFn = (rows: ReturnType<typeof functionTotals>) => [...rows].sort((a, b) => a.fn - b.fn);

describe("functionTotals", () => {
  it("counts a recursive function's total once, at its outermost call", () => {
    // root(0) → a(1) → b(2) → a(1) → c(3); root → c(3)
    const data = graph([
      [0, -1, 0, 100],
      [1, 0, 10, 80],
      [2, 1, 20, 70],
      [1, 2, 30, 50],
      [3, 3, 20, 20],
      [3, 0, 20, 20],
    ]);
    expect(byFn(functionTotals(data))).toEqual([
      { fn: 1, self: 40, total: 80, baseSelf: 0, baseTotal: 0 },
      { fn: 2, self: 20, total: 70, baseSelf: 0, baseTotal: 0 },
      { fn: 3, self: 40, total: 40, baseSelf: 0, baseTotal: 0 },
    ]);
  });

  it("forgets a function once the path has left it", () => {
    // root → a → b; root → b: the second b is not under a, and counts.
    const data = graph([
      [0, -1, 0, 30, 0, 60],
      [1, 0, 0, 10, 0, 20],
      [2, 1, 10, 10, 20, 20],
      [2, 0, 20, 20, 40, 40],
    ]);
    expect(byFn(functionTotals(data))).toEqual([
      { fn: 1, self: 0, total: 10, baseSelf: 0, baseTotal: 20 },
      { fn: 2, self: 30, total: 30, baseSelf: 60, baseTotal: 60 },
    ]);
  });

  it("agrees with the ancestor-set reference on random trees", () => {
    let seed = 7;
    const random = () => {
      seed = (seed * 1103515245 + 12345) % 2147483648;
      return seed / 2147483648;
    };
    for (let trial = 0; trial < 50; trial += 1) {
      // Preorder: each node's parent is somewhere on the path to the node before it.
      const nodes: number[][] = [[0, -1, 0, 1000, 0, 1000]];
      const path = [0];
      const size = 2 + Math.floor(random() * 200);
      for (let index = 1; index < size; index += 1) {
        path.length = 1 + Math.floor(random() * path.length);
        const parent = path[path.length - 1]!;
        nodes.push([1 + Math.floor(random() * 6), parent, Math.floor(random() * 10), Math.floor(random() * 100), Math.floor(random() * 10), Math.floor(random() * 100)]);
        path.push(index);
      }
      const data = graph(nodes);
      expect(byFn(functionTotals(data))).toEqual(byFn(reference(data)));
    }
  });
});
