import { Check, Copy } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { useCopied } from "@/hooks/useCopied";

/**
 * A mono, truncating read-only value with a copy button — the shape every
 * tokened egress URL is handed over in. The two-second "Copied" flash is the
 * only state; the value itself never changes underneath the reader.
 */
export function CopyField({ value }: { value: string }) {
  const { copied, copy } = useCopied();

  return (
    <div className="flex items-center gap-2">
      <code className="min-w-0 flex-1 truncate rounded-[var(--radius-control)] border border-border bg-surface-raised px-3 py-2 font-mono text-xs text-foreground">
        {value}
      </code>
      <Button variant="secondary" size="sm" onClick={() => copy(value)}>
        {copied ? <Check className="h-4 w-4" aria-hidden /> : <Copy className="h-4 w-4" aria-hidden />}
        {copied ? "Copied" : "Copy"}
      </Button>
    </div>
  );
}
