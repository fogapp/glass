import { X } from "lucide-react";

/** The fields a chart or a top list is grouped by: up to three. */
export function GroupEditor({ groups, options, onChange }: { groups: string[]; options: string[]; onChange: (next: string[]) => void }) {
  return (
    <div className="flex flex-wrap items-center gap-1">
      <span className="text-muted">by</span>
      {groups.map((group) => (
        <span key={group} className="flex items-center gap-1 rounded-[var(--radius-control)] border border-border bg-surface-raised px-1.5 py-0.5 font-mono text-xs text-foreground">
          {group}
          <button type="button" aria-label={`Remove ${group}`} onClick={() => onChange(groups.filter((entry) => entry !== group))} className="text-muted hover:text-foreground">
            <X className="h-3 w-3" aria-hidden />
          </button>
        </span>
      ))}
      {groups.length < 3 ? (
        <select
          value=""
          onChange={(event) => event.target.value && onChange([...groups, event.target.value])}
          aria-label="Group by"
          className="h-7 rounded-[var(--radius-control)] border border-border bg-input px-1.5 font-mono text-xs text-foreground"
        >
          <option value="">+ field</option>
          {options.filter((option) => !groups.includes(option)).map((option) => (
            <option key={option} value={option}>
              {option}
            </option>
          ))}
          <option value="@">@attribute…</option>
        </select>
      ) : null}
    </div>
  );
}
