import { useMemo } from "react";
import { cn } from "@/lib/cn";

/**
 * A 12-to-200-point line with no axes: the shape of a number, in a table
 * cell or a stat tile. SVG, so it scales with its box and costs nothing.
 */
export function Sparkline({
  values,
  color,
  width = 96,
  height = 24,
  fill = true,
  className,
}: {
  values: (number | null)[];
  color?: string;
  width?: number;
  height?: number;
  fill?: boolean;
  className?: string;
}) {
  const { line, area } = useMemo(() => {
    const points = values.map((value, index) => [index, value] as const).filter((point): point is readonly [number, number] => point[1] !== null);
    if (points.length < 2) return { line: "", area: "" };
    const max = Math.max(...points.map(([, value]) => value), 0);
    const min = Math.min(...points.map(([, value]) => value), 0);
    const span = max - min || 1;
    const x = (index: number) => (index / Math.max(values.length - 1, 1)) * width;
    const y = (value: number) => height - 2 - ((value - min) / span) * (height - 4);
    const path = points.map(([index, value], position) => `${position === 0 ? "M" : "L"}${x(index).toFixed(1)},${y(value).toFixed(1)}`).join(" ");
    const first = points[0]!;
    const last = points[points.length - 1]!;
    return { line: path, area: `${path} L${x(last[0]).toFixed(1)},${height} L${x(first[0]).toFixed(1)},${height} Z` };
  }, [values, width, height]);

  if (!line) return <span className={cn("inline-block", className)} style={{ width, height }} aria-hidden />;
  const stroke = color ?? "var(--color-primary)";
  return (
    <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`} className={cn("shrink-0", className)} aria-hidden>
      {fill ? <path d={area} fill={stroke} opacity={0.12} /> : null}
      <path d={line} fill="none" stroke={stroke} strokeWidth={1.5} strokeLinejoin="round" strokeLinecap="round" />
    </svg>
  );
}
