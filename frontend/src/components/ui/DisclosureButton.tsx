import { ChevronRight } from "lucide-react";
import { cn } from "@/lib/cn";
import { IconButton } from "./IconButton";

/** The chevron that opens and closes a row's detail. */
export function DisclosureButton({
  open,
  onToggle,
  label = "Details",
  disabled,
  className,
}: {
  open: boolean;
  onToggle: () => void;
  /** Names what opens: "Details", "Evidence". */
  label?: string;
  disabled?: boolean;
  className?: string;
}) {
  return (
    <IconButton label={label} size="sm" aria-expanded={open} onClick={onToggle} disabled={disabled} className={className}>
      <ChevronRight className={cn("h-4 w-4 transition-transform", open && "rotate-90")} aria-hidden />
    </IconButton>
  );
}
