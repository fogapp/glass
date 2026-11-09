import type { ReactNode } from "react";
import type { UseQueryResult } from "@tanstack/react-query";
import { cn } from "@/lib/cn";
import { apiErrorMessage } from "@/api/client";

/**
 * A chart's frame: a quiet title line, room for a control at the right, and
 * the three states a query can be in. A failed query is never an empty
 * chart — it says what went wrong and offers to retry.
 */
export function Panel({
  title,
  subtitle,
  actions,
  children,
  className,
  bodyClassName,
}: {
  title?: ReactNode;
  subtitle?: ReactNode;
  actions?: ReactNode;
  children: ReactNode;
  className?: string;
  bodyClassName?: string;
}) {
  return (
    <section className={cn("min-w-0 rounded-[var(--radius-card)] border border-border bg-surface", className)}>
      {title || actions ? (
        <header className="flex items-center justify-between gap-2 border-b border-border px-3 py-2">
          <div className="min-w-0">
            <h3 className="truncate text-xs font-semibold uppercase tracking-wider text-muted">{title}</h3>
            {subtitle ? <p className="truncate text-xs text-muted">{subtitle}</p> : null}
          </div>
          {actions ? <div className="flex shrink-0 items-center gap-1">{actions}</div> : null}
        </header>
      ) : null}
      <div className={cn("p-3", bodyClassName)}>{children}</div>
    </section>
  );
}

/** Renders a query's answer, or the state it is in, inside a Panel body. */
export function QueryBody<T>({
  query,
  height = 180,
  isEmpty,
  fill = false,
  children,
}: {
  query: UseQueryResult<T>;
  height?: number;
  /** The answer takes the whole body (a chart sized to its box). */
  fill?: boolean;
  isEmpty?: (data: T) => boolean;
  children: (data: T) => ReactNode;
}) {
  if (query.isError) {
    return (
      <div className="flex flex-col items-center justify-center gap-2 text-center text-xs text-muted" style={{ minHeight: height }}>
        <p className="text-negative">{apiErrorMessage(query.error, "Couldn't load this")}</p>
        <button type="button" className="underline hover:text-foreground" onClick={() => void query.refetch()}>
          Try again
        </button>
      </div>
    );
  }
  if (query.data === undefined) {
    return <div className="animate-pulse rounded bg-surface-raised/60" style={{ height }} aria-busy aria-label="Loading" />;
  }
  if (isEmpty?.(query.data)) {
    return (
      <div className="flex items-center justify-center text-xs text-muted" style={{ minHeight: height }}>
        No data in this range
      </div>
    );
  }
  return <div className={cn(fill && "h-full", query.isFetching && "opacity-90 transition-opacity")}>{children(query.data)}</div>;
}
