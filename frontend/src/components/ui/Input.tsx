import type { InputHTMLAttributes, ReactNode } from "react";
import { cn } from "@/lib/cn";

interface InputProps extends InputHTMLAttributes<HTMLInputElement> {
  label?: string;
  hint?: string;
  /** Sits inside the field's leading edge — a search glyph, typically. */
  icon?: ReactNode;
}

export function Input({ label, hint, icon, className, id, ...props }: InputProps) {
  const inputId = id ?? props.name;
  return (
    <div className="space-y-1.5">
      {label ? (
        <label htmlFor={inputId} className="block text-sm font-medium text-foreground">
          {label}
        </label>
      ) : null}
      <div className="relative">
        {icon ? (
          <span
            aria-hidden
            className="pointer-events-none absolute left-3 top-1/2 flex -translate-y-1/2 text-muted"
          >
            {icon}
          </span>
        ) : null}
        <input
          id={inputId}
          className={cn(
            "h-9 w-full rounded-[var(--radius-control)] border border-border bg-input px-3",
            "text-base text-foreground placeholder:text-muted sm:text-sm",
            "disabled:opacity-50",
            icon && "pl-9",
            className,
          )}
          {...props}
        />
      </div>
      {hint ? <p className="text-xs text-muted">{hint}</p> : null}
    </div>
  );
}
