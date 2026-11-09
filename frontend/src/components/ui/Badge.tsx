import type { ReactNode } from "react";
import { cn } from "@/lib/cn";

/** Status tones are a closed vocabulary — never pass raw color classes. */
const TONES = {
  neutral: "bg-surface-raised text-muted border-border",
  info: "bg-primary/10 text-primary border-primary/20",
  success: "bg-positive/10 text-positive border-positive/20",
  warning: "bg-warning/10 text-warning border-warning/25",
  danger: "bg-negative/10 text-negative border-negative/20",
} as const;

export type BadgeTone = keyof typeof TONES;

export function Badge({
  tone = "neutral",
  children,
  className,
  title,
}: {
  tone?: BadgeTone;
  children: ReactNode;
  className?: string;
  title?: string;
}) {
  return (
    <span
      className={cn(
        "inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-xs font-medium",
        TONES[tone],
        className,
      )}
      title={title}
    >
      {children}
    </span>
  );
}
