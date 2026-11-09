import { useEffect, useRef, useState, type KeyboardEvent, type PointerEvent, type ReactNode } from "react";
import { cn } from "@/lib/cn";
import { BREAKPOINTS, useMediaQuery } from "@/hooks/useMediaQuery";
import { useElementSize } from "@/hooks/useElementSize";
import { COLUMNS, compact, MAX_H, MIN_H, MIN_W, moveCell, nudgeCell, resizeCell, rows, sameLayout, type Cell } from "@/lib/dashboardLayout";

/** One row's height and the gutter between cells, in CSS px. */
export const ROW_HEIGHT = 30;
export const GAP = 12;

interface Gesture {
  id: string;
  mode: "move" | "resize";
  pointerX: number;
  pointerY: number;
  /** The layout when the gesture began; every step is computed from it. */
  base: Cell[];
}

/**
 * Cells on a twelve-column grid (`lib/dashboardLayout`). While `editing`, a
 * cell is dragged by anything in it that isn't a control and resized by its
 * bottom-right corner; it follows the pointer, a placeholder shows where it
 * will snap, and the rest make way as it goes. Arrows move a focused cell,
 * shift + arrows resize it, Esc abandons a drag. Below `lg` the cells stack
 * in reading order at their own heights, and there is nothing to drag.
 */
