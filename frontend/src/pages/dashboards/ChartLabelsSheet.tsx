import { useId, useState, type FormEvent } from "react";
import { Sheet } from "@/components/ui/Sheet";
import { Input } from "@/components/ui/Input";
import { Checkbox } from "@/components/ui/Checkbox";
import { Segmented } from "@/components/ui/Segmented";
import { FormError, FormFooter } from "@/components/ui/Form";
import { useFormMutation } from "@/hooks/useFormMutation";
import { LABEL_PART_NAMES, labelPart, widgetLabels } from "@/lib/widgetLabels";
import { LABEL_PARTS, type LabelPart, type QueryAnswer, type QueryWidget } from "@/types";

/** What a person sets on a chart's labels. */
export type ChartLabels = Pick<QueryWidget, "title" | "subtitle" | "title_parts" | "subtitle_parts">;

type Mode = "query" | "custom";

interface LabelDraft {
  mode: Mode;
  text: string;
  parts: LabelPart[];
}

const MODES = [
  { key: "query", label: "From the query" },
  { key: "custom", label: "Custom" },
] as const;

/**
 * A chart's header and subheader, each either read from its query — the
 * parts picked, kept current as the query and the scope change — or text
 * of its own. The preview is the chart's own header line.
 */
export function ChartLabelsSheet({ widget, answer, onClose, onSave }: { widget: QueryWidget; answer?: QueryAnswer; onClose: () => void; onSave: (labels: ChartLabels) => Promise<unknown> }) {
  const [title, setTitle] = useState<LabelDraft>(() => draftOf(widget.title, widget.title_parts));
  const [subtitle, setSubtitle] = useState<LabelDraft>(() => draftOf(widget.subtitle, widget.subtitle_parts));
  const labels: ChartLabels = {
    title: title.mode === "custom" ? title.text.trim() : "",
    title_parts: title.parts,
    subtitle: subtitle.mode === "custom" ? subtitle.text.trim() : "",
    subtitle_parts: subtitle.parts,
  };
  // Custom with nothing typed would quietly read from the query; ask for the text instead.
  const incomplete = (title.mode === "custom" && !labels.title) || (subtitle.mode === "custom" && !labels.subtitle);
  const save = useFormMutation({ mutationFn: () => onSave(labels), onSuccess: onClose, fallback: "Couldn't save the labels." });
  const preview = widgetLabels({ ...widget, ...labels }, answer);

  return (
    <Sheet open onClose={onClose} title="Chart labels" description="Read them from the query, or write your own.">
      <form
        className="space-y-5"
        onSubmit={(event: FormEvent) => {
          event.preventDefault();
          if (!incomplete) save.mutate();
        }}
      >
        <LabelField name="Header" draft={title} onChange={setTitle} widget={widget} answer={answer} placeholder="Slow checkouts" maxLength={120} />
        <LabelField name="Subheader" draft={subtitle} onChange={setSubtitle} widget={widget} answer={answer} placeholder="p95 across every store" maxLength={200} />
        <div className="space-y-1.5">
          <p className="text-sm font-medium text-foreground">Preview</p>
          <div className="rounded-[var(--radius-card)] border border-border bg-surface px-3 py-2">
            <p className="truncate text-xs font-semibold uppercase tracking-wider text-muted">{preview.title}</p>
            {preview.subtitle ? <p className="truncate text-xs text-muted">{preview.subtitle}</p> : null}
          </div>
        </div>
        <FormError message={save.errorMessage} />
        <FormFooter label="Save labels" pending={save.isPending} disabled={incomplete} onCancel={onClose} />
      </form>
    </Sheet>
  );
}

function draftOf(text: string, parts: LabelPart[]): LabelDraft {
  return { mode: text.trim() ? "custom" : "query", text, parts };
}

function LabelField({
  name,
  draft,
  onChange,
  widget,
  answer,
  placeholder,
  maxLength,
}: {
  name: string;
  draft: LabelDraft;
  onChange: (draft: LabelDraft) => void;
  widget: QueryWidget;
  answer?: QueryAnswer;
  placeholder: string;
  maxLength: number;
}) {
  const id = useId();
  const toggle = (part: LabelPart, on: boolean) => onChange({ ...draft, parts: on ? [...draft.parts, part] : draft.parts.filter((each) => each !== part) });
  return (
    <fieldset className="space-y-2">
      <legend className="mb-1.5 text-sm font-medium text-foreground">{name}</legend>
      <Segmented label={`${name} from`} size="md" segments={MODES} value={draft.mode} onChange={(mode) => onChange({ ...draft, mode })} />
      {draft.mode === "custom" ? (
        <Input id={`${id}-text`} aria-label={name} value={draft.text} onChange={(event) => onChange({ ...draft, text: event.target.value })} placeholder={placeholder} maxLength={maxLength} autoFocus />
      ) : (
        <ul className="space-y-1">
          {LABEL_PARTS.map((part) => {
            const value = labelPart(widget, part, answer);
            return (
              <li key={part}>
                <Checkbox
                  checked={draft.parts.includes(part)}
                  onChange={(on) => toggle(part, on)}
                  label={
                    <span className="flex min-w-0 gap-2 text-sm">
                      <span className="text-foreground">{LABEL_PART_NAMES[part]}</span>
                      <span className="truncate text-muted">{value ?? "nothing here"}</span>
                    </span>
                  }
                />
              </li>
            );
          })}
        </ul>
      )}
    </fieldset>
  );
}
