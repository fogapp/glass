import { ScopedLink } from "@/components/scope/ScopedLink";
import { cn } from "@/lib/cn";
import { formatClock, formatCount, formatMs, formatUsd } from "@/lib/format";
import { activeMs, phaseColor, phaseParts } from "@/lib/runs";
import { PhaseBar } from "@/components/charts/PhaseBar";
import type { TransactionRow } from "@/types";

/**
 * Runs as rows: when, who, where the person was, where the time went, what
 * it cost. Every row opens its trace. The duration shown is the active time
 * — how long the app took — with any wait on a person said beside it, so a
 * turn that sat on an approval does not read as a slow one.
 */
export function RunList({ rows, showAgent = true, emptyLabel = "No runs match" }: { rows: TransactionRow[]; showAgent?: boolean; emptyLabel?: string }) {
  if (rows.length === 0) return <p className="py-4 text-center text-xs text-muted">{emptyLabel}</p>;
  return (
    <ul className="divide-y divide-border">
      {rows.map((row) => {
        const parts = phaseParts(row).map(({ phase, value }) => ({ key: phase.key, label: phase.label, value, color: phaseColor(phase), hatched: phase.hatched }));
        const waited = Number(row.wait ?? 0);
        return (
          <li key={`${row.trace}-${row.span}`}>
            <ScopedLink to={`/traces/${row.trace}`} className="flex w-full items-center gap-2 px-2 py-1.5 text-left hover:bg-surface-raised">
              <span className="tabular w-24 shrink-0 whitespace-nowrap font-mono text-[11px] text-muted">{formatClock(row.ts)}</span>
              <span className={cn("w-16 shrink-0 truncate rounded px-1 text-center font-mono text-[10px] uppercase", row.status === "error" ? "bg-negative/15 text-negative" : "bg-surface-raised text-muted")} title={row.channel ? `on ${row.channel}` : `${row.trigger ?? "run"}`}>
                {row.channel ?? row.trigger ?? "run"}
              </span>
              {showAgent ? <span className="w-28 shrink-0 truncate font-mono text-[13px] text-foreground">{row.name}</span> : null}
              <PhaseBar parts={parts} format={formatMs} legend={false} height="h-2" className="hidden min-w-12 flex-1 sm:block" />
              {row.stop && row.stop !== "ok" ? <span className={cn("shrink-0 text-xs", row.status === "error" ? "text-negative" : "text-warning")}>{row.stop}</span> : null}
              <span className="tabular hidden w-16 shrink-0 text-right font-mono text-[11px] text-muted xl:inline">
                {formatCount(Number(row.tokens_in ?? 0) + Number(row.cache_read ?? 0) + Number(row.cache_write ?? 0))} tok
              </span>
              <span className="tabular w-14 shrink-0 text-right font-mono text-[11px] text-muted">{formatUsd(row.cost ?? 0)}</span>
              <span className="tabular w-16 shrink-0 text-right font-mono text-[13px] text-foreground" title={waited > 0 ? `plus ${formatMs(waited)} waiting on a person` : undefined}>
                {formatMs(activeMs(row))}
              </span>
            </ScopedLink>
          </li>
        );
      })}
    </ul>
  );
}
