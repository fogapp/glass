import { useEffect, useState } from "react";
import { cn } from "@/lib/cn";

/**
 * The console's one transient-message surface.
 *
 * Exists because the UI is server-state-driven: a failed mutation refetches
 * the unchanged value and the control quietly snaps back, which reads as a
 * no-op rather than a failure. Queries have LoadingState/ErrorState; this is
 * the mutation-side counterpart, wired once through MutationCache.onError so
 * no individual button has to remember to report bad news.
 */

// Errors only for now: nothing has ever had good news urgent enough for a
// toast; "info" arrived with remediations — a bulk action that returns
// in 200ms needs one line saying what it did.
export type ToastKind = "error" | "info";
type ToastRecord = { id: number; kind: ToastKind; message: string };

let nextId = 0;
let listener: ((record: ToastRecord) => void) | null = null;

/** Imperative, so non-component code (the mutation cache) can speak. */
export const toast = {
  error(message: string) {
    listener?.({ id: nextId++, kind: "error", message });
  },
  info(message: string) {
    listener?.({ id: nextId++, kind: "info", message });
  },
};

const DISMISS_MS = 6_000;
const MAX_VISIBLE = 4;

export function Toasts() {
  const [toasts, setToasts] = useState<ToastRecord[]>([]);

  useEffect(() => {
    listener = (record) => {
      setToasts((current) => [...current.slice(-(MAX_VISIBLE - 1)), record]);
      window.setTimeout(
        () => setToasts((current) => current.filter((t) => t.id !== record.id)),
        DISMISS_MS,
      );
    };
    return () => {
      listener = null;
    };
  }, []);

  if (toasts.length === 0) return null;

  return (
    <div className="fixed inset-x-4 bottom-4 z-50 flex flex-col items-stretch gap-2 sm:inset-x-auto sm:right-4 sm:items-end">
      {toasts.map((t) => (
        <div
          key={t.id}
          role={t.kind === "error" ? "alert" : "status"}
          className={cn(
            "rounded-[var(--radius-card)] border bg-surface-raised px-3 py-2 text-sm shadow-lg sm:max-w-sm",
            t.kind === "error" ? "border-negative/50 text-negative" : "border-border text-foreground",
          )}
        >
          {t.message}
        </div>
      ))}
    </div>
  );
}
