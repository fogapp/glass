import type { ButtonHTMLAttributes } from "react";
import { cn } from "@/lib/cn";

const SIZES = {
  sm: "p-1",
  md: "p-1.5",
  lg: "p-2.5",
} as const;

interface IconButtonProps extends Omit<ButtonHTMLAttributes<HTMLButtonElement>, "aria-label"> {
  /** What the button does, for the people who can't see the icon. Required. */
  label: string;
  size?: keyof typeof SIZES;
}

/** A button that is only an icon. The label is required, so none ships unnamed. */
export function IconButton({ label, size = "md", type = "button", className, ...props }: IconButtonProps) {
  return (
    <button
      type={type}
      aria-label={label}
      className={cn(
        "inline-flex items-center justify-center rounded-[var(--radius-control)] text-muted transition-colors",
        "hover:bg-surface-raised hover:text-foreground disabled:pointer-events-none disabled:opacity-30",
        SIZES[size],
        className,
      )}
      {...props}
    />
  );
}
