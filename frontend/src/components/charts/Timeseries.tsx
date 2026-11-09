import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import uPlot, { type AlignedData, type Options } from "uplot";
import { cn } from "@/lib/cn";
import { markersFor } from "@/lib/markers";
import { useScope } from "@/lib/scope";
import { formatDateTime, formatTick, formatTime, formatUnit, shortSha } from "@/lib/format";
import { seriesColor, seriesLabel } from "@/lib/seriesColors";
import type { App, Marker, TimeseriesResult } from "@/types";
import { slotColor, useChartTheme, withAlpha, type ChartTheme } from "@/components/charts/theme";

/** Every timeseries in the console shares one crosshair (dataviz: one time axis). */
export const CURSOR_SYNC_KEY = "glass";

export interface TimeseriesProps {
  result: TimeseriesResult;
  /** For an app-grouped series to wear its app's color. */
  apps?: App[];
  /** Vertical lines: deploys, incidents. */
  markers?: Marker[];
  height?: number;
  /** Take the height of the box it is in (legend included) instead of `height`. */
  fill?: boolean;
  /** Stack the series (throughput by endpoint) instead of overlaying them. */
  stacked?: boolean;
  /** Brushing a stretch of time asks for this range. */
  onBrush?: (from: number, to: number) => void;
  /** Clicking a point asks for what is behind it. */
  onPoint?: (time: number, step: number, series: TimeseriesResult["series"][number]) => void;
  /** Y axis from zero (counts, rates) or fitted (gauges). */
  fromZero?: boolean;
  className?: string;
  /** Hide the legend (a single series needs none). */
  legend?: boolean;
  /**
   * The slot (1..8) each series wears, in series order, for series that are
   * the same things on every chart they appear in — a run's phases — rather
   * than whatever a query happened to rank first.
   */
  slots?: number[];
}

interface Hover {
  time: number;
  left: number;
  values: { label: string; color: string; value: string }[];
  /** The marker lines under the cursor, nearest first. */
  markers: Marker[];
}

/** How close (CSS px) the cursor must come to a marker line to describe it. */
const MARKER_REACH = 6;

/** No markers, as one object: a fresh `[]` each render would rebuild the chart. */
const EMPTY_MARKERS: Marker[] = [];

function markerColor(theme: ChartTheme, kind: Marker["kind"]): string {
  return kind === "incident" ? theme.negative : kind === "deploy" ? theme.primary : theme.warning;
}

/**
 * The console's line chart: uPlot on a canvas, 2px lines with a 10% wash,
 * hairline grid, a crosshair synced across every chart on the page, deploy
 * markers, brush to zoom, click a point to pivot. Empty buckets are drawn
 * as gaps; a count's empty bucket is zero and arrives as one.
 */
