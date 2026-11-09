import { ScopedLink } from "@/components/scope/ScopedLink";
import { AppDot } from "@/components/scope/AppDot";
import { cn } from "@/lib/cn";
import { formatClock, formatMs, shortSha } from "@/lib/format";
import type { App, TransactionRow } from "@/types";

/**
 * Requests and jobs as rows: when, what, how long, what happened. Every
 * row opens its trace. Compact in a drawer; full in a page.
 */
export function TransactionList({
  rows,
  apps,
  compact = false,
  onSelect,
  selected,
}: {
  rows: TransactionRow[];
  apps: App[] | undefined;
  compact?: boolean;
  onSelect?: (row: TransactionRow) => void;
  selected?: string | null;
}) {
  if (rows.length === 0) return <p className="py-4 text-center text-xs text-muted">No requests or jobs match</p>;
  return (
    <ul className="divide-y divide-border">
      {rows.map((row) => {
        const app = apps?.find((candidate) => candidate.slug === row.app);
        const body = (
          <>
            <span className="tabular w-24 shrink-0 whitespace-nowrap font-mono text-[11px] text-muted">{formatClock(row.ts)}</span>
            <AppDot app={app} />
            <span className={cn("shrink-0 rounded px-1 font-mono text-[10px] uppercase", row.status === "error" ? "bg-negative/15 text-negative" : "bg-surface-raised text-muted")}>
              {row.kind === "request" ? (row.http_status ?? row.method ?? "req") : row.kind}
            </span>
            <span className="min-w-0 flex-1 truncate font-mono text-[13px] text-foreground">
              {row.name}
              {!compact && row.path ? <span className="ml-2 text-muted">{row.path}</span> : null}
            </span>
            {row.error ? <span className="hidden shrink-0 truncate text-xs text-negative sm:inline">{row.error}</span> : null}
            {row.n_plus_one ? <span className="shrink-0 rounded bg-warning/15 px-1 text-[10px] text-warning">N+1</span> : null}
            {!compact ? <span className="hidden font-mono text-[11px] text-muted lg:inline">{shortSha(row.release)}</span> : null}
            <span className="tabular w-16 shrink-0 text-right font-mono text-[13px] text-foreground">{formatMs(row.duration)}</span>
            {row.kept ? <span className="h-1.5 w-1.5 shrink-0 rounded-full bg-primary" title="trace kept" aria-label="trace kept" /> : <span className="h-1.5 w-1.5 shrink-0" aria-hidden />}
          </>
        );
        const className = cn(
          "flex w-full items-center gap-2 px-2 py-1.5 text-left hover:bg-surface-raised",
          selected === row.trace && "bg-primary/10",
        );
        return (
          <li key={`${row.trace}-${row.span}`}>
            {onSelect ? (
              <button type="button" onClick={() => onSelect(row)} className={className}>
                {body}
              </button>
            ) : (
              <ScopedLink to={`/traces/${row.trace}`} className={className}>
                {body}
              </ScopedLink>
            )}
          </li>
        );
      })}
    </ul>
  );
}
