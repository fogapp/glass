import { cn } from "@/lib/cn";
import type { App } from "@/types";

/** An app's colour, as the dot every list and legend uses for it. */
export function AppDot({ app, className, live }: { app: App | undefined; className?: string; live?: boolean }) {
  return (
    <span
      className={cn("inline-block h-2 w-2 shrink-0 rounded-full", className)}
      style={{
        background: app ? `var(--color-series-${app.color_slot})` : "var(--color-muted)",
        boxShadow: live ? `0 0 8px var(--color-series-${app?.color_slot ?? 1})` : undefined,
      }}
      aria-hidden
    />
  );
}

/** The CSS colour for an app's slot. */
export function appColor(app: App | undefined): string {
  return app ? `var(--color-series-${app.color_slot})` : "var(--color-muted)";
}
