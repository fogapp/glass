import { cn } from "@/lib/cn";
import { Button } from "./Button";

/** A form's failure, said beside the form. Renders nothing when there is none. */
export function FormError({ message, className }: { message: string | null | undefined; className?: string }) {
  if (!message) return null;
  return (
    <p role="alert" className={cn("text-sm text-negative", className)}>
      {message}
    </p>
  );
}

/** Submit, and optionally Cancel, at the foot of a form. */
export function FormFooter({
  label,
  pending,
  pendingLabel = "Saving…",
  disabled = false,
  onCancel,
}: {
  label: string;
  pending: boolean;
  pendingLabel?: string;
  disabled?: boolean;
  onCancel?: () => void;
}) {
  return (
    <div className="flex gap-2">
      <Button type="submit" disabled={pending || disabled}>
        {pending ? pendingLabel : label}
      </Button>
      {onCancel ? (
        <Button type="button" variant="ghost" onClick={onCancel}>
          Cancel
        </Button>
      ) : null}
    </div>
  );
}
