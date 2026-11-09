import { useState, type FormEvent } from "react";
import { useParams, useSearchParams } from "react-router-dom";
import { useMutation, useQuery } from "@tanstack/react-query";
import { api } from "@/api/client";
import { PageBody } from "@/components/layout/PageBody";
import { ScopedLink } from "@/components/scope/ScopedLink";
import { QueryBar, useCatalog } from "@/components/telemetry/QueryBar";
import { Badge, type BadgeTone } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { FormError, FormFooter } from "@/components/ui/Form";
import { Input } from "@/components/ui/Input";
import { Select } from "@/components/ui/Select";
import { Sheet } from "@/components/ui/Sheet";
import { Toggle } from "@/components/ui/Toggle";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import { useFormMutation } from "@/hooks/useFormMutation";
import { keys } from "@/lib/queryKeys";
import { useScopedNavigate } from "@/lib/scopeHref";
import { relativeTime } from "@/lib/time";
import { formatCount } from "@/lib/format";
import { cn } from "@/lib/cn";
import type { Incident, Monitor, MonitorKind, MonitorState } from "@/types";
import { computeSuggestions } from "@/lib/workFields";

const STATE_TONES: Record<MonitorState, BadgeTone> = { ok: "success", alert: "danger", no_data: "neutral" };
const STATE_LABELS: Record<MonitorState, string> = { ok: "OK", alert: "Alerting", no_data: "No data" };
const WINDOWS = [
  [60, "1 min"],
  [300, "5 min"],
  [900, "15 min"],
  [3600, "1 hour"],
  [21_600, "6 hours"],
  [86_400, "1 day"],
] as const;

interface Draft {
  name: string;
  description: string;
  enabled: boolean;
  kind: MonitorKind;
  source: string;
  filter: string;
  compute: string;
  metric: string;
  comparison: "gt" | "lt";
  threshold: number;
  window_seconds: number;
  for_seconds: number;
  deploy_grace_seconds: number;
  notify: boolean;
}

const EMPTY: Draft = {
  name: "",
  description: "",
  enabled: true,
  kind: "threshold",
  source: "transactions",
  filter: "",
  compute: "p95(duration)",
  metric: "",
  comparison: "gt",
  threshold: 500,
  window_seconds: 300,
  for_seconds: 0,
  deploy_grace_seconds: 300,
  notify: true,
};

function toDraft(monitor: Monitor): Draft {
  return {
    name: monitor.name,
    description: monitor.description ?? "",
    enabled: monitor.enabled,
    kind: monitor.kind,
    source: monitor.query.source ?? "transactions",
    filter: monitor.query.filter ?? "",
    compute: monitor.query.compute ?? "count",
    metric: monitor.query.metric ?? "",
    comparison: monitor.comparison,
    threshold: monitor.threshold,
    window_seconds: monitor.window_seconds,
    for_seconds: monitor.for_seconds,
    deploy_grace_seconds: monitor.deploy_grace_seconds,
    notify: monitor.notify,
  };
}

function toBody(draft: Draft) {
  return {
    name: draft.name.trim(),
    description: draft.description.trim() || null,
    enabled: draft.enabled,
    kind: draft.kind,
    query: { source: draft.source, filter: draft.filter.trim(), compute: draft.compute.trim(), metric: draft.metric.trim() },
    comparison: draft.comparison,
    threshold: draft.threshold,
    window_seconds: draft.window_seconds,
    for_seconds: draft.for_seconds,
    deploy_grace_seconds: draft.deploy_grace_seconds,
    notify: draft.notify,
  };
}

/**
 * Monitors and incidents: a saved query with a condition,
 * its state, and the stretches it was alerting.
 */
export function Monitors() {
  const monitors = useQuery({ queryKey: keys.monitors.list(), queryFn: () => api.get<Monitor[]>("/monitors"), refetchInterval: 30_000 });
  return (
    <QueryState query={monitors} errorMessage="Couldn't load monitors.">
      {(list) => <MonitorsPage monitors={list} />}
    </QueryState>
  );
}

