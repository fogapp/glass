import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { Minimize2, Minus, Plus } from "lucide-react";
import { cn } from "@/lib/cn";
import { formatMs, formatPercent } from "@/lib/format";
import type { Flamegraph as FlamegraphData } from "@/types";
import { categoryColor, useChartTheme, withAlpha } from "@/components/charts/theme";
import { HOME, MAX_SCALE, ROW, ZOOM_STEP, clampView, fitScale, panBy, rowHeight, treeSize, zoomAt, type Extent, type View } from "@/components/charts/flamegraphView";
import { IconButton } from "@/components/ui/IconButton";
import { useElementSize } from "@/hooks/useElementSize";

/** A node of the tree, laid out: where it sits and what it holds. */
interface Frame {
  index: number;
  fn: number;
  parent: number;
  depth: number;
  /** Fraction of the focused root's width where the frame starts, and its width. */
  x0: number;
  x1: number;
  self: number;
  total: number;
  baseSelf: number;
  baseTotal: number;
}

/** The position marks along the frame's right and bottom edges. */
const THUMB = 3;
/** A press that travels less than this is a click, not a drag. */
const DRAG_SLOP = 4;
const KEY_PANS: Record<string, [number, number]> = {
  ArrowLeft: [-80, 0],
  ArrowRight: [80, 0],
  ArrowUp: [0, -ROW * 3],
  ArrowDown: [0, ROW * 3],
};

/**
 * An icicle chart of the merged call tree (root on top). Canvas: a busy
 * app's tree is tens of thousands of frames. Hover reads a frame; click
 * focuses it (its ancestors dim, its subtree fills the width); the search
 * box highlights every frame whose name matches.
 *
 * The frame is a window onto the tree (`flamegraphView`): drag or scroll to
 * move it, pinch or ⌘-scroll to zoom where the cursor is. Zooming in
 * stretches the tree sideways; zooming out shrinks the rows until a tree
 * deeper than the frame fits in it.
 *
 * In diff mode a frame's color says how its share moved between the
 * baseline and the range: warmer grew, cooler shrank.
 */
