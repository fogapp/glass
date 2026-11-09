import { useState } from "react";
import { formatCount, formatUnit } from "@/lib/format";
import type { HistogramResult } from "@/types";
import { useChartTheme } from "@/components/charts/theme";

/**
 * A distribution on a log scale: how many at each size. The second mode
 * an average hides. Bars capped at 24px, 2px surface gap, hover names the
 * bucket.
 */
export function Histogram({ result, height = 120, onBucket }: { result: HistogramResult; height?: number; onBucket?: (low: number, high: number) => void }) {
  const theme = useChartTheme();
  const [hover, setHover] = useState<number | null>(null);
  const { edges, counts, unit } = result;
  if (edges.length < 2) return <p className="py-6 text-center text-xs text-muted">No data in range</p>;

  const max = Math.max(...counts, 1);
  const total = counts.reduce((sum, count) => sum + count, 0);
  const width = 100 / counts.length;
  return (
    <div className="relative">
      <svg viewBox={`0 0 100 ${height}`} preserveAspectRatio="none" className="block w-full" style={{ height }} role="img" aria-label="Distribution">
        {counts.map((count, index) => {
          const barHeight = (count / max) * (height - 4);
          return (
            <rect
              key={index}
              x={index * width + 0.15}
              y={height - barHeight}
              width={width - 0.3}
              height={barHeight}
              fill={hover === index ? theme.primary : theme.series[0]}
              opacity={hover === null || hover === index ? 1 : 0.5}
              onMouseEnter={() => setHover(index)}
              onMouseLeave={() => setHover(null)}
              onClick={() => onBucket?.(edges[index]!, edges[index + 1]!)}
              style={{ cursor: onBucket ? "pointer" : "default" }}
            />
          );
        })}
      </svg>
      <div className="mt-1 flex justify-between text-[11px] text-muted">
        <span>{formatUnit(edges[0], unit)}</span>
        <span>{formatUnit(edges[Math.floor(edges.length / 2)], unit)}</span>
        <span>{formatUnit(edges[edges.length - 1], unit)}</span>
      </div>
      {hover !== null ? (
        <div className="pointer-events-none absolute left-1/2 top-1 -translate-x-1/2 rounded-[var(--radius-control)] border border-border bg-surface/95 px-2 py-1 text-xs text-foreground shadow">
          {formatUnit(edges[hover], unit)} – {formatUnit(edges[hover + 1], unit)}:{" "}
          <span className="font-medium">{formatCount(counts[hover])}</span>
          <span className="text-muted"> ({total > 0 ? ((counts[hover]! / total) * 100).toFixed(1) : 0}%)</span>
        </div>
      ) : null}
    </div>
  );
}
