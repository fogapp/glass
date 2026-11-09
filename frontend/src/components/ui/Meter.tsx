import { cn } from "@/lib/cn";

/**
 * A share as a small bar beside its figure (time consumed, spend, a
 * transition's share). `floor` keeps a sliver visible for a share that
 * rounds to nothing; the bar never passes full.
 */
export function Meter({ value, floor = 0, className }: { value: number; floor?: number; className?: string }) {
  const width = Math.min(Math.max(value, floor), 1) * 100;
  return (
    <span className={cn("block h-1.5 w-16 shrink-0 overflow-hidden rounded-full bg-surface-raised", className)} aria-hidden>
      <span className="block h-full rounded-full bg-primary" style={{ width: `${width}%` }} />
    </span>
  );
}
