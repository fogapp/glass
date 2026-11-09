import { cn } from "@/lib/cn";
import { formatDateTime, formatTime } from "@/lib/format";
import type { Status, StatusRun } from "@/components/charts/statusRuns";

const FILLS: Record<Status, string> = {
  up: "bg-positive",
  down: "bg-negative",
  unknown: "bg-surface-raised",
};

const LABELS: Record<Status, string> = {
  up: "Up",
  down: "Down",
  unknown: "No reading",
};

/**
 * Up, down or unread across a range, as one band on the page's time axis.
 * Colour is not the only carrier: each stretch says what it is on hover,
 * and the page lists the outages beside it.
 */
export function StatusStrip({ runs, className }: { runs: StatusRun[]; className?: string }) {
  if (runs.length === 0) return null;
  const from = runs[0].from;
  const to = runs[runs.length - 1].to;
  const span = to - from;
  const down = runs.filter((run) => run.status === "down").length;
  return (
    <div className={className}>
      <div
        className="flex h-6 overflow-hidden rounded-[var(--radius-control)]"
        role="img"
        aria-label={down === 0 ? "Up for every reading in this range" : `Down ${down} ${down === 1 ? "time" : "times"} in this range`}
      >
        {runs.map((run) => (
          <span
            key={run.from}
            className={cn("min-w-px", FILLS[run.status])}
            style={{ flexGrow: run.to - run.from, flexBasis: 0 }}
            title={`${LABELS[run.status]} · ${formatDateTime(run.from)} – ${formatDateTime(run.to)}`}
          />
        ))}
      </div>
      <div className="tabular mt-1 flex justify-between font-mono text-[11px] text-muted">
        <span>{formatTime(from, span)}</span>
        <span>{formatTime(to, span)}</span>
      </div>
    </div>
  );
}
