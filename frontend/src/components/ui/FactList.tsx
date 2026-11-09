import type { ReactNode } from "react";
import { cn } from "@/lib/cn";

/**
 * A grid of labelled facts — the "This server" shape fog's System overview
 * uses. Facts are read, not edited: a small uppercase label over the value.
 */
export function FactList({
  children,
  className,
}: {
  children: ReactNode;
  className?: string;
}) {
  return (
    <dl
      className={cn(
        "grid grid-cols-2 gap-x-8 gap-y-3 text-sm md:grid-cols-3",
        className,
      )}
    >
      {children}
    </dl>
  );
}

export function Fact({
  label,
  value,
  hint,
  mono = true,
}: {
  label: string;
  value: ReactNode;
  /** A caveat about the value — why it is stale, where it moved to. */
  hint?: ReactNode;
  /** Paths, hashes, and versions read better in mono; prose does not. */
  mono?: boolean;
}) {
  return (
    <div className="min-w-0">
      <dt className="text-xs uppercase tracking-wide text-muted">{label}</dt>
      <dd
        className={cn(
          "mt-0.5 break-words text-foreground",
          mono && "font-mono text-sm",
        )}
      >
        {value}
      </dd>
      {hint ? <dd className="mt-0.5 text-xs text-muted">{hint}</dd> : null}
    </div>
  );
}