export function Flamegraph({
  data,
  search = "",
  focus,
  onFocus,
  height,
  className,
}: {
  data: FlamegraphData;
  search?: string;
  /** The node index to fill the width with; the root when absent. */
  focus?: number;
  onFocus?: (node: number | null) => void;
  height?: number;
  className?: string;
}) {
  const theme = useChartTheme();
  const canvas = useRef<HTMLCanvasElement>(null);
  const [box, { width }] = useElementSize<HTMLDivElement>();
  const [hover, setHover] = useState<{ frame: Frame; x: number; y: number } | null>(null);
  const [stored, setStored] = useState<View>(HOME);
  const [dragging, setDragging] = useState(false);
  const drag = useRef<{ x: number; y: number; moved: boolean } | null>(null);
  const dragged = useRef(false);

  const frames = useMemo(() => layout(data, focus ?? 0), [data, focus]);
  const byRow = useMemo(() => framesByRow(frames), [frames]);
  const rows = frames.reduce((max, frame) => Math.max(max, frame.depth), 0) + 1;
  const chartHeight = height ?? Math.min(Math.max(rows * ROW + 4, 120), 640);
  const query = search.trim().toLowerCase();

  const extent = useMemo<Extent>(() => ({ width, height: chartHeight, rows }), [width, chartHeight, rows]);
  const view = useMemo(() => clampView(stored, extent), [stored, extent]);
  // The wheel listener reads the view as it is, without being re-attached each time it moves.
  const viewRef = useRef(view);
  useLayoutEffect(() => {
    viewRef.current = view;
  }, [view]);
  const update = useCallback((change: (view: View) => View) => setStored((previous) => change(clampView(previous, extent))), [extent]);
  const fit = fitScale(extent);
  const tree = treeSize(view.scale, extent);
  const rowPx = rowHeight(view.scale);

  // A newly focused frame fills the width, so the sideways zoom starts over.
  const [focused, setFocused] = useState(focus);
  if (focused !== focus) {
    setFocused(focus);
    setStored({ scale: Math.min(view.scale, 1), x: 0, y: view.y });
  }

  useEffect(() => {
    const element = canvas.current;
    if (!element || width === 0) return;
    const dpr = window.devicePixelRatio || 1;
    element.width = width * dpr;
    element.height = chartHeight * dpr;
    const ctx = element.getContext("2d");
    if (!ctx) return;
    ctx.scale(dpr, dpr);
    ctx.clearRect(0, 0, width, chartHeight);
    ctx.font = `11px ${theme.mono}`;
    ctx.textBaseline = "middle";

    const labelled = rowPx >= 14;
    const gap = rowPx >= 8 ? 1 : 0;
    for (const frame of frames) {
      const y = Math.round(frame.depth * rowPx - view.y);
      const h = Math.round((frame.depth + 1) * rowPx - view.y) - y - gap;
      if (y + h <= 0 || y >= chartHeight) continue;
      const left = frame.x0 * tree.width - view.x;
      const right = left + Math.max((frame.x1 - frame.x0) * tree.width - 1, 0.5);
      if (right <= 0 || left >= width) continue;
      // Only the part inside the frame, so a label stays with what is visible.
      const x = Math.max(left, 0);
      const w = Math.min(right, width) - x;
      const fn = data.functions[frame.fn]!;
      const matches = query !== "" && fn.name.toLowerCase().includes(query);
      ctx.fillStyle = fillFor(frame, fn.category, data, theme, matches, query !== "");
      ctx.fillRect(x, y, w, h);
      if (labelled && w > 30) {
        ctx.fillStyle = theme.foreground;
        ctx.save();
        ctx.beginPath();
        ctx.rect(x + 3, y, w - 6, h);
        ctx.clip();
        ctx.fillText(fn.name, x + 4, y + h / 2);
        ctx.restore();
      }
    }

    // Where the frame sits in the tree, when the tree is larger than it.
    ctx.fillStyle = withAlpha(theme.foreground, 0.4);
    if (tree.height > chartHeight) {
      const length = Math.max((chartHeight / tree.height) * chartHeight, 16);
      ctx.fillRect(width - THUMB, (view.y / (tree.height - chartHeight)) * (chartHeight - length), THUMB, length);
    }
    if (tree.width > width) {
      const length = Math.max((width / tree.width) * width, 16);
      ctx.fillRect((view.x / (tree.width - width)) * (width - length), chartHeight - THUMB, length, THUMB);
    }
  }, [frames, width, chartHeight, theme, data, query, view, tree.width, tree.height, rowPx]);

  // React's wheel listener is passive; holding the page still takes a real one.
  useEffect(() => {
    const element = canvas.current;
    if (!element) return;
    const onWheel = (event: WheelEvent) => {
      const lines = event.deltaMode === WheelEvent.DOM_DELTA_LINE ? ROW : 1;
      if (event.ctrlKey || event.metaKey) {
        event.preventDefault();
        const rect = element.getBoundingClientRect();
        const factor = Math.exp(-Math.max(-50, Math.min(50, event.deltaY * lines)) * 0.01);
        update((current) => zoomAt(current, extent, current.scale * factor, event.clientX - rect.left, event.clientY - rect.top));
        return;
      }
      const sideways = event.shiftKey && event.deltaX === 0;
      const dx = (sideways ? event.deltaY : event.deltaX) * lines;
      const dy = sideways ? 0 : event.deltaY * lines;
      const view = viewRef.current;
      const moved = panBy(view, extent, dx, dy);
      if (moved.x === view.x && moved.y === view.y) return; // at an edge: the page scrolls
      event.preventDefault();
      update((current) => panBy(current, extent, dx, dy));
    };
    element.addEventListener("wheel", onWheel, { passive: false });
    return () => element.removeEventListener("wheel", onWheel);
  }, [extent, update]);

  const locate = useCallback(
    (event: React.MouseEvent<HTMLCanvasElement>) => {
      const rect = event.currentTarget.getBoundingClientRect();
      const x = (event.clientX - rect.left + view.x) / tree.width;
      const row = Math.floor((event.clientY - rect.top + view.y) / rowPx);
      return frameAt(byRow[row], x);
    },
    [byRow, view, tree.width, rowPx],
  );

  /** One step in or out around the middle of the frame, pausing at 100%. */
  const step = (factor: number) =>
    update((current) => {
      const target = current.scale * factor;
      const crossed = (current.scale < 1 && target > 1) || (current.scale > 1 && target < 1);
      return zoomAt(current, extent, crossed ? 1 : target, extent.width / 2, extent.height / 2);
    });
  const zoomIn = () => step(ZOOM_STEP);
  const zoomOut = () => step(1 / ZOOM_STEP);
  const reset = () => setStored(HOME);

  const endDrag = () => {
    dragged.current = drag.current?.moved ?? false;
    drag.current = null;
    setDragging(false);
  };

  return (
    <div ref={box} className={cn("relative", className)}>
      <canvas
        ref={canvas}
        className="block select-none outline-none focus-visible:ring-1 focus-visible:ring-primary"
        style={{ width: "100%", height: chartHeight, cursor: dragging ? "grabbing" : "pointer", touchAction: tree.height > chartHeight ? "none" : "pan-y" }}
        role="img"
        aria-label="Flamegraph"
        tabIndex={0}
        onPointerDown={(event) => {
          if (event.button !== 0) return;
          drag.current = { x: event.clientX, y: event.clientY, moved: false };
          dragged.current = false;
        }}
        onPointerMove={(event) => {
          const held = drag.current;
          if (!held) {
            const frame = locate(event);
            setHover(frame ? { frame, x: event.nativeEvent.offsetX, y: event.nativeEvent.offsetY } : null);
            return;
          }
          const dx = event.clientX - held.x;
          const dy = event.clientY - held.y;
          if (!held.moved) {
            if (Math.hypot(dx, dy) < DRAG_SLOP) return; // still a click
            held.moved = true;
            event.currentTarget.setPointerCapture(event.pointerId);
            setDragging(true);
            setHover(null);
          }
          held.x = event.clientX;
          held.y = event.clientY;
          update((current) => panBy(current, extent, -dx, -dy));
        }}
        onPointerUp={endDrag}
        onPointerCancel={endDrag}
        onPointerLeave={() => setHover(null)}
        onClick={(event) => {
          if (dragged.current) return;
          const frame = locate(event);
          if (!frame) return;
          onFocus?.(frame.index === 0 ? null : frame.index);
        }}
        onKeyDown={(event) => {
          if (event.metaKey || event.ctrlKey || event.altKey) return;
          const pan = KEY_PANS[event.key];
          if (pan) update((current) => panBy(current, extent, pan[0], pan[1]));
          else if (event.key === "+" || event.key === "=") zoomIn();
          else if (event.key === "-") zoomOut();
          else if (event.key === "0") reset();
          else return;
          event.preventDefault();
        }}
      />
      <div className="absolute bottom-2 right-2.5 flex items-center rounded-[var(--radius-control)] border border-border bg-surface/95 shadow-lg">
        {fit < 1 ? (
          <IconButton label="Fit the whole tree" title="Fit the whole tree" size="sm" disabled={view.scale <= fit} onClick={() => setStored({ scale: fit, x: 0, y: 0 })}>
            <Minimize2 className="h-3.5 w-3.5" aria-hidden />
          </IconButton>
        ) : null}
        <IconButton label="Zoom the flamegraph out" title="Zoom out (−)" size="sm" disabled={view.scale <= fit} onClick={zoomOut}>
          <Minus className="h-3.5 w-3.5" aria-hidden />
        </IconButton>
        <button
          type="button"
          aria-label="Reset the flamegraph's zoom"
          title="Reset zoom (0)"
          className="tabular min-w-10 px-1 text-center font-mono text-[11px] text-muted hover:text-foreground"
          onClick={reset}
        >
          {view.scale < 10 ? `${Math.round(view.scale * 100)}%` : `${Math.round(view.scale)}×`}
        </button>
        <IconButton label="Zoom the flamegraph in" title="Zoom in (+)" size="sm" disabled={view.scale >= MAX_SCALE} onClick={zoomIn}>
          <Plus className="h-3.5 w-3.5" aria-hidden />
        </IconButton>
      </div>
      {hover ? <FrameTip frame={hover.frame} data={data} x={hover.x} y={hover.y} width={width} /> : null}
    </div>
  );
}

