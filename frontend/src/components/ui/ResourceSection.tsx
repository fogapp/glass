import { useState, type ReactNode } from "react";
import type { UseQueryResult } from "@tanstack/react-query";
import { Plus } from "lucide-react";
import { cn } from "@/lib/cn";
import { Button } from "./Button";
import { Card } from "./Card";
import { EmptyState, QueryState } from "./PageState";
import { SectionHeader } from "./SectionHeader";

/** Where a section's rows come from: a list query, or rows already in hand. */
type Rows<T> =
  | { query: UseQueryResult<T[]>; errorMessage: string; rows?: never }
  | { rows: readonly T[]; query?: never; errorMessage?: never };

type ResourceSectionProps<T> = Rows<T> & {
  title: ReactNode;
  description?: ReactNode;
  /** The header button that opens the add form ("Add indexer"). */
  addLabel: string;
  /** The add form. `close` folds it away — call it on save and on cancel. */
  form: (close: () => void) => ReactNode;
  /** Between the header and the add form: a secret just minted, a directory. */
  above?: ReactNode;
  /** What an empty list says. `offerAdd` repeats the add button inside it. */
  empty?: { title: string; description?: string; offerAdd?: boolean };
  /** Control the add form from outside — one form open across several sections. */
  adding?: boolean;
  onAddingChange?: (adding: boolean) => void;
  /** The section's vertical rhythm; `space-y-4` unless the page asks otherwise. */
  className?: string;
  /** The rows, as `ResourceRow`s; they sit in a divided list. */
  children: (rows: readonly T[]) => ReactNode;
};

/**
 * A settings list of things you configure — indexers, clients, tokens: a
 * header with an "Add X" toggle, the add form in a panel, and the rows. The
 * empty state stays out of the way while the add form is open, so the form
 * is not framed by a "nothing here yet" it is about to make untrue.
 */
export function ResourceSection<T>({
  title,
  description,
  addLabel,
  form,
  above,
  empty,
  adding: controlled,
  onAddingChange,
  className,
  children,
  ...source
}: ResourceSectionProps<T>) {
  const [own, setOwn] = useState(false);
  const adding = controlled ?? own;
  const setAdding = (next: boolean) => {
    if (controlled === undefined) setOwn(next);
    onAddingChange?.(next);
  };

  const emptyState =
    empty && !adding ? (
      <EmptyState
        title={empty.title}
        description={empty.description}
        action={
          empty.offerAdd === false ? undefined : (
            <Button size="sm" onClick={() => setAdding(true)}>
              {addLabel}
            </Button>
          )
        }
      />
    ) : undefined;
  const list = (rows: readonly T[]) => <ul className="divide-y divide-border">{children(rows)}</ul>;

  return (
    <section className={cn("space-y-4", className)}>
      <SectionHeader
        title={title}
        description={description}
        actions={
          <Button size="sm" variant="secondary" onClick={() => setAdding(!adding)}>
            <Plus className="h-4 w-4" aria-hidden /> {addLabel}
          </Button>
        }
      />
      {above}
      {adding ? <ResourcePanel>{form(() => setAdding(false))}</ResourcePanel> : null}
      {source.query ? (
        <QueryState query={source.query} errorMessage={source.errorMessage} empty={emptyState}>
          {list}
        </QueryState>
      ) : source.rows.length === 0 && emptyState ? (
        emptyState
      ) : (
        list(source.rows)
      )}
    </section>
  );
}

/** The boxed panel a resource's form sits in. */
export function ResourcePanel({ className, children }: { className?: string; children: ReactNode }) {
  return <Card className={cn("p-4", className)}>{children}</Card>;
}

const ROW_SPACING = {
  md: { row: "py-4", body: "mt-4" },
  sm: { row: "py-3", body: "mt-3" },
} as const;

interface ResourceRowProps {
  name: ReactNode;
  /** Beside the name: kind, health, counts. */
  badges?: ReactNode;
  /** Muted lines under the name, one per entry. */
  meta?: ReactNode[];
  /** The last thing that went wrong, in the negative tone. */
  error?: string | null;
  /** Buttons on the row's right: Test, Remove. */
  actions?: ReactNode;
  /** Between the row's header and its body: a test result, an edit form. */
  below?: ReactNode;
  /**
   * Given, the header is a button that shows and hides the body (with
   * `aria-expanded`). Left out, the row is static and its actions centre
   * against its text.
   */
  open?: boolean;
  onToggle?: () => void;
  /** Shown while open, in a panel unless `panel` is false. */
  children?: ReactNode;
  panel?: boolean;
  spacing?: keyof typeof ROW_SPACING;
}

/**
 * One configured thing in a `ResourceSection`: its name and badges, a muted
 * meta line or two, its last error, and its actions — with an expandable
 * body (usually its edit form) behind the header.
 */
export function ResourceRow({
  name,
  badges,
  meta = [],
  error,
  actions,
  below,
  open = false,
  onToggle,
  children,
  panel = true,
  spacing = "md",
}: ResourceRowProps) {
  const expandable = onToggle !== undefined;
  const Line = expandable ? "span" : "div";
  const lineGap = expandable ? "mt-1" : "mt-0.5";
  const text = (
    <>
      <Line className="flex flex-wrap items-center gap-2">
        <span className="font-semibold text-foreground">{name}</span>
        {badges}
      </Line>
      {meta.map((line, index) =>
        line === null || line === undefined || line === false ? null : (
          <Line key={index} className={cn(lineGap, "block text-xs text-muted")}>
            {line}
          </Line>
        ),
      )}
      {error ? <Line className={cn(lineGap, "block text-xs text-negative")}>{error}</Line> : null}
    </>
  );

  return (
    <li className={ROW_SPACING[spacing].row}>
      <div className={cn("flex flex-wrap justify-between gap-3", expandable ? "items-start" : "items-center")}>
        {expandable ? (
          <button type="button" onClick={onToggle} aria-expanded={open} className="min-w-0 flex-1 text-left">
            {text}
          </button>
        ) : (
          <div className="min-w-0">{text}</div>
        )}
        {actions ? <div className="flex flex-wrap items-center gap-2">{actions}</div> : null}
      </div>
      {below}
      {open && children ? (
        panel ? <ResourcePanel className={ROW_SPACING[spacing].body}>{children}</ResourcePanel> : children
      ) : null}
    </li>
  );
}