export function GridLayout({
  cells,
  editing,
  onChange,
  label,
  children,
}: {
  cells: Cell[];
  editing: boolean;
  /** A settled layout, once a gesture ends somewhere new. */
  onChange: (cells: Cell[]) => void;
  /** What a cell is, for the people who can't see it. */
  label: (id: string) => string;
  children: (cell: Cell) => ReactNode;
}) {
  const wide = useMediaQuery(BREAKPOINTS.lg);
  const [container, { width }] = useElementSize<HTMLDivElement>();
  const [gesture, setGesture] = useState<Gesture | null>(null);
  const [preview, setPreview] = useState<Cell[] | null>(null);
  const [offset, setOffset] = useState({ dx: 0, dy: 0 });

  const settled = compact(cells);
  const layout = preview ?? settled;
  const pitchX = (width + GAP) / COLUMNS;
  const pitchY = ROW_HEIGHT + GAP;
  const box = (cell: Cell) => ({ left: cell.x * pitchX, top: cell.y * pitchY, width: cell.w * pitchX - GAP, height: cell.h * pitchY - GAP });

  // The pointer is followed on the window, so a fast drag that leaves the
  // cell (or the page) is still the same drag.
  const latest = useRef({ preview, onChange });
  latest.current = { preview, onChange };
  useEffect(() => {
    if (!gesture) return;
    const start = gesture.base.find((cell) => cell.id === gesture.id);
    if (!start) return;
    const origin = { left: start.x * pitchX, top: start.y * pitchY, width: start.w * pitchX - GAP, height: start.h * pitchY - GAP };
    const finish = (commit: boolean) => {
      const next = latest.current.preview;
      if (commit && next && !sameLayout(next, gesture.base)) latest.current.onChange(next);
      setGesture(null);
      setPreview(null);
      setOffset({ dx: 0, dy: 0 });
    };
    const onMove = (event: globalThis.PointerEvent) => {
      const dx = event.clientX - gesture.pointerX;
      const dy = event.clientY - gesture.pointerY;
      if (gesture.mode === "move") {
        setOffset({ dx, dy });
        setPreview(moveCell(gesture.base, gesture.id, (origin.left + dx) / pitchX, (origin.top + dy) / pitchY));
      } else {
        // The cell keeps to the sizes it may take and to the grid's right
        // edge, so the corner stays under the pointer as far as it can.
        const within = (value: number, least: number, most: number) => Math.min(Math.max(value, least), most);
        setOffset({
          dx: within(dx, MIN_W * pitchX - GAP - origin.width, (COLUMNS - start.x) * pitchX - GAP - origin.width),
          dy: within(dy, (start.minH ?? MIN_H) * pitchY - GAP - origin.height, MAX_H * pitchY - GAP - origin.height),
        });
        setPreview(resizeCell(gesture.base, gesture.id, (origin.width + dx + GAP) / pitchX, (origin.height + dy + GAP) / pitchY));
      }
    };
    const onUp = () => finish(true);
    const onCancel = () => finish(false);
    const onKey = (event: globalThis.KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.stopPropagation();
      finish(false);
    };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
    window.addEventListener("pointercancel", onCancel);
    window.addEventListener("keydown", onKey, true);
    return () => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
      window.removeEventListener("pointercancel", onCancel);
      window.removeEventListener("keydown", onKey, true);
    };
  }, [gesture, pitchX, pitchY]);

  // Leaving edit mode mid-drag drops the drag.
  useEffect(() => {
    if (!editing) {
      setGesture(null);
      setPreview(null);
    }
  }, [editing]);

  const begin = (event: PointerEvent, id: string, mode: Gesture["mode"]) => {
    if (!editing || !wide || event.button !== 0) return;
    if (mode === "move" && (event.target as HTMLElement).closest("button, select, input, textarea, a, [data-grid-resize]")) return;
    event.preventDefault();
    event.stopPropagation();
    setGesture({ id, mode, pointerX: event.clientX, pointerY: event.clientY, base: settled });
    setPreview(settled);
  };

  const onKeyDown = (event: KeyboardEvent, cell: Cell) => {
    if (event.target !== event.currentTarget || gesture) return;
    const step = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }[event.key];
    if (!step) return;
    event.preventDefault();
    const [dx, dy] = step as [number, number];
    const next = event.shiftKey ? resizeCell(settled, cell.id, cell.w + dx, cell.h + dy) : nudgeCell(settled, cell.id, dx, dy);
    if (!sameLayout(next, settled)) onChange(next);
  };

  const active = gesture ? layout.find((cell) => cell.id === gesture.id) : undefined;
  const start = gesture ? gesture.base.find((cell) => cell.id === gesture.id) : undefined;
  if (!wide) {
    return (
      <div ref={container} className="grid gap-3">
        {[...settled]
          .sort((a, b) => a.y - b.y || a.x - b.x)
          .map((cell) => (
            <div key={cell.id} style={{ height: cell.h * pitchY - GAP }}>
              {children(cell)}
            </div>
          ))}
      </div>
    );
  }

  return (
    <div ref={container} className={cn("relative", editing && "select-none")} style={{ height: Math.max(rows(layout) * pitchY - GAP, 0) }}>
      {width > 0 && active ? (
        <div
          aria-hidden
          className="absolute left-0 top-0 rounded-[var(--radius-card)] border border-dashed border-primary bg-primary/10 motion-safe:transition-[transform,width,height] motion-safe:duration-150"
          style={{ transform: `translate(${box(active).left}px, ${box(active).top}px)`, width: box(active).width, height: box(active).height }}
        />
      ) : null}
      {width > 0
        ? layout.map((cell) => {
            const held = gesture?.id === cell.id && start;
            let place = box(cell);
            if (held && gesture.mode === "move") place = { ...box(start), left: box(start).left + offset.dx, top: box(start).top + offset.dy };
            if (held && gesture.mode === "resize") place = { ...box(start), width: box(start).width + offset.dx, height: box(start).height + offset.dy };
            return (
              <div
                key={cell.id}
                tabIndex={editing ? 0 : undefined}
                role={editing ? "group" : undefined}
                aria-roledescription={editing ? "movable widget" : undefined}
                aria-label={editing ? `${label(cell.id)} — arrows move it, shift and arrows resize it` : undefined}
                onPointerDown={(event) => begin(event, cell.id, "move")}
                onKeyDown={editing ? (event) => onKeyDown(event, cell) : undefined}
                className={cn(
                  "absolute left-0 top-0",
                  held ? "z-10 opacity-90 shadow-2xl" : "motion-safe:transition-[transform,width,height] motion-safe:duration-150",
                  editing && "touch-none rounded-[var(--radius-card)] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary",
                  editing && (held && gesture.mode === "move" ? "cursor-grabbing" : "cursor-grab"),
                )}
                style={{ transform: `translate(${place.left}px, ${place.top}px)`, width: place.width, height: place.height }}
              >
                {children(cell)}
                {editing ? (
                  <div
                    data-grid-resize
                    aria-hidden
                    onPointerDown={(event) => begin(event, cell.id, "resize")}
                    className="absolute bottom-0 right-0 flex h-5 w-5 cursor-nwse-resize items-end justify-end p-1 text-muted hover:text-foreground"
                  >
                    <svg viewBox="0 0 8 8" className="h-2.5 w-2.5" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round">
                      <path d="M7 1 1 7M7 4 4 7" />
                    </svg>
                  </div>
                ) : null}
              </div>
            );
          })
        : null}
    </div>
  );
}
