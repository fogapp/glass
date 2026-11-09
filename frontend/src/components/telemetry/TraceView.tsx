import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { ExternalLink } from "lucide-react";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { cn } from "@/lib/cn";
import { levelTone } from "@/lib/logLevels";
import { formatClock, formatCount, formatDateTime, formatMs, formatPercent, formatUsd, shortSha } from "@/lib/format";
import { useExploreHref } from "@/lib/explore";
import { ScopedLink } from "@/components/scope/ScopedLink";
import { RUN_PHASES, activeMs, linkFor, phaseColor, phaseParts } from "@/lib/runs";
import { ErrorState, LoadingState } from "@/components/ui/PageState";
import { hatch } from "@/components/charts/hatch";
import { PhaseBar } from "@/components/charts/PhaseBar";
import { AppDot } from "@/components/scope/AppDot";
import { useAppsBySlug } from "@/hooks/useApps";
import { useGlassQuery } from "@/lib/glassQuery";
import { waterfall, type WaterfallRow } from "@/components/telemetry/waterfall";
import type { App, ListResult, LogRow, TraceModelCall, TraceSpan, TraceTransaction, Trace } from "@/types";

/**
 * A step's colour by its kind. An app's own plumbing and the steps of a run
 * share the eight slots; a run's steps wear the slots their phases wear
 * everywhere else (lib/runs.ts), and the kind is always written beside the
 * mark, so colour is never the only thing that says what a row is.
 */
const KIND_COLORS: Record<string, string> = {
  request: "var(--color-series-1)",
  job: "var(--color-series-7)",
  run: "var(--color-series-6)",
  sql: "var(--color-series-3)",
  view: "var(--color-series-4)",
  http: "var(--color-series-2)",
  cache: "var(--color-series-5)",
  enqueue: "var(--color-series-7)",
  custom: "var(--color-muted)",
  memory: "var(--color-series-4)",
  context: "var(--color-series-4)",
  sandbox: "var(--color-series-8)",
  channel: "var(--color-series-2)",
  ...Object.fromEntries(RUN_PHASES.map((phase) => [phase.key, phaseColor(phase)])),
};
/** Time that was not the app's — a person deciding — and time nothing accounts for: drawn hatched. */
const HATCHED = new Set(["wait", "untracked"]);

const colorOf = (kind: string): string => KIND_COLORS[kind] ?? KIND_COLORS.custom!;
const fillOf = (row: Pick<WaterfallRow, "kind" | "status">): string =>
  row.status === "error" ? "var(--color-negative)" : HATCHED.has(row.kind) ? hatch(colorOf(row.kind)) : colorOf(row.kind);

export function useTrace(id: string | null) {
  return useQuery({
    queryKey: keys.traces.detail(id ?? ""),
    queryFn: () => api.get<Trace>(`/traces/${id}`),
    enabled: id !== null,
    staleTime: 60_000,
  });
}

/**
 * One trace as a waterfall: the unit of work that began it and everything it
 * set going (across apps) as roots, their spans beneath, time across. For a
 * run, where its time went is drawn above, the stretches no span covers are a
 * row of their own, and each model step says what it spent. Below: the model
 * calls, and the log lines written under this trace.
 */
