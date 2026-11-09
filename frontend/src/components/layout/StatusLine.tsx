import { useQuery } from "@tanstack/react-query";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { formatAgo, formatBytes, formatRate } from "@/lib/format";
import type { Status } from "@/types";
import { cn } from "@/lib/cn";

const POLL_MS = 10_000;

/**
 * The line along the bottom: is telemetry arriving, from how much of the
 * fleet, how fast, how much of the disk budget is spent, which build this
 * is. The place to look when a chart is empty and the question is "is it
 * them or is it us".
 */
export function StatusLine() {
  const status = useQuery({ queryKey: keys.status.line(), queryFn: () => api.get<Status>("/status"), refetchInterval: POLL_MS });
  const data = status.data;
  const stale = data?.last_seen_at ? data.now - data.last_seen_at > 60 : true;
  const budgetShare = data ? data.storage.used_bytes / Math.max(data.storage.budget_bytes, 1) : 0;

  return (
    <footer className="flex h-7 shrink-0 items-center gap-4 border-t border-border bg-surface px-3 text-[11px] text-muted">
      <span className="flex items-center gap-1.5">
        <span
          className={cn("inline-block h-1.5 w-1.5 rounded-full", data && !stale ? "bg-primary shadow-[0_0_6px_var(--color-primary)]" : "bg-muted")}
          aria-hidden
        />
        {status.isError ? "Status unavailable" : data ? (stale ? `Last report ${formatAgo(data.last_seen_at, data.now)}` : "Receiving") : "…"}
      </span>
      {data ? (
        <>
          <Cell label="apps" value={`${data.apps.reporting}/${data.apps.total}`} />
          <Cell label="processes" value={`${data.processes.live}`} />
          <Cell label="throughput" value={formatRate(data.throughput)} />
          <Cell
            label="storage"
            value={`${formatBytes(data.storage.used_bytes)} / ${formatBytes(data.storage.budget_bytes)}`}
            tone={budgetShare > 0.9 ? "warning" : undefined}
          />
          <span className="ml-auto hidden font-mono sm:inline">glass {data.release}</span>
        </>
      ) : null}
    </footer>
  );
}

function Cell({ label, value, tone }: { label: string; value: string; tone?: "warning" }) {
  return (
    <span className="hidden items-center gap-1 sm:flex">
      <span>{label}</span>
      <span className={cn("tabular font-mono text-foreground", tone === "warning" && "text-warning")}>{value}</span>
    </span>
  );
}