export function Timeseries({
  result,
  apps,
  markers = EMPTY_MARKERS,
  height = 180,
  fill = false,
  stacked = false,
  onBrush,
  onPoint,
  fromZero = true,
  className,
  legend = true,
  slots,
}: TimeseriesProps) {
  const theme = useChartTheme();
  const showMarkers = useScope().markers;
  const container = useRef<HTMLDivElement>(null);
  const plot = useRef<uPlot | null>(null);
  /** What the live instance currently shows, so an update is applied once. */
  const shown = useRef<{ data: AlignedData; hidden: Set<number>; markers: Marker[] } | null>(null);
  const [hover, setHover] = useState<Hover | null>(null);
  const [hidden, setHidden] = useState<Set<number>>(() => new Set());
  const handlers = useRef({ onBrush, onPoint });
  handlers.current = { onBrush, onPoint };
  // Callers hand fresh closures each render; the chart cares only whether there is one.
  const brushable = Boolean(onBrush);
  const pointable = Boolean(onPoint);

  const unit = result.series[0]?.unit ?? null;
  const colors = useMemo(
    () => result.series.map((series, index) => (slots?.[index] ? slotColor(theme, slots[index] - 1) : seriesColor(theme, series, index, apps))),
    [result.series, theme, apps, slots],
  );

  // uPlot wants columns: x, then one y per series. Stacking is done here —
  // uPlot draws what it is given — and the tooltip reads the real values.
  const data = useMemo<AlignedData>(() => {
    const columns = result.series.map((series) => series.values.map((value) => (value === null ? null : value)));
    if (stacked) {
      const running = new Array<number>(result.times.length).fill(0);
      for (const column of columns) {
        for (let index = 0; index < column.length; index += 1) {
          const value = column[index];
          if (value === null || value === undefined) continue;
          running[index] = (running[index] ?? 0) + value;
          column[index] = running[index]!;
        }
      }
    }
    return [result.times, ...columns] as AlignedData;
  }, [result, stacked]);

  const span = result.to - result.from;
  const visibleMarkers = useMemo(() => (showMarkers ? markersFor(markers, result) : EMPTY_MARKERS), [showMarkers, markers, result]);

  // What the chart's hooks read at the moment they run: the instance
  // outlives a render, so it reads the latest through refs, never a capture.
  const latest = useRef({ result, data, colors, hidden, visibleMarkers, span, unit });
  useLayoutEffect(() => {
    latest.current = { result, data, colors, hidden, visibleMarkers, span, unit };
  });

  // What the canvas is built from. Anything else — new points, a legend
  // toggle, markers — updates the instance in place, so the crosshair and
  // hover survive a live refetch.
  const seriesKey = result.series.map((series) => `${series.key}\u0000${seriesLabel(series)}`).join("\u0001");
  const colorsKey = colors.join("|");
  const seriesCount = result.series.length;

  useEffect(() => {
    const element = container.current;
    if (!element) return;
    const { colors, hidden, result: initial } = latest.current;

    const options: Options = {
      width: element.clientWidth,
      height: fill ? element.clientHeight : height,
      padding: [8, 8, 0, 0],
      legend: { show: false },
      cursor: {
        sync: { key: CURSOR_SYNC_KEY, setSeries: false },
        drag: { x: brushable, y: false, setScale: false },
        points: { size: 8, fill: (self, index) => (self.series[index]?.stroke as () => string)?.() ?? theme.primary, stroke: theme.surface, width: 2 },
      },
      select: { show: brushable, left: 0, top: 0, width: 0, height: 0 },
      // Stacked: each series' wash reaches down only to the one beneath it.
      bands: stacked ? Array.from({ length: Math.max(seriesCount - 1, 0) }, (_, index) => ({ series: [index + 2, index + 1] as [number, number] })) : [],
      scales: {
        x: { time: true },
        y: { range: fromZero ? (_, min, max) => [Math.min(0, min), Math.max(max * 1.05, 1e-9)] : undefined },
      },
      axes: [
        {
          stroke: theme.muted,
          grid: { stroke: theme.grid, width: 1 },
          ticks: { show: false },
          font: `11px ${theme.sans}`,
          gap: 6,
          space: 72,
          values: (_, ticks) => ticks.map((tick) => formatTime(tick, latest.current.span)),
        },
        {
          stroke: theme.muted,
          grid: { stroke: theme.grid, width: 1 },
          ticks: { show: false },
          font: `11px ${theme.sans}`,
          size: 48,
          gap: 6,
          values: (_, ticks) => ticks.map((tick) => formatTick(tick, latest.current.unit)),
        },
      ],
      series: [
        { value: (_, raw) => formatDateTime(raw) },
        ...initial.series.map((series, index) => ({
          label: seriesLabel(series),
          stroke: colors[index],
          width: 2,
          fill: stacked ? withAlpha(colors[index]!, 0.35) : withAlpha(colors[index]!, 0.1),
          points: { show: false },
          spanGaps: false,
          show: !hidden.has(index),
        })),
      ],
      hooks: {
        // Deploys and incidents as hairlines the full height of the plot.
        draw: [
          (self) => {
            const visibleMarkers = latest.current.visibleMarkers;
            if (visibleMarkers.length === 0) return;
            const ctx = self.ctx;
            ctx.save();
            ctx.setLineDash([4, 4]);
            ctx.lineWidth = 1;
            for (const marker of visibleMarkers) {
              const x = self.valToPos(marker.ts, "x", true);
              ctx.strokeStyle = markerColor(theme, marker.kind);
              ctx.beginPath();
              ctx.moveTo(x, self.bbox.top);
              ctx.lineTo(x, self.bbox.top + self.bbox.height);
              ctx.stroke();
            }
            ctx.restore();
          },
        ],
        setSelect: [
          (self) => {
            if (self.select.width <= 0) return;
            const from = self.posToVal(self.select.left, "x");
            const to = self.posToVal(self.select.left + self.select.width, "x");
            self.setSelect({ left: 0, top: 0, width: 0, height: 0 }, false);
            if (to - from >= 10) handlers.current.onBrush?.(from, to);
          },
        ],
        setCursor: [
          (self) => {
            const index = self.cursor.idx;
            if (index === null || index === undefined || self.cursor.left === undefined || self.cursor.left < 0) {
              setHover(null);
              return;
            }
            const { result, colors, hidden, visibleMarkers } = latest.current;
            const time = result.times[index];
            if (time === undefined) return;
            const left = self.cursor.left;
            const near = visibleMarkers
              .map((marker) => ({ marker, distance: Math.abs(self.valToPos(marker.ts, "x") - left) }))
              .filter(({ distance }) => distance <= MARKER_REACH)
              .sort((a, b) => a.distance - b.distance)
              .map(({ marker }) => marker);
            setHover({
              time,
              left,
              markers: near,
              values: result.series.flatMap((series, position) => {
                if (hidden.has(position)) return [];
                const value = series.values[index];
                return [
                  {
                    label: seriesLabel(series),
                    color: colors[position]!,
                    value: value === null || value === undefined ? "—" : formatUnit(value, series.unit),
                  },
                ];
              }),
            });
          },
        ],
      },
    };

    const built = latest.current.data;
    const instance = new uPlot(options, built, element);
    plot.current = instance;
    shown.current = { data: built, hidden, markers: latest.current.visibleMarkers };

    const onClick = (event: MouseEvent) => {
      const index = instance.cursor.idx;
      const { result } = latest.current;
      const first = result.series[0];
      if (index === null || index === undefined || !first || event.shiftKey) return;
      const time = result.times[index];
      if (time !== undefined) handlers.current.onPoint?.(time, result.step, first);
    };
    instance.over.addEventListener("click", onClick);
    instance.over.style.cursor = pointable ? "pointer" : "crosshair";

    const observer = new ResizeObserver(() => {
      instance.setSize({ width: element.clientWidth, height: fill ? element.clientHeight : height });
    });
    observer.observe(element);

    return () => {
      observer.disconnect();
      instance.over.removeEventListener("click", onClick);
      instance.destroy();
      plot.current = null;
      shown.current = null;
    };
    // Rebuilt only when the chart's structure changes; `seriesKey` and
    // `colorsKey` stand for the series and their colors.
  }, [seriesKey, seriesCount, colorsKey, theme, height, stacked, fromZero, brushable, pointable, fill]);

  // New points: the same instance, fed. Stacked bands are columns of `data`
  // and the band pairs depend only on the series count, which rebuilds.
  useEffect(() => {
    const instance = plot.current;
    if (!instance || !shown.current || shown.current.data === data) return;
    shown.current.data = data;
    instance.setData(data);
  }, [data]);

  // A legend toggle shows or hides the series in place.
  useEffect(() => {
    const instance = plot.current;
    if (!instance || !shown.current || shown.current.hidden === hidden) return;
    const before = shown.current.hidden;
    shown.current.hidden = hidden;
    for (let index = 0; index < seriesCount; index += 1) {
      if (before.has(index) !== hidden.has(index)) instance.setSeries(index + 1, { show: !hidden.has(index) });
    }
  }, [hidden, seriesCount]);

  // Markers are read by the draw hook; a redraw picks them up.
  useEffect(() => {
    const instance = plot.current;
    if (!instance || !shown.current || shown.current.markers === visibleMarkers) return;
    shown.current.markers = visibleMarkers;
    instance.redraw(false);
  }, [visibleMarkers]);

  const toggle = (index: number) =>
    setHidden((current) => {
      const next = new Set(current);
      if (next.has(index)) next.delete(index);
      else next.add(index);
      return next;
    });

  return (
    <div className={cn("relative", fill && "flex h-full flex-col", className)}>
      <div ref={container} className={cn("w-full", fill && "min-h-0 flex-1 overflow-hidden")} style={fill ? undefined : { height }} />
      {hover && (hover.values.length > 0 || hover.markers.length > 0) ? (
        <Tooltip hover={hover} width={container.current?.clientWidth ?? 0} theme={theme} />
      ) : null}
      {legend && result.series.length > 1 ? (
        <ul className="mt-1 flex shrink-0 flex-wrap gap-x-3 gap-y-0.5 px-1 text-xs text-muted">
          {result.series.map((series, index) => (
            <li key={index}>
              <button
                type="button"
                onClick={() => toggle(index)}
                className={cn("inline-flex items-center gap-1.5 hover:text-foreground", hidden.has(index) && "line-through opacity-60")}
                aria-pressed={!hidden.has(index)}
              >
                <span className="inline-block h-2 w-2 rounded-full" style={{ background: colors[index] }} aria-hidden />
                <span className="max-w-64 truncate">{seriesLabel(series)}</span>
              </button>
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}

function Tooltip({ hover, width, theme }: { hover: Hover; width: number; theme: ChartTheme }) {
  // Flip to the left of the cursor near the right edge, so it never leaves
  // the chart.
  const flip = width > 0 && hover.left > width * 0.6;
  return (
    <div
      className="pointer-events-none absolute top-2 z-10 max-w-80 rounded-[var(--radius-control)] border border-border bg-surface/95 px-2.5 py-2 text-xs shadow-lg backdrop-blur"
      style={flip ? { right: width - hover.left + 12 } : { left: hover.left + 12 }}
    >
      {hover.markers.length > 0 ? (
        <ul className="mb-2 space-y-1 border-b border-border pb-2">
          {hover.markers.slice(0, 4).map((marker, index) => (
            <li key={`${marker.ts}-${index}`}>
              <p className="flex items-center gap-1.5 text-foreground">
                <span className="inline-block h-2 w-2 shrink-0 rounded-full" style={{ background: markerColor(theme, marker.kind) }} aria-hidden />
                <span className="truncate font-medium">{marker.title}</span>
              </p>
              <p className="pl-3.5 text-muted">
                {[marker.kind, marker.app, marker.release ? shortSha(marker.release) : null, formatDateTime(marker.ts)].filter(Boolean).join(" · ")}
              </p>
            </li>
          ))}
        </ul>
      ) : null}
      <p className="mb-1 text-muted">{formatDateTime(hover.time)}</p>
      <ul className="space-y-0.5">
        {hover.values.slice(0, 12).map((row) => (
          <li key={row.label} className="flex items-center justify-between gap-4">
            <span className="flex min-w-0 items-center gap-1.5 text-foreground">
              <span className="inline-block h-2 w-2 shrink-0 rounded-full" style={{ background: row.color }} aria-hidden />
              <span className="truncate">{row.label}</span>
            </span>
            <span className="tabular shrink-0 font-medium text-foreground" style={{ fontFamily: theme.mono }}>
              {row.value}
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}
