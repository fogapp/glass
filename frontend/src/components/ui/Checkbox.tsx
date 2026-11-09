import type { InputHTMLAttributes, ReactNode } from "react";
import { cn } from "@/lib/cn";

interface CheckboxProps extends Omit<InputHTMLAttributes<HTMLInputElement>, "type" | "onChange" | "checked"> {
  checked: boolean;
  onChange: (checked: boolean) => void;
  /** Visible text beside the box. Leave it out and give an `aria-label`. */
  label?: ReactNode;
  /** The "some of these" state a select-all box shows. */
  indeterminate?: boolean;
}

/** A checkbox, labelled or bare. `className` lands on the label when there is one. */
export function Checkbox({ label, indeterminate = false, onChange, className, ...props }: CheckboxProps) {
  const box = (
    <input
      type="checkbox"
      ref={(element) => {
        if (element) element.indeterminate = indeterminate;
      }}
      onChange={(event) => onChange(event.target.checked)}
      className={cn(
        "h-4 w-4 shrink-0 cursor-pointer accent-primary disabled:cursor-not-allowed",
        label ? "mt-0.5" : className,
      )}
      {...props}
    />
  );
  if (!label) return box;
  return (
    <label className={cn("flex items-start gap-2 text-sm text-foreground", className)}>
      {box}
      <span>{label}</span>
    </label>
  );
}
