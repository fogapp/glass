import type { ButtonHTMLAttributes } from "react";
import { cn } from "@/lib/cn";

/**
 * Variant maps are plain objects, not CVA — one dependency fewer, and the
 * shape is legible at a glance.
 */
const VARIANTS = {
  primary: "bg-primary text-primary-foreground hover:bg-primary-hover",
  secondary: "bg-surface-raised text-foreground border border-border hover:bg-border/40",
  ghost: "text-muted hover:text-foreground hover:bg-surface-raised",
  danger: "bg-negative text-negative-foreground hover:opacity-90",
} as const;

const SIZES = {
  sm: "h-8 px-3 text-sm gap-1.5",
  md: "h-9 px-4 text-sm gap-2",
  lg: "h-10 px-5 text-base gap-2",
} as const;

export type ButtonVariant = keyof typeof VARIANTS;
export type ButtonSize = keyof typeof SIZES;

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant;
  size?: ButtonSize;
}

export function Button({ variant = "primary", size = "md", className, ...props }: ButtonProps) {
  return (
    <button
      className={cn(
        "inline-flex items-center justify-center rounded-[var(--radius-control)] font-medium",
        "transition-colors disabled:pointer-events-none disabled:opacity-50",
        VARIANTS[variant],
        SIZES[size],
        className,
      )}
      {...props}
    />
  );
}
