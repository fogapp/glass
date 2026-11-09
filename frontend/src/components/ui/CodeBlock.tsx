import { Check, Copy } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { useCopied } from "@/hooks/useCopied";
import { cn } from "@/lib/cn";

/**
 * A scrollable block of raw text — a payload, a config, a transcript. The
 * block owns its overflow so wide content scrolls here rather than dragging
 * the page sideways. `copyable` adds a copy button beside it, for text meant
 * to be pasted somewhere else (a command, a config file).
 */
export function CodeBlock({ value, className, copyable = false }: { value: string; className?: string; copyable?: boolean }) {
  const { copied, copy } = useCopied();
  const block = (
    <pre
      className={cn(
        "max-h-96 overflow-auto rounded-[var(--radius-control)] border border-border",
        "bg-surface-raised px-3 py-2 font-mono text-xs leading-relaxed text-foreground",
        copyable && "min-w-0 flex-1",
        className,
      )}
    >
      {value}
    </pre>
  );
  if (!copyable) return block;

  return (
    <div className="flex items-start gap-2">
      {block}
      <Button variant="secondary" size="sm" onClick={() => copy(value)}>
        {copied ? <Check className="h-4 w-4" aria-hidden /> : <Copy className="h-4 w-4" aria-hidden />}
        {copied ? "Copied" : "Copy"}
      </Button>
    </div>
  );
}
