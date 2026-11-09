import type { Trace, TraceModelCall, TraceSpan, TraceTransaction } from "@/types";

export interface WaterfallRow {
  id: string;
  parent: string | null;
  depth: number;
  kind: string;
  name: string;
  resource: string | null;
  start: number;
  duration: number;
  status: "ok" | "error";
  app: string | null;
  transaction?: TraceTransaction;
  span?: TraceSpan;
  /** The model call this span was. */
  call?: TraceModelCall;
  /** For the stretches of a run that no span covers: each one, as [start, duration]. */
  segments?: [number, number][];
}

/** The stretches of [start, end) that none of the intervals cover. */
export function uncovered(start: number, end: number, intervals: [number, number][]): [number, number][] {
  const gaps: [number, number][] = [];
  let cursor = start;
  for (const [from, to] of [...intervals].sort((a, b) => a[0] - b[0])) {
    if (from > cursor) gaps.push([cursor, Math.min(from, end) - cursor]);
    cursor = Math.max(cursor, to);
    if (cursor >= end) break;
  }
  if (cursor < end) gaps.push([cursor, end - cursor]);
  return gaps.filter(([, duration]) => duration > 0);
}

/**
 * Transactions and spans as one tree, in start order, with depths. A run
 * gets one more row: the time no span of its covers, so that a hole in what
 * was recorded is something on the page rather than something missing from it.
 */
export function waterfall(trace: Trace): WaterfallRow[] {
  const rows: WaterfallRow[] = [];
  const byId = new Map<string, WaterfallRow>();
  const calls = new Map(trace.model_calls.filter((call) => call.span).map((call) => [call.span as string, call]));
  const all: WaterfallRow[] = [
    ...trace.transactions.map((txn) => ({
      id: txn.span,
      parent: txn.parent,
      depth: 0,
      kind: txn.kind,
      name: txn.name,
      resource: null,
      start: txn.ts * 1000,
      duration: txn.duration,
      status: txn.status,
      app: txn.app,
      transaction: txn,
    })),
    ...trace.spans.map((span) => ({
      id: span.span,
      parent: span.parent,
      depth: 0,
      kind: span.kind,
      name: span.name,
      resource: span.resource,
      start: span.ts * 1000,
      duration: span.duration,
      status: span.status,
      app: span.app,
      span,
      call: calls.get(span.span),
    })),
  ];
  all.forEach((row) => byId.set(row.id, row));
  const children = new Map<string | null, WaterfallRow[]>();
  for (const row of all) {
    const parent = row.parent && byId.has(row.parent) ? row.parent : null;
    (children.get(parent) ?? children.set(parent, []).get(parent)!).push(row);
  }
  const visit = (parent: string | null, depth: number) => {
    for (const row of (children.get(parent) ?? []).sort((a, b) => a.start - b.start)) {
      row.depth = depth;
      rows.push(row);
      if (row.transaction?.kind === "run") {
        const steps = (children.get(row.id) ?? []).filter((child) => child.span).map((child) => [child.start, child.start + child.duration] as [number, number]);
        const gaps = uncovered(row.start, row.start + row.duration, steps);
        const total = gaps.reduce((sum, [, duration]) => sum + duration, 0);
        // A few milliseconds between steps is the cost of having steps; a stretch worth a row is one a person could feel.
        if (steps.length > 0 && total >= Math.max(row.duration * 0.01, 20)) {
          rows.push({ id: `${row.id}:untracked`, parent: row.id, depth: depth + 1, kind: "untracked", name: "no span covers this", resource: null, start: gaps[0]![0], duration: total, status: "ok", app: row.app, segments: gaps });
        }
      }
      visit(row.id, depth + 1);
    }
  };
  visit(null, 0);
  return rows;
}