function FrameTip({ frame, data, x, y, width }: { frame: Frame; data: FlamegraphData; x: number; y: number; width: number }) {
  const fn = data.functions[frame.fn]!;
  const total = data.total_ms || 1;
  const flip = x > width * 0.6;
  return (
    <div
      className="pointer-events-none absolute z-10 max-w-96 rounded-[var(--radius-control)] border border-border bg-surface/95 px-2.5 py-2 text-xs shadow-lg"
      style={flip ? { right: width - x + 8, top: y + 14 } : { left: x + 8, top: y + 14 }}
    >
      <p className="break-all font-mono text-foreground">{fn.name}</p>
      {fn.file ? (
        <p className="break-all text-muted">
          {fn.file}
          {fn.line ? `:${fn.line}` : ""}
        </p>
      ) : null}
      <dl className="tabular mt-1 grid grid-cols-[auto_1fr] gap-x-3 text-muted">
        <dt>total</dt>
        <dd className="text-foreground">
          {formatMs(frame.total)} · {formatPercent(frame.total / total)}
        </dd>
        <dt>self</dt>
        <dd className="text-foreground">
          {formatMs(frame.self)} · {formatPercent(frame.self / total)}
        </dd>
        {data.diff ? (
          <>
            <dt>baseline</dt>
            <dd className="text-foreground">
              {formatMs(frame.baseTotal)} · {formatPercent(frame.baseTotal / (data.baseline_total_ms || 1))}
            </dd>
          </>
        ) : null}
      </dl>
    </div>
  );
}

