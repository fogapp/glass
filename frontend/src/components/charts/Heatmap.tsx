import { useEffect, useMemo, useRef, useState } from "react";
import { formatCount, formatTime, formatUnit } from "@/lib/format";
import type { HeatmapResult } from "@/types";
import { useChartTheme } from "@/components/charts/theme";
import { useElementSize } from "@/hooks/useElementSize";

/**
 * Latency over time as a density: time across, value up (log scale), count
 * as depth of one hue. A canvas — a day at one-minute buckets is 50,000
 * cells. Hover names a cell; click asks for the requests in it.
 */
export function Heatmap({
  result,
  height = 200,
  onCell,
}: {
  result: HeatmapResult;
  height?: number;
  onCell?: (from: number, to: number, low: number, high: number) => void;
}) {
  const theme = useChartTheme();
  const canvas = useRef<HTMLCanvasElement>(null);
  const [box, size] = useElementSize<HTMLDivElement>();
  const [hover, setHover] = useState<{ time: number; bucket: number; count: number; x: number; y: number } | null>(null);
  const { times, edges, cells, unit, step } = result;
  const buckets = Math.max(edges.length - 1, 1);
  const axisWidth = 48;

  // Hover reads a cell per mouse move: look it up, never scan for it.
  const { counts, max } = useMemo(() => {
    const counts = new Map<number, number>();
    let max = 1;
    for (const [timeIndex, bucket, count] of cells) {
      if (count > max) max = count;
      if (bucket < 0 || bucket >= buckets) continue;
      const key = timeIndex * buckets + bucket;
      if (!counts.has(key)) counts.set(key, count);
    }
    return { counts, max };
  }, [cells, buckets]);

  useEffect(() => {
    const element = canvas.current;
    if (!element || size.width === 0) return;
    const dpr = window.devicePixelRatio || 1;
    element.width = size.width * dpr;
    element.height = height * dpr;
    const ctx = element.getContext("2d");
    if (!ctx) return;
    ctx.scale(dpr, dpr);
    ctx.clearRect(0, 0, size.width, height);

    const plotWidth = size.width - axisWidth;
    const plotHeight = height - 18;
    const cellWidth = plotWidth / Math.max(times.length, 1);
    const cellHeight = plotHeight / buckets;
    const steps = theme.heat;

    for (const [timeIndex, bucket, count] of cells) {
      const level = Math.min(steps.length - 1, Math.floor(Math.sqrt(count / max) * steps.length));
      ctx.fillStyle = steps[level]!;
      ctx.fillRect(axisWidth + timeIndex * cellWidth, plotHeight - (bucket + 1) * cellHeight, Math.max(cellWidth - 0.5, 0.5), Math.max(cellHeight - 0.5, 0.5));
    }

    ctx.fillStyle = theme.muted;
    ctx.font = `11px ${theme.sans}`;
    ctx.textAlign = "right";
    [0, 0.25, 0.5, 0.75, 1].forEach((fraction) => {
      const edge = edges[Math.round(fraction * buckets)];
      if (edge === undefined) return;
      ctx.fillText(formatUnit(edge, unit), axisWidth - 6, plotHeight - fraction * plotHeight + 4);
    });
    ctx.textAlign = "center";
    const labels = Math.max(2, Math.floor(plotWidth / 90));
    for (let index = 0; index < labels; index += 1) {
      const position = Math.round((index / (labels - 1)) * (times.length - 1));
      const time = times[position];
      if (time === undefined) continue;
      ctx.fillText(formatTime(time, result.to - result.from), axisWidth + (position + 0.5) * cellWidth, height - 4);
    }
  }, [size.width, height, times, edges, cells, max, unit, theme, buckets, result.from, result.to]);

  const locate = (event: React.MouseEvent<HTMLCanvasElement>) => {
    const rect = event.currentTarget.getBoundingClientRect();
    const x = event.clientX - rect.left - axisWidth;
    const y = event.clientY - rect.top;
    const plotWidth = size.width - axisWidth;
    const plotHeight = height - 18;
    if (x < 0 || y > plotHeight) return null;
    const timeIndex = Math.floor((x / plotWidth) * times.length);
    const bucket = Math.floor(((plotHeight - y) / plotHeight) * buckets);
    return { timeIndex, bucket };
  };

  return (
    <div ref={box} className="relative">
      <canvas
        ref={canvas}
        style={{ width: "100%", height, cursor: onCell ? "pointer" : "crosshair" }}
        role="img"
        aria-label="Latency heatmap"
        onMouseMove={(event) => {
          const at = locate(event);
          if (!at) return setHover(null);
          const count = at.bucket >= 0 && at.bucket < buckets ? (counts.get(at.timeIndex * buckets + at.bucket) ?? 0) : 0;
          setHover({ time: times[at.timeIndex] ?? 0, bucket: at.bucket, count, x: event.nativeEvent.offsetX, y: event.nativeEvent.offsetY });
        }}
        onMouseLeave={() => setHover(null)}
        onClick={(event) => {
          const at = locate(event);
          const time = at ? times[at.timeIndex] : undefined;
          if (!at || time === undefined) return;
          onCell?.(time, time + step, edges[at.bucket] ?? 0, edges[at.bucket + 1] ?? Number.POSITIVE_INFINITY);
        }}
      />
      {hover ? (
        <div
          className="pointer-events-none absolute z-10 rounded-[var(--radius-control)] border border-border bg-surface/95 px-2 py-1 text-xs shadow"
          style={{ left: Math.min(hover.x + 12, size.width - 180), top: Math.max(hover.y - 40, 0) }}
        >
          <p className="text-muted">{formatTime(hover.time, result.to - result.from)}</p>
          <p className="text-foreground">
            {formatUnit(edges[hover.bucket], unit)} – {formatUnit(edges[hover.bucket + 1], unit)} · <span className="font-medium">{formatCount(hover.count)}</span>
          </p>
        </div>
      ) : null}
    </div>
  );
}
