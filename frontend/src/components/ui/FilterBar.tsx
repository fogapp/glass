import type { ReactNode } from "react";
import { cn } from "@/lib/cn";

export interface FilterChipOption<K extends string> {
  key: K;
  label: string;
  /** A count beside the label, when the list knows it. */
  count?: number;
  icon?: ReactNode;
}

/**
 * A row of chips choosing one value (or, with `multiple`, any number) from
 * a small closed set — a kind facet, a status facet. The first option is
 * usually "All"; the value lives in the URL (useUrlEnum) so a filtered list
 * can be linked to and survives a refresh.
 */
export function FilterChips<K extends string>({
  options,
  value,
  onChange,
  label,
  multiple = false,
}: {
  options: readonly FilterChipOption<K>[];
  value: K | readonly K[];
  onChange: (next: K | K[]) => void;
  label: string;
  multiple?: boolean;
}) {
  const selected = new Set<K>(Array.isArray(value) ? (value as readonly K[]) : [value as K]);
  function toggle(key: K) {
    if (!multiple) return onChange(key);
    const next = new Set(selected);
    if (next.has(key)) next.delete(key);
    else next.add(key);
    onChange([...next]);
  }
  return (
    <div role="group" aria-label={label} className="scrollbar-none flex max-w-full items-center gap-1 overflow-x-auto">
      {options.map((option) => {
        const on = selected.has(option.key);
        return (
          <button
            key={option.key}
            type="button"
            aria-pressed={on}
            onClick={() => toggle(option.key)}
            className={cn(
              "inline-flex h-8 shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full border px-3 text-sm transition-colors",
              on ? "border-primary bg-primary/10 text-primary" : "border-border bg-surface text-muted hover:bg-surface-raised hover:text-foreground",
            )}
          >
            {option.icon}
            {option.label}
            {option.count !== undefined ? <span className="text-xs tabular-nums opacity-80">{option.count}</span> : null}
          </button>
        );
      })}
    </div>
  );
}
