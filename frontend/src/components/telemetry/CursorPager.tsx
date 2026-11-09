import { cn } from "@/lib/cn";

/** The footer of a list paged by cursor: back to the newest page, and on to older rows when there are any. */
export function CursorPager({ before, next, onChange, className }: { before: number | null; next: number | null | undefined; onChange: (before: number | null) => void; className?: string }) {
  return (
    <div className={cn("flex justify-between text-xs", className)}>
      {before ? (
        <button type="button" className="text-primary hover:underline" onClick={() => onChange(null)}>
          Back to newest
        </button>
      ) : (
        <span />
      )}
      {next ? (
        <button type="button" className="text-primary hover:underline" onClick={() => onChange(next)}>
          Older →
        </button>
      ) : null}
    </div>
  );
}
