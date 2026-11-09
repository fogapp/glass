import { useEffect, useId, useRef, useState, type CSSProperties, type KeyboardEvent as ReactKeyboardEvent, type PointerEvent as ReactPointerEvent, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { X } from "lucide-react";
import { cn } from "@/lib/cn";
import { IconButton } from "@/components/ui/IconButton";

/**
 * A side panel for a task that needs its own space but not its own page:
 * the request sheet, a rule editor, an episode's actions. Slides in from
 * the right on a wide screen and takes the whole screen on a phone
 * (attention tasks are designed at 390 px first).
 * Escape and the backdrop close it; focus lands on the panel when it
 * opens and returns to what opened it when it closes.
 *
 * On a wide screen its left edge can be dragged (or nudged with the arrow
 * keys) to widen it for a closer look; a double-click puts it back. The
 * width lasts while the sheet is open — it opens at its default next time.
 */
export function Sheet({
  open,
  onClose,
  title,
  description,
  children,
  footer,
  size = "md",
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  description?: string;
  children: ReactNode;
  footer?: ReactNode;
  size?: "md" | "lg";
}) {
  const panel = useRef<HTMLDivElement>(null);
  const opener = useRef<Element | null>(null);
  const titleId = useId();
  const [width, setWidth] = useState<number | null>(null);

  useEffect(() => {
    if (!open) return;
    opener.current = document.activeElement;
    panel.current?.focus();
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    document.addEventListener("keydown", onKeyDown);
    const { overflow } = document.body.style;
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", onKeyDown);
      document.body.style.overflow = overflow;
      if (opener.current instanceof HTMLElement) opener.current.focus();
    };
  }, [open, onClose]);

  if (!open) return null;

  const resizeTo = (next: number) => setWidth(clampWidth(next));

  const onHandlePointerDown = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (event.button !== 0) return;
    event.preventDefault();
    const handle = event.currentTarget;
    handle.setPointerCapture(event.pointerId);
    const { userSelect, cursor } = document.body.style;
    document.body.style.userSelect = "none";
    document.body.style.cursor = "col-resize";
    const onMove = (move: PointerEvent) => resizeTo(window.innerWidth - move.clientX);
    const onUp = () => {
      handle.removeEventListener("pointermove", onMove);
      handle.removeEventListener("pointerup", onUp);
      handle.removeEventListener("pointercancel", onUp);
      document.body.style.userSelect = userSelect;
      document.body.style.cursor = cursor;
    };
    handle.addEventListener("pointermove", onMove);
    handle.addEventListener("pointerup", onUp);
    handle.addEventListener("pointercancel", onUp);
  };

  const onHandleKeyDown = (event: ReactKeyboardEvent<HTMLDivElement>) => {
    const step = event.shiftKey ? 160 : 40;
    const current = panel.current?.offsetWidth ?? 0;
    if (event.key === "ArrowLeft") resizeTo(current + step);
    else if (event.key === "ArrowRight") resizeTo(current - step);
    else return;
    event.preventDefault();
  };

  return createPortal(
    <div className="fixed inset-0 z-40 flex justify-end">
      <button type="button" aria-label="Dismiss" className="absolute inset-0 bg-foreground/40" onClick={onClose} />
      <div
        ref={panel}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        tabIndex={-1}
        className={cn(
          "relative flex h-full w-full flex-col bg-surface shadow-xl outline-none md:border-l md:border-border",
          width === null ? (size === "lg" ? "md:max-w-2xl" : "md:max-w-lg") : "md:w-[var(--sheet-width)] md:max-w-[calc(100vw-3rem)]",
        )}
        style={width === null ? undefined : ({ "--sheet-width": `${width}px` } as CSSProperties)}
      >
        <div
          role="separator"
          aria-orientation="vertical"
          aria-label="Resize panel"
          title="Drag to resize · double-click to reset"
          tabIndex={0}
          onPointerDown={onHandlePointerDown}
          onDoubleClick={() => setWidth(null)}
          onKeyDown={onHandleKeyDown}
          className="absolute inset-y-0 -left-1 z-10 hidden w-2 cursor-col-resize touch-none outline-none after:absolute after:inset-y-0 after:left-[3px] after:w-0.5 after:bg-primary after:opacity-0 after:transition-opacity hover:after:opacity-100 focus-visible:after:opacity-100 md:block"
        />
        <header className="flex items-start justify-between gap-3 border-b border-border px-4 py-3 sm:px-6">
          <div className="min-w-0">
            <h2 id={titleId} className="text-base font-semibold text-foreground">
              {title}
            </h2>
            {description ? <p className="mt-0.5 text-sm text-muted">{description}</p> : null}
          </div>
          <IconButton label="Close" onClick={onClose} className="-mr-1">
            <X className="h-4 w-4" aria-hidden />
          </IconButton>
        </header>
        <div className="min-h-0 flex-1 overflow-y-auto px-4 py-4 sm:px-6">{children}</div>
        {footer ? <footer className="flex flex-wrap justify-end gap-2 border-t border-border px-4 py-3 sm:px-6">{footer}</footer> : null}
      </div>
    </div>,
    document.body,
  );
}

/** No narrower than a phone-sized column, no wider than leaves a strip of the list showing. */
function clampWidth(width: number): number {
  return Math.round(Math.min(Math.max(width, 384), window.innerWidth - 48));
}