/**
 * Preorder nodes → placed frames. Widths are shares of the focused node;
 * ancestors of the focus span the full width so the path to it stays
 * readable.
 */
function layout(data: FlamegraphData, focus: number): Frame[] {
  const nodes = data.nodes;
  if (nodes.length === 0) return [];
  const focusTotal = Math.max(nodes[focus]?.[3] ?? 0, 1e-9);
  const frames: Frame[] = [];
  const byIndex = new Map<number, Frame>();

  // Ancestors of the focus, root first.
  const ancestors = new Set<number>();
  for (let cursor = focus; cursor >= 0; cursor = nodes[cursor]?.[1] ?? -1) ancestors.add(cursor);

  const cursorAt = new Map<number, number>(); // parent → next child's x0
  for (let index = 0; index < nodes.length; index += 1) {
    const [fn, parent, self, total, baseSelf = 0, baseTotal = 0] = nodes[index] as number[];
    const parentFrame = parent === undefined || parent < 0 ? null : byIndex.get(parent);
    if (parent !== undefined && parent >= 0 && !parentFrame) continue; // outside the focused subtree

    let x0: number;
    let x1: number;
    if (ancestors.has(index) && index !== focus) {
      x0 = 0;
      x1 = 1;
    } else if (index === focus) {
      x0 = 0;
      x1 = 1;
    } else if (parentFrame && (ancestors.has(parent!) && parent !== focus)) {
      continue; // a sibling branch of the focus path
    } else {
      const start = cursorAt.get(parent!) ?? parentFrame!.x0;
      const widthShare = (total ?? 0) / focusTotal;
      x0 = start;
      x1 = start + widthShare;
      cursorAt.set(parent!, x1);
    }
    const frame: Frame = {
      index,
      fn: fn as number,
      parent: parent as number,
      depth: parentFrame ? parentFrame.depth + 1 : 0,
      x0,
      x1,
      self: self ?? 0,
      total: total ?? 0,
      baseSelf,
      baseTotal,
    };
    byIndex.set(index, frame);
    frames.push(frame);
  }
  return frames;
}

/** Each row's frames, left to right, so a point is found by bisection. */
function framesByRow(frames: Frame[]): Frame[][] {
  const rows: Frame[][] = [];
  for (const frame of frames) (rows[frame.depth] ??= []).push(frame);
  for (const row of rows) row?.sort((a, b) => a.x0 - b.x0);
  return rows;
}

