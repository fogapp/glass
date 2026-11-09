import { cn } from "@/lib/cn";

export interface SegmentDescriptor<K extends string> {
  key: K;
  label: string;
  /** Spoken/hover form when the visible label is terse. */
  title?: string;
}

/**
 * A compact segmented control — one value from a small closed set, shown as
 * a row of joined buttons. Radio-group semantics underneath so it announces
 * as one control; built for dense rows where a Select would be too heavy.
 */
/** `sm` is the inline size for a settings row; `md` matches the h-9 of Input,
 *  Select, so a filter ribbon lines up. */
const SIZES = {
  sm: "h-6 px-2 text-xs",
  md: "h-9 px-3 text-sm",
} as const;

export function Segmented<K extends string>({
  segments,
  value,
  onChange,
  label,
  disabled,
  size = "sm",
}: {
  segments: readonly SegmentDescriptor<K>[];
  value: K;
  onChange: (key: K) => void;
  label: string;
  disabled?: boolean;
  size?: keyof typeof SIZES;
}) {
  function onKeyDown(event: React.KeyboardEvent) {
    if (event.key !== "ArrowRight" && event.key !== "ArrowLeft") return;
    event.preventDefault();
    const index = segments.findIndex((segment) => segment.key === value);
    const step = event.key === "ArrowRight" ? 1 : -1;
    const next = segments[(index + step + segments.length) % segments.length];
    onChange(next.key);
  }

  return (
    <div
      role="radiogroup"
      aria-label={label}
      onKeyDown={onKeyDown}
      className={cn(
        "scrollbar-none inline-flex max-w-full overflow-x-auto rounded-[var(--radius-control)] border border-border",
        disabled && "opacity-50",
      )}
    >
      {segments.map((segment, index) => {
        const selected = segment.key === value;
        return (
          <button
            key={segment.key}
            type="button"
            role="radio"
            aria-checked={selected}
            title={segment.title}
            tabIndex={selected ? 0 : -1}
            disabled={disabled}
            onClick={() => onChange(segment.key)}
            className={cn(
              "shrink-0 whitespace-nowrap transition-colors",
              SIZES[size],
              index > 0 && "border-l border-border",
              selected
                ? "bg-primary text-primary-foreground"
                : "bg-surface text-muted hover:bg-surface-raised hover:text-foreground",
              disabled && "cursor-not-allowed",
            )}
          >
            {segment.label}
          </button>
        );
      })}
    </div>
  );
}
