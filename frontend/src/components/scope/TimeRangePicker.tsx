import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { ChevronDown, ChevronLeft, ChevronRight, Flag, Radio, ZoomOut } from "lucide-react";
import { cn } from "@/lib/cn";
import { useScope } from "@/lib/scope";
import { RANGE_PRESETS, absoluteRange, describeRange, parseRange, shiftRange, zoomOut } from "@/lib/timeRange";
import { IconButton } from "@/components/ui/IconButton";
import { isTyping } from "@/lib/keyboard";

/** Pixels between the picker and its panel, and between the panel and the viewport's edge. */
const PANEL_GAP = 8;

/**
 * The time range and the live and markers toggles, in the scope bar.
 * Presets, a custom absolute window, step back and forward by one width,
 * zoom out. Keyboard: `t` opens it, `[` and `]` step, `l` toggles live, `m`
 * toggles the marker lines on every chart.
 */
export function TimeRangePicker() {
  const scope = useScope();
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLDivElement>(null);
  const panel = useRef<HTMLDivElement>(null);
  const [customFrom, setCustomFrom] = useState("");
  const [customTo, setCustomTo] = useState("");

  useEffect(() => {
    if (!open) return;
    const onClick = (event: MouseEvent) => {
      if (!root.current?.contains(event.target as Node)) setOpen(false);
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") setOpen(false);
    };
    document.addEventListener("mousedown", onClick);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onClick);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  // The scope bar scrolls sideways when it is too narrow, and a scroll
  // container clips whatever hangs below it — so the panel is fixed to the
  // viewport and placed under the picker by hand.
  useLayoutEffect(() => {
    if (!open) return;
    const place = () => {
      const anchor = root.current?.getBoundingClientRect();
      if (!anchor || !panel.current) return;
      panel.current.style.top = `${anchor.bottom + PANEL_GAP}px`;
      panel.current.style.right = `${Math.max(PANEL_GAP, document.documentElement.clientWidth - anchor.right)}px`;
    };
    place();
    window.addEventListener("resize", place);
    window.addEventListener("scroll", place, true);
    return () => {
      window.removeEventListener("resize", place);
      window.removeEventListener("scroll", place, true);
    };
  }, [open]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (isTyping(event)) return;
      if (event.key === "t") {
        event.preventDefault();
        setOpen((value) => !value);
      } else if (event.key === "[") scope.setRange(shiftRange(scope.range, -1));
      else if (event.key === "]") scope.setRange(shiftRange(scope.range, 1));
      else if (event.key === "l") scope.setLive(!scope.live && scope.range.relative !== null);
      else if (event.key === "m") scope.setMarkers(!scope.markers);
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [scope]);

  const applyCustom = () => {
    const from = Date.parse(customFrom) / 1000;
    const to = Date.parse(customTo) / 1000;
    if (Number.isFinite(from) && Number.isFinite(to) && to > from) {
      scope.setRange(absoluteRange(from, to));
      setOpen(false);
    }
  };

  return (
    <div ref={root} className="relative flex items-center gap-0.5">
      <IconButton label="Earlier (shortcut [)" size="sm" onClick={() => scope.setRange(shiftRange(scope.range, -1))}>
        <ChevronLeft className="h-4 w-4" aria-hidden />
      </IconButton>
      <button
        type="button"
        onClick={() => setOpen((value) => !value)}
        aria-expanded={open}
        className="flex h-8 items-center gap-1.5 rounded-[var(--radius-control)] border border-border bg-input px-2.5 text-sm text-foreground hover:bg-surface-raised"
      >
        <span className="tabular whitespace-nowrap">{describeRange(scope.range)}</span>
        <ChevronDown className="h-3.5 w-3.5 text-muted" aria-hidden />
      </button>
      <IconButton label="Later (shortcut ])" size="sm" onClick={() => scope.setRange(shiftRange(scope.range, 1))}>
        <ChevronRight className="h-4 w-4" aria-hidden />
      </IconButton>
      <IconButton label="Zoom out" size="sm" onClick={() => scope.setRange(zoomOut(scope.range))}>
        <ZoomOut className="h-4 w-4" aria-hidden />
      </IconButton>
      <button
        type="button"
        onClick={() => scope.setLive(!scope.live)}
        disabled={scope.range.relative === null}
        aria-pressed={scope.live}
        title={scope.range.relative === null ? "An absolute range cannot be live" : "Follow the clock (shortcut l)"}
        className={cn(
          "ml-1 flex h-8 items-center gap-1.5 rounded-[var(--radius-control)] border px-2.5 text-xs font-medium uppercase tracking-wider disabled:opacity-40",
          scope.live ? "border-primary/40 bg-primary/10 text-primary" : "border-border text-muted hover:text-foreground",
        )}
      >
        <Radio className={cn("h-3.5 w-3.5", scope.live && "animate-pulse")} aria-hidden />
        Live
      </button>
      <button
        type="button"
        onClick={() => scope.setMarkers(!scope.markers)}
        aria-pressed={scope.markers}
        title={scope.markers ? "Hide deploy and incident lines on charts (shortcut m)" : "Show deploy and incident lines on charts (shortcut m)"}
        className={cn(
          "flex h-8 items-center gap-1.5 rounded-[var(--radius-control)] border px-2.5 text-xs font-medium uppercase tracking-wider",
          scope.markers ? "border-primary/40 bg-primary/10 text-primary" : "border-border text-muted hover:text-foreground",
        )}
      >
        <Flag className="h-3.5 w-3.5" aria-hidden />
        Markers
      </button>

      {open ? (
        <div ref={panel} className="fixed z-30 w-72 max-w-[calc(100vw-1rem)] rounded-[var(--radius-card)] border border-border bg-surface p-2 shadow-xl">
          <ul className="grid grid-cols-2 gap-1">
            {RANGE_PRESETS.map((preset) => (
              <li key={preset.key}>
                <button
                  type="button"
                  onClick={() => {
                    scope.setRange(parseRange(preset.key));
                    setOpen(false);
                  }}
                  className={cn(
                    "w-full rounded-[var(--radius-control)] px-2 py-1.5 text-left text-sm hover:bg-surface-raised",
                    scope.range.relative === preset.key ? "bg-primary/10 text-primary" : "text-foreground",
                  )}
                >
                  Last {preset.label}
                </button>
              </li>
            ))}
          </ul>
          <div className="mt-2 border-t border-border pt-2">
            <p className="mb-1 text-xs text-muted">Custom</p>
            <div className="flex flex-col gap-1">
              <input
                type="datetime-local"
                aria-label="From"
                value={customFrom}
                onChange={(event) => setCustomFrom(event.target.value)}
                className="h-8 rounded-[var(--radius-control)] border border-border bg-input px-2 text-xs text-foreground"
              />
              <input
                type="datetime-local"
                aria-label="To"
                value={customTo}
                onChange={(event) => setCustomTo(event.target.value)}
                className="h-8 rounded-[var(--radius-control)] border border-border bg-input px-2 text-xs text-foreground"
              />
              <button
                type="button"
                onClick={applyCustom}
                className="h-8 rounded-[var(--radius-control)] bg-primary text-xs font-medium text-primary-foreground hover:bg-primary-hover"
              >
                Apply
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}
