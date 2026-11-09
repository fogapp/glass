import { useEffect, useId, useRef, useState, type ReactNode } from "react";
import { cn } from "@/lib/cn";

/**
 * A popover hung off a button, for the controls a page needs to keep but not
 * to show: settings that are set once and then left alone. The panel holds
 * arbitrary children rather than a list of menu items, because what gets
 * tucked away here is usually a small form (a want's priority and profile),
 * not a set of commands.
 *
 * Dismissal is a pointerdown outside, or Escape — or the panel's own
 * `close`, for a choice that is done once it is made.
 *
 * With an icon the trigger is the icon alone (the label is its accessible
 * name); without one the label is the trigger's text.
 */
const TRIGGER_SIZES = {
  default: "h-8 px-3 text-sm font-medium",
  compact: "px-2 py-1 text-xs",
} as const;

export function Menu({
  label,
  icon,
  children,
  align = "right",
  size = "default",
  className,
}: {
  /** Accessible name for the trigger — the panel's heading too. */
  label: string;
  icon?: ReactNode;
  children: ReactNode | ((close: () => void) => ReactNode);
  align?: "left" | "right";
  size?: keyof typeof TRIGGER_SIZES;
  className?: string;
}) {
  const [open, setOpen] = useState(false);
  const container = useRef<HTMLDivElement>(null);
  const panelId = useId();

  useEffect(() => {
    if (!open) return;
    const onPointerDown = (event: PointerEvent) => {
      if (!container.current?.contains(event.target as Node)) setOpen(false);
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") setOpen(false);
    };
    document.addEventListener("pointerdown", onPointerDown);
    document.addEventListener("keydown", onKeyDown);
    return () => {
      document.removeEventListener("pointerdown", onPointerDown);
      document.removeEventListener("keydown", onKeyDown);
    };
  }, [open]);

  return (
    <div ref={container} className={cn("relative", className)}>
      <button
        type="button"
        aria-expanded={open}
        aria-haspopup="true"
        aria-controls={open ? panelId : undefined}
        onClick={() => setOpen((value) => !value)}
        className={cn(
          "inline-flex items-center justify-center gap-1.5 rounded-[var(--radius-control)]",
          "border border-border bg-surface-raised transition-colors",
          TRIGGER_SIZES[size],
          open ? "text-foreground" : "text-muted hover:text-foreground",
        )}
      >
        {icon ?? label}
        {icon ? <span className="sr-only">{label}</span> : null}
      </button>

      {open ? (
        <div
          id={panelId}
          className={cn(
            "absolute top-full z-20 mt-1 w-64 max-w-[calc(100vw-2rem)] rounded-[var(--radius-card)] border border-border",
            "bg-surface-raised p-3 text-left shadow-lg",
            align === "right" ? "right-0" : "left-0",
          )}
        >
          <p className="mb-2 text-xs font-medium uppercase tracking-wide text-muted">{label}</p>
          {typeof children === "function" ? children(() => setOpen(false)) : children}
        </div>
      ) : null}
    </div>
  );
}
