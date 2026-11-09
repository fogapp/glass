import type { ReactNode } from "react";
import { cn } from "@/lib/cn";

interface ToggleProps {
  label: ReactNode;
  hint?: ReactNode;
  checked: boolean;
  onChange: (checked: boolean) => void;
  disabled?: boolean;
  name?: string;
}

/**
 * An on/off setting.
 *
 * A real checkbox underneath rather than a styled div: it stays keyboard
 * operable, announces its state to a screen reader, and works if the CSS
 * never loads. The visible track is decoration on top of it.
 */
export function Toggle({ label, hint, checked, onChange, disabled, name }: ToggleProps) {
  return (
    <label
      className={cn(
        "flex items-start gap-3",
        disabled ? "opacity-50" : "cursor-pointer",
      )}
    >
      <span className="relative mt-0.5 inline-flex shrink-0">
        <input
          type="checkbox"
          name={name}
          checked={checked}
          disabled={disabled}
          onChange={(event) => onChange(event.target.checked)}
          className="peer h-5 w-9 cursor-pointer appearance-none rounded-full bg-border transition-colors checked:bg-primary disabled:cursor-not-allowed"
        />
        <span
          aria-hidden
          className="pointer-events-none absolute left-0.5 top-0.5 h-4 w-4 rounded-full bg-surface transition-transform peer-checked:translate-x-4"
        />
      </span>
      <span className="min-w-0">
        <span className="block text-sm font-medium text-foreground">{label}</span>
        {hint ? <span className="mt-0.5 block text-xs text-muted">{hint}</span> : null}
      </span>
    </label>
  );
}
