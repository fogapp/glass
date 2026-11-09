import { CheckCircle2, XCircle } from "lucide-react";
import { cn } from "@/lib/cn";
import { relativeTime } from "@/lib/time";

/** The one-line outcome of a Test or Check button, or the last recorded test. */
export function TestResultLine({
  ok,
  message,
  at,
  compact = false,
}: {
  ok: boolean | null;
  message: string | null;
  at?: string | null;
  /** The smaller size, for a line under a single field. */
  compact?: boolean;
}) {
  if (ok === null || !message) return null;
  const icon = cn("mt-0.5 shrink-0", compact ? "h-3.5 w-3.5" : "h-4 w-4");
  return (
    <p className={cn("flex items-start gap-1.5", compact ? "text-xs" : "text-sm", ok ? "text-positive" : "text-negative")}>
      {ok ? <CheckCircle2 className={icon} aria-hidden /> : <XCircle className={icon} aria-hidden />}
      <span>
        {message}
        {at ? <span className="text-muted"> · {relativeTime(at)}</span> : null}
      </span>
    </p>
  );
}