export function TraceView({ id }: { id: string }) {
  const explore = useExploreHref();
  const trace = useTrace(id);
  const bySlug = useAppsBySlug();
  const [selected, setSelected] = useState<string | null>(null);
  const rows = useMemo(() => (trace.data ? waterfall(trace.data) : []), [trace.data]);
  const logs = useGlassQuery<ListResult>(
    trace.data
      ? { source: "logs", shape: "list", from: trace.data.started_at - 60, to: trace.data.started_at + trace.data.duration_ms / 1000 + 3600, filter: `trace:${id}`, limit: 200 }
      : null,
  );

  // What a browser reported under this trace: the moment the first answer text was painted, for one.
  const seen = useGlassQuery<ListResult>(
    trace.data
      ? { source: "page_events", shape: "list", from: trace.data.started_at - 60, to: trace.data.started_at + trace.data.duration_ms / 1000 + 3600, filter: `trace:${id}`, limit: 50 }
      : null,
  );
  const browser = [...((seen.data?.rows ?? []) as unknown as BrowserEvent[])].reverse();

  if (trace.isPending) return <LoadingState />;
  if (trace.isError) return <ErrorState message="Couldn't load this trace — it may have aged out." onRetry={() => void trace.refetch()} />;
  const data = trace.data;
  const root = data.transactions[0];
  const total = Math.max(data.duration_ms, 0.001);
  const current = rows.find((row) => row.id === selected) ?? rows[0];
  const several = new Set(data.transactions.map((txn) => txn.app)).size > 1;
  const appOf = (slug: string | null): App | undefined => (slug ? bySlug.get(slug) : undefined);

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-muted">
        <span className="font-mono text-foreground">{id}</span>
        <span>{formatDateTime(data.started_at)}</span>
        <span>{formatMs(data.duration_ms)} end to end</span>
        <span>
          {data.transactions.length} {data.transactions.length === 1 ? "transaction" : "transactions"} · {data.spans.length} spans
          {data.model_calls.length > 0 ? ` · ${data.model_calls.length} model ${data.model_calls.length === 1 ? "call" : "calls"}` : ""}
        </span>
        {data.truncated ? <span className="text-warning">truncated</span> : null}
        {root ? (
          <ScopedLink to={explore({ shape: "list", filter: `trace:${id}` })} className="text-primary hover:underline">
            as rows
          </ScopedLink>
        ) : null}
      </div>

      {root?.kind === "run" ? <RunSummary run={root} app={appOf(root.app)} /> : null}

      <div className="overflow-hidden rounded-[var(--radius-card)] border border-border bg-surface">
        <div className="max-h-[50vh] overflow-y-auto scrollbar-thin">
          {rows.map((row, position) => {
            const bars = row.segments ?? [[row.start, row.duration] as [number, number]];
            return (
              <button
                // A span reported twice is two rows, not one row and a warning.
                key={`${row.id}:${position}`}
                type="button"
                onClick={() => setSelected(row.id)}
                className={cn(
                  "grid w-full grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)_4.5rem] items-center gap-2 border-b border-border/60 px-2 py-1 text-left hover:bg-surface-raised",
                  current?.id === row.id && "bg-primary/10",
                )}
              >
                <span className="flex min-w-0 items-center gap-1.5" style={{ paddingLeft: row.depth * 14 }}>
                  <span className="inline-block h-2 w-2 shrink-0 rounded-sm" style={{ background: HATCHED.has(row.kind) ? hatch(colorOf(row.kind)) : colorOf(row.kind) }} aria-hidden />
                  <span className="shrink-0 font-mono text-[10px] uppercase text-muted">{row.kind}</span>
                  {several && row.transaction ? <AppDot app={appOf(row.app)} /> : null}
                  <span className={cn("truncate font-mono text-xs", row.status === "error" ? "text-negative" : row.kind === "untracked" ? "text-muted" : "text-foreground")}>{row.name}</span>
                  {row.call ? <span className="hidden shrink-0 font-mono text-[11px] text-muted sm:inline">{callSummary(row.call)}</span> : null}
                </span>
                <span className="relative h-3 rounded-sm bg-surface-raised/70" aria-hidden>
                  {bars.map(([start, duration], index) => {
                    const left = ((start - data.started_at * 1000) / total) * 100;
                    const width = Math.max((duration / total) * 100, 0.3);
                    return <span key={index} className="absolute inset-y-0 rounded-sm" style={{ left: `${Math.min(Math.max(left, 0), 99.7)}%`, width: `${Math.min(width, 100 - left)}%`, background: fillOf(row) }} />;
                  })}
                </span>
                <span className="tabular text-right font-mono text-xs text-foreground">{formatMs(row.duration)}</span>
              </button>
            );
          })}
        </div>
      </div>

      {current ? <Details row={current} app={appOf(current.app)} /> : null}

      {data.model_calls.length > 0 ? <ModelCalls calls={data.model_calls} startedAt={data.started_at} /> : null}

      {browser.length > 0 ? (
        <section>
          <h3 className="mb-1 text-xs font-semibold uppercase tracking-wider text-muted">What the browser saw</h3>
          <ul className="divide-y divide-border rounded-[var(--radius-card)] border border-border bg-surface font-mono text-xs">
            {browser.map((event, index) => (
              <li key={index} className="flex gap-3 px-2 py-1">
                <span className="tabular w-20 shrink-0 text-muted">+{formatMs((event.ts - data.started_at) * 1000)}</span>
                <span className="min-w-0 flex-1 truncate text-foreground">{event.name ?? event.kind}</span>
                <span className="shrink-0 text-muted">{[event.browser, event.device].filter(Boolean).join(" · ")}</span>
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      <section>
        <h3 className="mb-1 text-xs font-semibold uppercase tracking-wider text-muted">Logs in this trace</h3>
        {logs.data && logs.data.rows.length === 0 ? <p className="text-xs text-muted">No log lines carried this trace id.</p> : null}
        <ul className="divide-y divide-border rounded-[var(--radius-card)] border border-border bg-surface font-mono text-xs">
          {(logs.data?.rows as LogRow[] | undefined)?.map((line, index) => (
            <li key={index} className="flex gap-2 px-2 py-1">
              <span className="shrink-0 text-muted">{formatClock(line.ts)}</span>
              <span className={cn("w-10 shrink-0 uppercase", levelTone(line.level))}>{line.level}</span>
              <span className="min-w-0 break-words text-foreground">{line.message}</span>
            </li>
          ))}
        </ul>
      </section>
    </div>
  );
}

/** A page event carrying this trace: the server knows when a token was sent, only the browser knows when it was painted. */
interface BrowserEvent {
  ts: number;
  kind: string;
  name: string | null;
  browser: string | null;
  device: string | null;
}

/** What a model step spent, in one line beside its name. */
function callSummary(call: TraceModelCall): string {
  const input = call.tokens_in + call.cache_read + call.cache_write;
  return `${formatCount(input)} → ${formatCount(call.tokens_out)} tok${call.cost > 0 ? ` · ${formatUsd(call.cost)}` : ""}`;
}

/** A run at a glance: where its time went, what the person saw, what it spent — and the way to what Glass is never sent. */
function RunSummary({ run, app }: { run: TraceTransaction; app: App | undefined }) {
  const parts = phaseParts(run).map(({ phase, value }) => ({ key: phase.key, label: phase.label, value, color: phaseColor(phase), hatched: phase.hatched }));
  const link = linkFor(app, { trace: null, session: run.session, attrs: run.attrs });
  const figures: [string, string][] = [
    ["took", formatMs(activeMs(run))],
    ...(Number(run.wait ?? 0) > 0 ? ([["waited on a person", formatMs(run.wait)]] as [string, string][]) : []),
    ...(run.ttft !== null && run.ttft !== undefined ? ([["first text after", formatMs(run.ttft)]] as [string, string][]) : []),
    ...(run.stall !== null && run.stall !== undefined ? ([["longest silence", formatMs(run.stall)]] as [string, string][]) : []),
    ["spent", formatUsd(run.cost ?? 0)],
    ["tokens", `${formatCount(Number(run.tokens_in ?? 0) + Number(run.cache_read ?? 0) + Number(run.cache_write ?? 0))} in · ${formatCount(run.tokens_out ?? 0)} out`],
  ];
  return (
    <div className="rounded-[var(--radius-card)] border border-border bg-surface p-3">
      <div className="mb-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-xs">
        {figures.map(([label, value]) => (
          <span key={label} className="text-muted">
            {label} <span className="tabular font-mono text-foreground">{value}</span>
          </span>
        ))}
        <span className="ml-auto flex items-center gap-3">
          {run.session && run.app ? (
            <ScopedLink to={`/apps/${run.app}/sessions/${encodeURIComponent(run.session)}`} className="text-primary hover:underline">
              The conversation
            </ScopedLink>
          ) : null}
          {link ? (
            <a href={link} target="_blank" rel="noreferrer" className="flex items-center gap-1 text-primary hover:underline" title="Glass is never sent what was said; the app's own console has it">
              Open in {app?.name ?? "the app"} <ExternalLink className="h-3 w-3" aria-hidden />
            </a>
          ) : null}
        </span>
      </div>
      <PhaseBar parts={parts} format={formatMs} />
    </div>
  );
}

function ModelCalls({ calls, startedAt }: { calls: TraceModelCall[]; startedAt: number }) {
  const cost = calls.reduce((sum, call) => sum + (call.cost_source === "shadow" ? 0 : call.cost), 0);
  return (
    <section>
      <h3 className="mb-1 text-xs font-semibold uppercase tracking-wider text-muted">
        Model calls <span className="font-normal normal-case tracking-normal">· {formatUsd(cost)}</span>
      </h3>
      <div className="overflow-x-auto rounded-[var(--radius-card)] border border-border bg-surface">
        <table className="w-full text-left font-mono text-xs">
          <thead className="text-[10px] uppercase tracking-wider text-muted">
            <tr className="border-b border-border">
              {["at", "for", "model", "input", "cached", "output", "first token", "took", "cost", "ended"].map((heading, index) => (
                <th key={heading} className={cn("px-2 py-1 font-semibold", index >= 3 && index <= 8 && "text-right")}>
                  {heading}
                </th>
              ))}
            </tr>
          </thead>
          <tbody className="tabular">
            {calls.map((call, index) => {
              const input = call.tokens_in + call.cache_read + call.cache_write;
              return (
                <tr key={index} className="border-b border-border/60 last:border-0">
                  <td className="px-2 py-1 text-muted">+{formatMs((call.ts - startedAt) * 1000)}</td>
                  <td className="px-2 py-1 text-foreground">
                    {call.purpose}
                    {call.round !== null ? <span className="text-muted"> · round {call.round + 1}</span> : null}
                    {call.retry_of ? <span className="text-warning"> · retry</span> : null}
                  </td>
                  <td className="max-w-48 truncate px-2 py-1 text-foreground" title={`${call.provider} · ${call.served ?? call.model}`}>
                    {call.served ?? call.model}
                  </td>
                  <td className="px-2 py-1 text-right text-foreground">
                    {formatCount(input)}
                    {call.estimated ? <span className="text-muted" title="The provider gave no usage; counted from text length">~</span> : null}
                  </td>
                  <td className="px-2 py-1 text-right text-muted">{input > 0 ? formatPercent(call.cache_read / input, 0) : "—"}</td>
                  <td className="px-2 py-1 text-right text-foreground">{formatCount(call.tokens_out)}</td>
                  <td className="px-2 py-1 text-right text-foreground">{formatMs(call.ttft)}</td>
                  <td className="px-2 py-1 text-right text-foreground">{formatMs(call.duration)}</td>
                  <td className="px-2 py-1 text-right text-foreground" title={call.cost_source ?? undefined}>
                    {call.cost_source === "shadow" ? <span className="text-muted">({formatUsd(call.cost)})</span> : formatUsd(call.cost)}
                  </td>
                  <td className={cn("px-2 py-1", call.status === "error" ? "text-negative" : "text-muted")}>{call.status === "error" ? (call.error ?? "error") : (call.stop ?? "—")}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function Details({ row, app }: { row: WaterfallRow; app: App | undefined }) {
  const txn = row.transaction;
  const span = row.span;
  const call = row.call;
  const link = txn ? linkFor(app, { trace: null, session: txn.session, attrs: txn.attrs }) : null;
  const facts: [string, string][] = txn ? transactionFacts(txn) : span ? spanFacts(span, call) : row.kind === "untracked" ? [["what", "stretches of the run that no span covers"]] : [];
  const attrs = Object.entries(txn?.attrs ?? span?.attrs ?? {});
  return (
    <div className="rounded-[var(--radius-card)] border border-border bg-surface p-3 text-xs">
      <p className="mb-2 flex items-center gap-3 break-all font-mono text-sm text-foreground">
        {row.name}
        {link ? (
          <a href={link} target="_blank" rel="noreferrer" className="flex shrink-0 items-center gap-1 font-sans text-xs text-primary hover:underline">
            Open in {app?.name ?? "the app"} <ExternalLink className="h-3 w-3" aria-hidden />
          </a>
        ) : null}
      </p>
      {row.resource ? <pre className="mb-2 max-h-40 overflow-auto whitespace-pre-wrap break-all rounded bg-surface-raised p-2 font-mono text-[11px] text-foreground">{row.resource}</pre> : null}
      <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5 sm:grid-cols-[auto_1fr_auto_1fr]">
        {facts.map(([label, value]) => (
          <div key={label} className="contents">
            <dt className="text-muted">{label}</dt>
            <dd className="truncate font-mono text-foreground">{value}</dd>
          </div>
        ))}
        {attrs.map(([key, value]) => (
          <div key={key} className="contents">
            <dt className="text-muted">@{key}</dt>
            <dd className="truncate font-mono text-foreground">{String(value)}</dd>
          </div>
        ))}
      </dl>
    </div>
  );
}

/** What is worth saying about a unit of work depends on its kind: each says its own facets. */
function transactionFacts(txn: TraceTransaction): [string, string][] {
  const spine: [string, string][] = [
    ["app", txn.app ?? "—"],
    ["process", `${txn.process}${txn.host ? ` @ ${txn.host}` : ""}`],
    ["release", shortSha(txn.release)],
  ];
  const failure: [string, string][] = txn.error ? [["error", txn.error]] : [];
  if (txn.kind === "run") {
    return [
      ...spine,
      ["agent", txn.agent ?? "—"],
      ["trigger", txn.trigger ?? "—"],
      ["channel", txn.channel ?? "—"],
      ["ended", txn.stop ?? txn.status],
      ["answered by", txn.model ?? "—"],
      ["rounds", `${txn.rounds ?? 0} · ${txn.calls ?? 0} model calls`],
      ["tools", `${txn.tools ?? 0} calls${txn.tool_errors ? ` · ${txn.tool_errors} failed` : ""}`],
      ["tokens in", `${formatCount(txn.tokens_in ?? 0)} + ${formatCount(txn.cache_read ?? 0)} cached${txn.cache_write ? ` + ${formatCount(txn.cache_write)} written` : ""}`],
      ["tokens out", formatCount(txn.tokens_out ?? 0)],
      ["cost", formatUsd(txn.cost ?? 0)],
      ["lag before it began", formatMs(txn.lag)],
      ["first visible text", formatMs(txn.ttft)],
      ["longest silence", formatMs(txn.stall)],
      ["user", txn.user ?? "—"],
      ["session", txn.session ?? "—"],
      ...failure,
    ];
  }
  const breakdown: [string, string][] = [
    ["database", `${formatMs(txn.db)} · ${txn.db_count} queries${txn.n_plus_one ? " · N+1" : ""}`],
    ["views", formatMs(txn.view)],
    ["external", `${formatMs(txn.ext)} · ${txn.ext_count} calls`],
    ["cache", `${txn.cache_hits} hits · ${txn.cache_misses} misses`],
    ["gc", formatMs(txn.gc)],
    ["allocations", txn.allocations === null ? "—" : formatCount(txn.allocations)],
  ];
  if (txn.kind === "request") {
    return [
      ...spine,
      ["request", `${txn.method ?? ""} ${txn.path ?? ""}`.trim()],
      ["route", txn.route ?? "—"],
      ["status", txn.http_status ? String(txn.http_status) : txn.status],
      ["origin", txn.origin ?? "—"],
      ["user", txn.user ?? "—"],
      ["visit", txn.visit ?? "—"],
      ...breakdown,
      ...failure,
    ];
  }
  return [...spine, ["queue", txn.queue ?? "—"], ["queue latency", formatMs(txn.queue_ms)], ["attempt", String(txn.attempt ?? 1)], ...breakdown, ...failure];
}

function spanFacts(span: TraceSpan, call: TraceModelCall | undefined): [string, string][] {
  const base: [string, string][] = [
    ["kind", span.kind],
    ["app", span.app ?? "—"],
    ["duration", formatMs(span.duration)],
    ["status", span.status],
  ];
  if (!call) return base;
  const input = call.tokens_in + call.cache_read + call.cache_write;
  return [
    ...base,
    ["model", call.served ?? call.model],
    ["provider", call.provider],
    ["for", `${call.purpose}${call.round !== null ? ` · round ${call.round + 1}` : ""}`],
    ["why this model", call.route ?? "—"],
    ["input", `${formatCount(input)} tokens · ${input > 0 ? formatPercent(call.cache_read / input, 0) : "0%"} from cache`],
    ["output", `${formatCount(call.tokens_out)} tokens${call.reasoning ? ` · ${formatCount(call.reasoning)} reasoning` : ""}`],
    ["cost", `${formatUsd(call.cost)}${call.cost_source ? ` (${call.cost_source})` : ""}`],
    ["first token", formatMs(call.ttft)],
    ["first text", formatMs(call.first_text)],
    ...(call.load ? ([["model load", formatMs(call.load)]] as [string, string][]) : []),
    ...(call.server_queue ? ([["server queue", formatMs(call.server_queue)]] as [string, string][]) : []),
    ["ended", call.status === "error" ? (call.error ?? "error") : (call.stop ?? "—")],
    ["tool calls", call.tools_valid === null ? String(call.tools) : `${call.tools} · ${call.tools_valid} valid`],
    ...(call.fallback_from ? ([["fell back from", call.fallback_from]] as [string, string][]) : []),
  ];
}