function MonitorsPage({ monitors }: { monitors: Monitor[] }) {
  const { id } = useParams();
  const [params] = useSearchParams();
  const navigate = useScopedNavigate();
  const incidents = useQuery({ queryKey: keys.monitors.incidents(), queryFn: () => api.get<Incident[]>("/incidents"), refetchInterval: 30_000 });
  const creating = params.get("new") === "1";
  const editing = id ? monitors.find((monitor) => monitor.id === id) : undefined;

  return (
    <PageBody className="space-y-4 py-4">
      <div className="flex items-center gap-2">
        <h2 className="text-xs font-semibold uppercase tracking-wider text-muted">Monitors</h2>
        <span className="text-xs text-muted">
          {monitors.filter((monitor) => monitor.state === "alert").length} alerting · {monitors.length} total
        </span>
        <Button size="sm" className="ml-auto" onClick={() => navigate("/monitors?new=1")}>
          New monitor
        </Button>
      </div>
      {monitors.length === 0 ? (
        <EmptyState title="No monitors yet" description="A monitor is any Explorer query with a condition: p95 over 800 ms for 5 minutes, no heartbeat from a worker, an error rate past 2%." />
      ) : (
        <ul className="divide-y divide-border rounded-[var(--radius-card)] border border-border bg-surface">
          {monitors.map((monitor) => (
            <li key={monitor.id}>
              <ScopedLink to={`/monitors/${monitor.id}`} className="flex w-full flex-wrap items-center gap-3 px-3 py-2 text-left hover:bg-surface-raised">
                <Badge tone={monitor.enabled ? STATE_TONES[monitor.state] : "neutral"}>{monitor.enabled ? STATE_LABELS[monitor.state] : "Off"}</Badge>
                <span className="font-medium text-foreground">{monitor.name}</span>
                <span className="font-mono text-xs text-muted">{monitor.condition}</span>
                {monitor.app ? <span className="text-xs text-muted">{monitor.app}</span> : null}
                <span className="ml-auto text-xs text-muted">
                  {monitor.last_value !== null ? `now ${formatCount(monitor.last_value)}` : ""}
                  {monitor.last_evaluated_at ? ` · checked ${relativeTime(monitor.last_evaluated_at)}` : " · never checked"}
                </span>
                {monitor.last_error ? <span className="w-full text-xs text-negative">{monitor.last_error}</span> : null}
              </ScopedLink>
            </li>
          ))}
        </ul>
      )}

      <section>
        <h2 className="mb-2 text-xs font-semibold uppercase tracking-wider text-muted">Incidents</h2>
        <QueryState query={incidents} errorMessage="Couldn't load incidents." empty={<p className="text-sm text-muted">None yet.</p>}>
          {(list) => (
            <ul className="divide-y divide-border rounded-[var(--radius-card)] border border-border bg-surface">
              {list.map((incident) => (
                <li key={incident.id} className="flex flex-wrap items-center gap-3 px-3 py-2 text-sm">
                  <span className={cn("inline-block h-2 w-2 rounded-full", incident.closed_at ? "bg-muted" : "bg-negative shadow-[0_0_6px_var(--color-negative)]")} aria-hidden />
                  <ScopedLink to={`/monitors/${incident.monitor_id}`} className="font-medium text-foreground hover:text-primary">
                    {incident.monitor}
                  </ScopedLink>
                  <span className="font-mono text-xs text-muted">{incident.condition}</span>
                  <span className="ml-auto text-xs text-muted">
                    {relativeTime(incident.opened_at)}
                    {incident.closed_at ? ` → resolved ${relativeTime(incident.closed_at)}` : " · open"}
                    {incident.peak_value !== null ? ` · peak ${formatCount(incident.peak_value)}` : ""}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </QueryState>
      </section>

      {creating || editing ? (
        <MonitorSheet
          key={editing?.id ?? "new"}
          monitor={editing}
          initial={creating ? draftFromParams(params) : editing ? toDraft(editing) : EMPTY}
          onClose={() => navigate("/monitors")}
        />
      ) : null}
    </PageBody>
  );
}

/** Explore's "make a monitor" prefills the query through the URL. */
function draftFromParams(params: URLSearchParams): Draft {
  return {
    ...EMPTY,
    source: params.get("source") ?? EMPTY.source,
    filter: params.get("filter") ?? "",
    compute: params.get("compute") ?? (params.get("source") === "metrics" ? "avg" : EMPTY.compute),
    metric: params.get("metric") ?? "",
  };
}

function MonitorSheet({ monitor, initial, onClose }: { monitor: Monitor | undefined; initial: Draft; onClose: () => void }) {
  const [draft, setDraft] = useState<Draft>(initial);
  const set = <K extends keyof Draft>(key: K, value: Draft[K]) => setDraft((current) => ({ ...current, [key]: value }));
  const catalog = useCatalog();
  const save = useFormMutation({
    mutationFn: () => (monitor ? api.patch<Monitor>(`/monitors/${monitor.id}`, toBody(draft)) : api.post<Monitor>("/monitors", toBody(draft))),
    meta: { invalidates: [keys.monitors.all] },
    fallback: "Couldn't save the monitor.",
    onSuccess: onClose,
  });
  const evaluate = useMutation({
    mutationFn: () => api.post<Monitor>(`/monitors/${monitor!.id}/evaluate`),
    meta: { invalidates: [keys.monitors.all] },
  });
  const remove = useMutation({
    mutationFn: () => api.delete(`/monitors/${monitor!.id}`),
    meta: { invalidates: [keys.monitors.all] },
    onSuccess: onClose,
  });
  const detail = useQuery({ queryKey: keys.monitors.detail(monitor?.id ?? ""), queryFn: () => api.get<Monitor>(`/monitors/${monitor!.id}`), enabled: Boolean(monitor) });
  const history = detail.data?.incidents ?? [];
  const functions = draft.source === "metrics" ? (catalog.data?.functions.metrics ?? []) : (catalog.data?.functions.events ?? []);

  return (
    <Sheet open onClose={onClose} title={monitor ? monitor.name : "New monitor"} description={monitor ? `${STATE_LABELS[monitor.state]} · ${monitor.condition}` : undefined} size="lg">
      <form
        onSubmit={(event: FormEvent) => {
          event.preventDefault();
          save.mutate();
        }}
        className="space-y-4"
      >
        <Input label="Name" value={draft.name} onChange={(event) => set("name", event.target.value)} required autoFocus placeholder="Hook search is slow" />
        <div className="grid gap-3 sm:grid-cols-2">
          <Select label="Kind" value={draft.kind} onChange={(event) => set("kind", event.target.value as MonitorKind)}>
            <option value="threshold">Threshold — a value crosses a line</option>
            <option value="absence">Absence — nothing arrives</option>
          </Select>
          <Select label="Source" value={draft.source} onChange={(event) => set("source", event.target.value)}>
            {(catalog.data?.sources ?? []).map((source) => (
              <option key={source.name} value={source.name}>
                {source.label}
              </option>
            ))}
            <option value="metrics">Metrics</option>
          </Select>
        </div>
        {draft.source === "metrics" ? (
          <Select label="Metric" value={draft.metric} onChange={(event) => set("metric", event.target.value)}>
            <option value="">Pick a metric…</option>
            {(catalog.data?.metrics ?? []).map((entry) => (
              <option key={entry.name} value={entry.name}>
                {entry.name}
              </option>
            ))}
          </Select>
        ) : null}
        <div>
          <p className="mb-1 text-sm text-foreground">Filter</p>
          <QueryBar value={draft.filter} onChange={(value) => set("filter", value)} onSubmit={(value) => set("filter", value)} source={draft.source} metric={draft.metric} placeholder="app:hook kind:request name:*Search*" />
        </div>
        {draft.kind === "threshold" ? (
          <div className="grid gap-3 sm:grid-cols-3">
            <label className="block text-sm">
              <span className="mb-1 block text-foreground">Compute</span>
              <input list="monitor-computes" value={draft.compute} onChange={(event) => set("compute", event.target.value)} className="h-9 w-full rounded-[var(--radius-control)] border border-border bg-input px-2 font-mono text-sm text-foreground" aria-label="Compute" />
              <datalist id="monitor-computes">
                {computeSuggestions(functions, draft.source, catalog.data?.sources.find((source) => source.name === draft.source)?.fields ?? []).map((option) => (
                  <option key={option} value={option} />
                ))}
              </datalist>
            </label>
            <Select label="Is" value={draft.comparison} onChange={(event) => set("comparison", event.target.value as "gt" | "lt")}>
              <option value="gt">above</option>
              <option value="lt">below</option>
            </Select>
            <Input label="Threshold" type="number" step="any" value={draft.threshold} onChange={(event) => set("threshold", Number(event.target.value))} />
          </div>
        ) : null}
        <div className="grid gap-3 sm:grid-cols-3">
          <Select label="Over the last" value={draft.window_seconds} onChange={(event) => set("window_seconds", Number(event.target.value))}>
            {WINDOWS.map(([seconds, label]) => (
              <option key={seconds} value={seconds}>
                {label}
              </option>
            ))}
          </Select>
          <Input label="Must hold for (s)" hint="Hysteresis: alert only after the condition has held this long." type="number" min={0} value={draft.for_seconds} onChange={(event) => set("for_seconds", Number(event.target.value))} />
          <Input label="Deploy grace (s)" hint="Stay quiet this long after the app's deploy." type="number" min={0} value={draft.deploy_grace_seconds} onChange={(event) => set("deploy_grace_seconds", Number(event.target.value))} />
        </div>
        <div className="flex flex-wrap gap-6">
          <Toggle label="Enabled" checked={draft.enabled} onChange={(checked) => set("enabled", checked)} />
          <Toggle label="Push through ntfy" checked={draft.notify} onChange={(checked) => set("notify", checked)} />
        </div>
        <Input label="Notes" value={draft.description} onChange={(event) => set("description", event.target.value)} placeholder="What to do when this fires" />
        <FormError message={save.errorMessage} />
        <div className="flex flex-wrap items-center gap-2">
          <FormFooter label={monitor ? "Save" : "Create"} pendingLabel={monitor ? "Saving…" : "Creating…"} pending={save.isPending} disabled={!draft.name.trim()} />
          {monitor ? (
            <Button type="button" variant="secondary" onClick={() => evaluate.mutate()} disabled={evaluate.isPending}>
              Evaluate now
            </Button>
          ) : null}
          {monitor ? (
            <ConfirmButton question="Delete this monitor and its incidents?" onConfirm={() => remove.mutate()} variant="ghost">
              Delete
            </ConfirmButton>
          ) : null}
        </div>
        {history.length > 0 ? (
          <section>
            <h3 className="mb-1 text-xs font-semibold uppercase tracking-wider text-muted">History</h3>
            <ul className="divide-y divide-border text-xs">
              {history.map((incident) => (
                <li key={incident.id} className="flex items-center gap-2 py-1">
                  <span className={cn("inline-block h-1.5 w-1.5 rounded-full", incident.closed_at ? "bg-muted" : "bg-negative")} aria-hidden />
                  <span className="text-foreground">{new Date(incident.opened_at).toLocaleString()}</span>
                  <span className="text-muted">{incident.closed_at ? `→ ${new Date(incident.closed_at).toLocaleString()}` : "open"}</span>
                  {incident.peak_value !== null ? <span className="ml-auto font-mono text-muted">peak {formatCount(incident.peak_value)}</span> : null}
                </li>
              ))}
            </ul>
          </section>
        ) : null}
      </form>
    </Sheet>
  );
}
