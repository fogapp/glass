import { cn } from "@/lib/cn";
import { hatch } from "@/components/charts/hatch";

export interface PhasePart {
  key: string;
  label: string;
  value: number;
  /** A colour token, as a CSS value. */
  color: string;
  /** Drawn hatched: a stretch that belongs to someone else. */
  hatched?: boolean;
}

/**
 * Where a duration went: one bar, cut into the parts that add up to it, and
 * the parts named beneath. The same picture for a request (database · views
 * · external · app) and a run (queue · model · tools · waiting · …).
 */
export function PhaseBar({
  parts,
  format,
  legend = true,
  className,
  height = "h-3",
}: {
  parts: PhasePart[];
  format: (value: number) => string;
  legend?: boolean;
  className?: string;
  height?: string;
}) {
  const total = parts.reduce((sum, part) => sum + part.value, 0) || 1;
  const shown = parts.filter((part) => part.value > 0);
  return (
    <div className={className}>
      <div className={cn("flex overflow-hidden rounded-full bg-surface-raised", height)} role="img" aria-label={shown.map((part) => `${part.label} ${format(part.value)}`).join(", ") || "No time recorded"}>
        {shown.map((part) => (
          <span key={part.key} title={`${part.label} ${format(part.value)}`} style={{ width: `${(part.value / total) * 100}%`, background: part.hatched ? hatch(part.color) : part.color }} />
        ))}
      </div>
      {legend ? (
        <ul className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-xs">
          {parts.map((part) => (
            <li key={part.key} className="flex items-center gap-1.5 text-muted">
              <span className="inline-block h-2 w-2 rounded-full" style={{ background: part.hatched ? hatch(part.color) : part.color }} aria-hidden />
              {part.label} <span className="tabular font-mono text-foreground">{format(part.value)}</span>
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}
