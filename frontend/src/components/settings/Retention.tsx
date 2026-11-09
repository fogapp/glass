import { useQuery } from "@tanstack/react-query";
import { api } from "@/api/client";
import { useDraft } from "@/hooks/useDraft";
import { useFormMutation } from "@/hooks/useFormMutation";
import { keys } from "@/lib/queryKeys";
import { formatBytes } from "@/lib/format";
import { FormError, FormFooter } from "@/components/ui/Form";
import { Input } from "@/components/ui/Input";
import { QueryState } from "@/components/ui/PageState";
import { SectionHeader } from "@/components/ui/SectionHeader";
import { useSettings } from "@/components/settings/Notifications";
import type { Settings, StorageReport } from "@/types";
import { cn } from "@/lib/cn";

/**
 * Settings › Retention & storage: how long each signal is kept, the disk
 * budget, and what is on disk today by signal and by day.
 */
export function Retention() {
  const settings = useSettings();
  const storage = useQuery({ queryKey: keys.settings.storage(), queryFn: () => api.get<StorageReport>("/storage"), refetchInterval: 60_000 });
  return (
    <div className="space-y-8">
      <QueryState query={settings} errorMessage="Couldn't load settings.">
        {(data) => <RetentionForm settings={data} />}
      </QueryState>
      <QueryState query={storage} errorMessage="Couldn't read storage.">
        {(report) => <StorageView report={report} />}
      </QueryState>
    </div>
  );
}

function RetentionForm({ settings }: { settings: Settings }) {
  const { draft, set } = useDraft({
    disk_budget_mb: settings.disk_budget_mb,
    days: Object.fromEntries(settings.retention.map((row) => [row.table, row.days])) as Record<string, number>,
  });
  const save = useFormMutation<Settings, void>({
    mutationFn: () => api.patch<Settings>("/app_setting", { disk_budget_mb: draft.disk_budget_mb, retention_days: draft.days }),
    meta: { invalidates: [keys.settings.all] },
    fallback: "Couldn't save.",
  });
  return (
    <form
      onSubmit={(event) => {
        event.preventDefault();
        save.mutate();
      }}
      className="max-w-2xl space-y-4"
    >
      <SectionHeader
        title="Retention"
        description="Telemetry is kept in day partitions; retention is dropping a day, instantly. Over the disk budget, the oldest days of the most expendable signals go first, and it is written up in Activity."
      />
      <div className="grid gap-3 sm:grid-cols-2">
        {settings.retention.map((row) => (
          <Input
            key={row.table}
            label={row.label}
            hint={`default ${row.default_days} · at most ${row.max_days} days`}
            type="number"
            min={1}
            max={row.max_days}
            value={draft.days[row.table] ?? row.days}
            onChange={(event) => set("days", { ...draft.days, [row.table]: Number(event.target.value) })}
          />
        ))}
        <Input label="Disk budget (MB)" hint="What telemetry may use on the Postgres fog shares with every app." type="number" min={256} value={draft.disk_budget_mb} onChange={(event) => set("disk_budget_mb", Number(event.target.value))} />
      </div>
      <FormError message={save.errorMessage} />
      <FormFooter label="Save" pending={save.isPending} />
    </form>
  );
}

function StorageView({ report }: { report: StorageReport }) {
  const share = report.used_bytes / Math.max(report.budget_bytes, 1);
  return (
    <section className="space-y-3">
      <SectionHeader title="On disk" description={`${formatBytes(report.used_bytes)} of the ${formatBytes(report.budget_bytes)} budget.`} />
      <div className="h-2 overflow-hidden rounded-full bg-surface-raised" role="meter" aria-valuenow={Math.round(share * 100)} aria-valuemin={0} aria-valuemax={100} aria-label="Budget used">
        <div className={cn("h-full rounded-full", share > 0.9 ? "bg-negative" : share > 0.7 ? "bg-warning" : "bg-primary")} style={{ width: `${Math.min(share * 100, 100)}%` }} />
      </div>
      <table className="w-full text-sm">
        <thead>
          <tr className="text-left text-[11px] uppercase tracking-wider text-muted">
            <th className="py-1 font-semibold">signal</th>
            <th className="py-1 text-right font-semibold">days</th>
            <th className="py-1 text-right font-semibold">kept for</th>
            <th className="py-1 text-right font-semibold">size</th>
          </tr>
        </thead>
        <tbody>
          {report.tables.map((table) => (
            <tr key={table.table} className="border-t border-border">
              <td className="py-1.5 text-foreground">
                {table.label} <span className="font-mono text-xs text-muted">{table.table}</span>
              </td>
              <td className="tabular py-1.5 text-right font-mono">{table.days.length}</td>
              <td className="tabular py-1.5 text-right font-mono">{table.retention_days}d</td>
              <td className="tabular py-1.5 text-right font-mono">{formatBytes(table.bytes)}</td>
            </tr>
          ))}
          <tr className="border-t border-border">
            <td className="py-1.5 text-foreground">
              Dictionaries <span className="font-mono text-xs text-muted">series, stacks, functions</span>
            </td>
            <td className="tabular py-1.5 text-right font-mono text-muted">—</td>
            <td className="tabular py-1.5 text-right font-mono text-muted">while used</td>
            <td className="tabular py-1.5 text-right font-mono">{formatBytes(report.dictionary_bytes)}</td>
          </tr>
        </tbody>
      </table>
    </section>
  );
}
