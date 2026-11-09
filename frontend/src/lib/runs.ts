import type { App, TraceTransaction, TransactionRow } from "@/types";

/**
 * A run's phases (Telemetry::Work, kind `run`): the steps that add up to its
 * duration, in the order they happen, each with the categorical slot it
 * wears wherever a run's time is drawn — the stacked chart, the bar, the
 * waterfall. Slots are fixed here so "model" is the same colour on all three.
 */
export interface Phase {
  key: "queue" | "prep" | "model" | "tool" | "wait" | "deliver" | "untracked";
  /** The transactions field that holds it. */
  field: string;
  label: string;
  /** 1..8: the series slot (index.css `--color-series-N`). */
  slot: number;
  /** Drawn hatched: time that was a person's, not the app's. */
  hatched?: boolean;
}

export const RUN_PHASES: Phase[] = [
  { key: "queue", field: "queue_ms", label: "Waiting its turn", slot: 7 },
  { key: "prep", field: "prep", label: "Preparing", slot: 4 },
  { key: "model", field: "model_ms", label: "Model", slot: 1 },
  { key: "tool", field: "tool_ms", label: "Tools", slot: 3 },
  { key: "wait", field: "wait", label: "Waiting on a person", slot: 5, hatched: true },
  { key: "deliver", field: "deliver", label: "Delivering", slot: 2 },
  { key: "untracked", field: "untracked", label: "Untracked", slot: 8 },
];

export const phaseColor = (phase: Phase): string => `var(--color-series-${phase.slot})`;

/** What a query computes for the mean of each phase, in phase order. */
export const PHASE_COMPUTES = RUN_PHASES.map((phase) => `avg(${phase.field})`);

type RunLike = Pick<TransactionRow, "duration" | "queue_ms" | "prep" | "model_ms" | "tool_ms" | "wait" | "deliver"> | TraceTransaction;

/** A run's phases with their values, and what no phase accounts for. */
export function phaseParts(run: RunLike): { phase: Phase; value: number }[] {
  const value = (key: Phase["key"]): number => {
    switch (key) {
      case "queue": return Number(run.queue_ms ?? 0);
      case "prep": return Number(run.prep ?? 0);
      case "model": return Number(run.model_ms ?? 0);
      case "tool": return Number(run.tool_ms ?? 0);
      case "wait": return Number(run.wait ?? 0);
      case "deliver": return Number(run.deliver ?? 0);
      default: return 0;
    }
  };
  const parts = RUN_PHASES.filter((phase) => phase.key !== "untracked").map((phase) => ({ phase, value: value(phase.key) }));
  const accounted = parts.reduce((sum, part) => sum + part.value, 0);
  const untracked = RUN_PHASES.find((phase) => phase.key === "untracked")!;
  return [...parts, { phase: untracked, value: Math.max(Number(run.duration ?? 0) - accounted, 0) }];
}

/** How long the app took: the duration less the time spent waiting on a person. */
export const activeMs = (run: { duration: number; wait?: number | null }): number => Math.max(run.duration - Number(run.wait ?? 0), 0);

/**
 * The link out of Glass into the app's own console (App#link_template):
 * `{trace}` and any key the row carries — its `session`, its `@run` — are
 * filled in. Null when there is no template, or it names something this row
 * does not have.
 */
export function linkFor(app: App | undefined, row: { trace?: string | null; session?: string | null; attrs?: Record<string, unknown> }): string | null {
  const template = app?.link_template;
  if (!template) return null;
  let missing = false;
  const filled = template.replace(/\{([a-z_]{1,40})\}/g, (_, key: string) => {
    const value = key === "trace" ? row.trace : key === "session" ? row.session : row.attrs?.[key];
    if (value === null || value === undefined || value === "") {
      missing = true;
      return "";
    }
    return encodeURIComponent(String(value));
  });
  return missing ? null : filled;
}
