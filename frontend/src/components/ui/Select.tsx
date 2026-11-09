import type { SelectHTMLAttributes } from "react";
import { cn } from "@/lib/cn";

interface SelectProps extends SelectHTMLAttributes<HTMLSelectElement> {
  label?: string;
  hint?: string;
}

export function Select({ label, hint, className, id, children, ...props }: SelectProps) {
  const selectId = id ?? props.name;
  return (
    <div className="space-y-1.5">
      {label ? (
        <label htmlFor={selectId} className="block text-sm font-medium text-foreground">
          {label}
        </label>
      ) : null}
      <select
        id={selectId}
        className={cn(
          "h-9 w-full rounded-[var(--radius-control)] border border-border bg-input px-3",
          "text-base text-foreground disabled:opacity-50 sm:text-sm",
          className,
        )}
        {...props}
      >
        {children}
      </select>
      {hint ? <p className="text-xs text-muted">{hint}</p> : null}
    </div>
  );
}