/** The frame of a row (sorted by x0) that holds x, a fraction of the width. */
function frameAt(row: Frame[] | undefined, x: number): Frame | null {
  if (!row || row.length === 0) return null;
  // The last frame starting at or before x.
  let low = 0;
  let high = row.length - 1;
  let found = -1;
  while (low <= high) {
    const middle = (low + high) >> 1;
    if (row[middle]!.x0 <= x) {
      found = middle;
      low = middle + 1;
    } else high = middle - 1;
  }
  // Frames that start together (an empty one beside a real one): any that holds x.
  for (let index = found; index >= 0 && row[index]!.x0 === row[found]!.x0; index -= 1) {
    const frame = row[index]!;
    if (x < frame.x1) return frame;
  }
  return null;
}

function fillFor(
  frame: Frame,
  category: string,
  data: Pick<FlamegraphData, "diff" | "total_ms" | "baseline_total_ms">,
  theme: ReturnType<typeof useChartTheme>,
  matches: boolean,
  searching: boolean,
): string {
  if (searching) return matches ? theme.warning : withAlpha(theme.muted, 0.3);
  if (data.diff) {
    // Share of each side's total — what the tooltip shows; the move is what the color says.
    const here = data.total_ms ? frame.total / data.total_ms : 0;
    const there = data.baseline_total_ms ? frame.baseTotal / data.baseline_total_ms : 0;
    const change = there === 0 ? (here > 0 ? 1 : 0) : (here - there) / Math.max(there, 1e-9);
    if (Math.abs(change) < 0.05) return withAlpha(theme.muted, 0.4);
    const strength = Math.min(Math.abs(change), 1);
    return withAlpha(change > 0 ? theme.negative : theme.series[0]!, 0.35 + strength * 0.6);
  }
  return withAlpha(categoryColor(theme, category), 0.78);
}

/**
 * Per-function self and total time across the tree, recursion counted once:
 * a node's total counts only when its function is not already on the path
 * above it. Nodes arrive in preorder, so the path is a stack.
 */
export function functionTotals(data: FlamegraphData): { fn: number; self: number; total: number; baseSelf: number; baseTotal: number }[] {
  const self = new Map<number, number>();
  const total = new Map<number, number>();
  const baseSelf = new Map<number, number>();
  const baseTotal = new Map<number, number>();
  const nodes = data.nodes;
  // The path from the root to the node before this one, and how often each function is on it.
  const path: number[] = [];
  const onPath = new Map<number, number>();
  const depthOf = new Int32Array(nodes.length).fill(-1);
  const leave = () => {
    const fn = nodes[path.pop()!]?.[0];
    if (fn !== undefined) onPath.set(fn, onPath.get(fn)! - 1);
  };
  const enter = (index: number) => {
    depthOf[index] = path.length;
    path.push(index);
    const fn = nodes[index]?.[0];
    if (fn !== undefined) onPath.set(fn, (onPath.get(fn) ?? 0) + 1);
  };

  for (let index = 0; index < nodes.length; index += 1) {
    const [fn, parent, s, t, bs = 0, bt = 0] = nodes[index] as number[];
    const hasParent = parent !== undefined && parent >= 0 && parent < index;
    if (!hasParent) {
      while (path.length > 0) leave();
    } else if (depthOf[parent]! >= 0 && path[depthOf[parent]!] === parent) {
      while (path.length > depthOf[parent]! + 1) leave();
    } else {
      // Not preorder after all: rebuild the path from the parent's ancestors.
      while (path.length > 0) leave();
      const chain: number[] = [];
      for (let cursor = parent, before = index; cursor >= 0 && cursor < before; before = cursor, cursor = nodes[cursor]?.[1] ?? -1) chain.push(cursor);
      for (let position = chain.length - 1; position >= 0; position -= 1) enter(chain[position]!);
    }
    if (fn !== undefined) {
      self.set(fn, (self.get(fn) ?? 0) + (s ?? 0));
      baseSelf.set(fn, (baseSelf.get(fn) ?? 0) + bs);
      if (!onPath.get(fn)) {
        total.set(fn, (total.get(fn) ?? 0) + (t ?? 0));
        baseTotal.set(fn, (baseTotal.get(fn) ?? 0) + bt);
      }
    }
    enter(index);
  }
  return Array.from(total.keys())
    .filter((fn) => fn !== 0)
    .map((fn) => ({ fn, self: self.get(fn) ?? 0, total: total.get(fn) ?? 0, baseSelf: baseSelf.get(fn) ?? 0, baseTotal: baseTotal.get(fn) ?? 0 }));
}
