import { cn } from "@/lib/cn";
import { ScopedLink } from "@/components/scope/ScopedLink";

export interface BarListRow {
  key: string;
  label: string;
  value: number;
  /** The figure as shown; the bar uses `value`. */
  display: string;
  /** A second, quieter figure at the right. */
  secondary?: string;
  color?: string;
  /** Where the row leads: the rows behind the figure (a link, so it opens in a new tab too). */
  href?: string;
  onClick?: () => void;
}

/**
 * A ranking: label, a bar proportional to the largest, the figure. Rows are
 * links (or buttons) when they lead somewhere. The bar is the mark; text stays in text
 * tokens (dataviz: text never wears the data color).
 */
export function BarList({ rows, className, emptyLabel = "Nothing yet" }: { rows: BarListRow[]; className?: string; emptyLabel?: string }) {
  const max = Math.max(...rows.map((row) => row.value), 0) || 1;
  if (rows.length === 0) return <p className={cn("py-4 text-center text-xs text-muted", className)}>{emptyLabel}</p>;
  return (
    <ul className={cn("space-y-1", className)}>
      {rows.map((row) => {
        const className = cn(
          "group flex w-full items-center gap-3 rounded-[var(--radius-control)] px-1.5 py-1 text-left text-sm",
          (row.href || row.onClick) && "hover:bg-surface-raised",
        );
        const body = (
          <>
              <span className="relative min-w-0 flex-1">
                <span
                  className="absolute inset-y-0 left-0 rounded-sm opacity-15"
                  style={{ width: `${(row.value / max) * 100}%`, background: row.color ?? "var(--color-primary)" }}
                  aria-hidden
                />
                <span className="relative block truncate px-1.5 py-0.5 font-mono text-[13px] text-foreground">{row.label}</span>
              </span>
              <span className="tabular shrink-0 font-mono text-[13px] text-foreground">{row.display}</span>
              {row.secondary ? <span className="tabular w-16 shrink-0 text-right text-xs text-muted">{row.secondary}</span> : null}
          </>
        );
        return (
          <li key={row.key}>
            {row.href ? (
              <ScopedLink to={row.href} className={className}>
                {body}
              </ScopedLink>
            ) : row.onClick ? (
              <button type="button" onClick={row.onClick} className={className}>
                {body}
              </button>
            ) : (
              <div className={className}>{body}</div>
            )}
          </li>
        );
      })}
    </ul>
  );
}
