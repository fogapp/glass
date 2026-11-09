import type { ReactNode } from "react";
import { Sparkline } from "@/components/charts/Sparkline";
import { ScopedLink } from "@/components/scope/ScopedLink";
import { cn } from "@/lib/cn";

const SPARK_TONE = { negative: "var(--color-negative)", warning: "var(--color-warning)" } as const;

/**
 * One figure in a row of them at the head of a page: a small label, the
 * value, and under it — when there is something to say — what the value
 * leaves out. `tone` marks a figure that is past where it should be, and
 * its sparkline with it; `spark` draws the figure's course over the range
 * beside it; `to` is the rows behind it (a scoped path, usually an
 * Explorer link), and makes the whole card a link.
 */
export function Kpi({
  label,
  value,
  hint,
  tone,
  spark,
  to,
}: {
  label: string;
  value: ReactNode;
  hint?: ReactNode;
  tone?: "negative" | "warning";
  spark?: (number | null)[];
  to?: string;
}) {
  const body = (
    <>
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="text-[11px] font-semibold uppercase tracking-wider text-muted">{label}</p>
          <p className={cn("tabular mt-1 text-2xl font-semibold text-foreground", tone === "negative" && "text-negative", tone === "warning" && "text-warning")}>{value}</p>
        </div>
        {spark ? <Sparkline values={spark} width={88} height={28} color={tone ? SPARK_TONE[tone] : undefined} /> : null}
      </div>
      {hint ? <p className="mt-0.5 truncate text-xs text-muted">{hint}</p> : null}
    </>
  );
  const className = "block rounded-[var(--radius-card)] border border-border bg-surface px-4 py-3";
  return to ? (
    <ScopedLink to={to} className={cn(className, "hover:border-primary/40")}>
      {body}
    </ScopedLink>
  ) : (
    <div className={className}>{body}</div>
  );
}
