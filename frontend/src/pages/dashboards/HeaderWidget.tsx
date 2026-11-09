import { useId, useState, type FormEvent, type ReactNode } from "react";
import { Ban } from "lucide-react";
import { Sheet } from "@/components/ui/Sheet";
import { Input } from "@/components/ui/Input";
import { Segmented } from "@/components/ui/Segmented";
import { FormError, FormFooter } from "@/components/ui/Form";
import { useFormMutation } from "@/hooks/useFormMutation";
import { HEADER_ICON_GLYPHS, HEADER_SIZE_STYLES } from "@/lib/headerIcons";
import { cn } from "@/lib/cn";
import { HEADER_ICONS, HEADER_SIZES, type HeaderWidget } from "@/types";

/** What a person sets on a header; its place is the grid's business. */
export type HeaderFields = Pick<HeaderWidget, "title" | "subtitle" | "size" | "icon">;

const BLANK: HeaderFields = { title: "", subtitle: "", size: "md", icon: null };

/**
 * A dashboard header: an icon, a line of text, and a quieter one under it,
 * naming the stretch of dashboard below. While editing it shows its box,
 * so it can be found to drag, and its controls.
 */
export function DashboardHeader({ header, editing = false, actions }: { header: HeaderFields; editing?: boolean; actions?: ReactNode }) {
  const style = HEADER_SIZE_STYLES[header.size];
  const Glyph = header.icon ? HEADER_ICON_GLYPHS[header.icon] : null;
  return (
    <div
      className={cn(
        "flex h-full items-center gap-3 overflow-hidden rounded-[var(--radius-card)] border px-1",
        editing ? "border-dashed border-border bg-surface/40 px-3" : "border-transparent",
      )}
    >
      {Glyph ? <Glyph className={cn("shrink-0 text-muted", style.icon)} aria-hidden /> : null}
      <div className="min-w-0 flex-1">
        <h2 className={cn("truncate text-foreground", style.title)}>{header.title}</h2>
        {header.subtitle ? <p className={cn("truncate text-muted", style.subtitle)}>{header.subtitle}</p> : null}
      </div>
      {actions ? <div className="flex shrink-0 items-center gap-1">{actions}</div> : null}
    </div>
  );
}

/** Adds a header, or changes one: its text, the line under it, its size and its icon. */
export function HeaderSheet({ header, onClose, onSave }: { header?: HeaderFields; onClose: () => void; onSave: (fields: HeaderFields) => Promise<unknown> }) {
  const form = useId();
  const [draft, setDraft] = useState<HeaderFields>(header ?? BLANK);
  const save = useFormMutation({ mutationFn: () => onSave({ ...draft, title: draft.title.trim(), subtitle: draft.subtitle.trim() }), onSuccess: onClose, fallback: "Couldn't save the header." });
  const set = (changes: Partial<HeaderFields>) => setDraft((current) => ({ ...current, ...changes }));

  return (
    <Sheet open onClose={onClose} title={header ? "Edit header" : "New header"} description="A heading for the widgets below it.">
      <form
        className="space-y-4"
        onSubmit={(event: FormEvent) => {
          event.preventDefault();
          if (draft.title.trim()) save.mutate();
        }}
      >
        <Input id={`${form}-title`} label="Header" value={draft.title} onChange={(event) => set({ title: event.target.value })} placeholder="Checkout" maxLength={120} required autoFocus />
        <Input id={`${form}-subtitle`} label="Subheader" value={draft.subtitle} onChange={(event) => set({ subtitle: event.target.value })} placeholder="What buyers see, from cart to receipt" maxLength={200} />
        <div className="space-y-1.5">
          <p className="text-sm font-medium text-foreground">Size</p>
          <Segmented
            label="Size"
            size="md"
            segments={HEADER_SIZES.map((size) => ({ key: size, label: HEADER_SIZE_STYLES[size].label, title: HEADER_SIZE_STYLES[size].name }))}
            value={draft.size}
            onChange={(size) => set({ size })}
          />
        </div>
        <fieldset className="space-y-1.5">
          <legend className="text-sm font-medium text-foreground">Icon</legend>
          <div className="grid grid-cols-8 gap-1">
            <IconChoice label="No icon" selected={draft.icon === null} onClick={() => set({ icon: null })}>
              <Ban className="h-4 w-4" aria-hidden />
            </IconChoice>
            {HEADER_ICONS.map((icon) => {
              const Glyph = HEADER_ICON_GLYPHS[icon];
              return (
                <IconChoice key={icon} label={icon.replace(/-/g, " ")} selected={draft.icon === icon} onClick={() => set({ icon })}>
                  <Glyph className="h-4 w-4" aria-hidden />
                </IconChoice>
              );
            })}
          </div>
        </fieldset>
        <div className="space-y-1.5">
          <p className="text-sm font-medium text-foreground">Preview</p>
          <div className="rounded-[var(--radius-card)] border border-border bg-background p-2" style={{ minHeight: 72 }}>
            <DashboardHeader header={{ ...draft, title: draft.title.trim() || "Header" }} />
          </div>
        </div>
        <FormError message={save.errorMessage} />
        <FormFooter label={header ? "Save header" : "Add header"} pending={save.isPending} disabled={!draft.title.trim()} onCancel={onClose} />
      </form>
    </Sheet>
  );
}

function IconChoice({ label, selected, onClick, children }: { label: string; selected: boolean; onClick: () => void; children: ReactNode }) {
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      aria-pressed={selected}
      onClick={onClick}
      className={cn(
        "flex h-8 items-center justify-center rounded-[var(--radius-control)] border transition-colors",
        selected ? "border-primary bg-primary/10 text-foreground" : "border-transparent text-muted hover:bg-surface-raised hover:text-foreground",
      )}
    >
      {children}
    </button>
  );
}
