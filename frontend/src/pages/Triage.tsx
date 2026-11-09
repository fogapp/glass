import { useEffect, useMemo, useState, type ReactNode } from "react";
import { Link, useNavigate, useParams, useSearchParams } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { BellOff, Check, ChevronDown, ChevronRight, ClipboardCopy, Download, EyeOff, ExternalLink, Undo2 } from "lucide-react";
import { api, apiErrorMessage } from "@/api/client";
import { PageBody } from "@/components/layout/PageBody";
import { AppDot } from "@/components/scope/AppDot";
import { useApps } from "@/hooks/useApps";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { FormError } from "@/components/ui/Form";
import { CodeBlock } from "@/components/ui/CodeBlock";
import { Fact, FactList } from "@/components/ui/FactList";
import { FilterChips } from "@/components/ui/FilterBar";
import { EmptyState, ErrorState, LoadingState, QueryState } from "@/components/ui/PageState";
import { Sheet } from "@/components/ui/Sheet";
import { useAuth } from "@/hooks/useAuth";
import { useFormMutation } from "@/hooks/useFormMutation";
import { useCopied } from "@/hooks/useCopied";
import { BREAKPOINTS, useMediaQuery } from "@/hooks/useMediaQuery";
import { useUrlEnum } from "@/hooks/useSearchParamState";
import { useExploreHref } from "@/lib/explore";
import { roundRange } from "@/lib/glassQuery";
import { keys } from "@/lib/queryKeys";
import { useScope } from "@/lib/scope";
import { ScopedLink } from "@/components/scope/ScopedLink";
import { baselineText, countBy, dismissalText, kindsPresent, rowsHref, SEVERITY_LABELS, SEVERITY_TONES, TRIAGE_KIND_LABELS } from "@/lib/triage";
import { cn } from "@/lib/cn";
import { isTyping } from "@/lib/keyboard";
import {
  TRIAGE_KINDS,
  TRIAGE_SEVERITIES,
  type App,
  type TriageDetail,
  type TriageDismissalMode,
  type TriageFinding,
  type TriageReport,
  type TriageSeverity,
} from "@/types";
import { EvidenceBlock } from "@/components/triage/Evidence";

/** Ranges are asked for on the minute, so a live tick is a cache hit. */
const SEVERITY_FILTERS = ["all", ...TRIAGE_SEVERITIES] as const;
const KIND_FILTERS = ["all", ...TRIAGE_KINDS] as const;

/**
 * What needs fixing across the fleet, worst first: the ranked findings on
 * the left, the one picked worked up beside them — what it is, the facts,
 * the evidence, the steps, and the brief to hand an agent.
 */
export function Triage() {
  const scope = useScope();
  const apps = useApps();
  const navigate = useNavigate();
  const { id } = useParams();
  const [params] = useSearchParams();
  const wide = useMediaQuery(BREAKPOINTS.lg);
  const [severity, setSeverity] = useUrlEnum<(typeof SEVERITY_FILTERS)[number]>("severity", SEVERITY_FILTERS, "all");
  const [kind, setKind] = useUrlEnum<(typeof KIND_FILTERS)[number]>("kind", KIND_FILTERS, "all");
  const { from, to } = roundRange(scope.range);

  const report = useQuery({
    queryKey: keys.triage.list(from, to, scope.app ?? ""),
    queryFn: ({ signal }) => api.get<TriageReport>(`/triage?from=${from}&to=${to}${scope.app ? `&app=${encodeURIComponent(scope.app)}` : ""}`, { signal }),
    refetchInterval: scope.live ? 60_000 : false,
    placeholderData: (previous) => previous,
  });

  const [showHidden, setShowHidden] = useState(false);
  const findings = useMemo(() => report.data?.findings ?? [], [report.data]);
  const hidden = useMemo(() => report.data?.hidden ?? [], [report.data]);
  const matches = useMemo(
    () => (finding: TriageFinding) => (severity === "all" || finding.severity === severity) && (kind === "all" || finding.kind === kind),
    [severity, kind],
  );
  const shown = useMemo(() => findings.filter(matches), [findings, matches]);
  const shownHidden = useMemo(() => hidden.filter(matches), [hidden, matches]);
  // j / k walk what is on screen: the list, then what is hidden when it is open.
  const walkable = useMemo(() => (showHidden ? [...shown, ...shownHidden] : shown), [showHidden, shown, shownHidden]);
  const open = (finding: TriageFinding | undefined) => {
    if (finding) navigate({ pathname: `/triage/${finding.id}`, search: params.toString() });
  };
  const close = () => navigate({ pathname: "/triage", search: params.toString() });
  // Answering a listed finding moves on to the next one, as working down a list does.
  const answered = (answeredId: string) => {
    const index = shown.findIndex((finding) => finding.id === answeredId);
    if (index === -1) return;
    const next = shown[index + 1] ?? shown[index - 1];
    if (next) navigate({ pathname: `/triage/${next.id}`, search: params.toString() }, { replace: true });
    else close();
  };

  // j / k walk the list; the first press with nothing open opens the top.
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.metaKey || event.ctrlKey || event.altKey || isTyping(event)) return;
      if (event.key !== "j" && event.key !== "k") return;
      const index = walkable.findIndex((finding) => finding.id === id);
      const next = index === -1 ? 0 : Math.min(Math.max(index + (event.key === "j" ? 1 : -1), 0), walkable.length - 1);
      if (walkable[next]) {
        event.preventDefault();
        navigate({ pathname: `/triage/${walkable[next].id}`, search: params.toString() }, { replace: true });
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [walkable, id, navigate, params]);

  const severities = countBy(findings, (finding) => finding.severity);
  const kinds = countBy(findings, (finding) => finding.kind);
  const selected = findings.find((finding) => finding.id === id) ?? hidden.find((finding) => finding.id === id);

  return (
    <PageBody className="space-y-3 py-4">
      <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <h2 className="text-xs font-semibold uppercase tracking-wider text-muted">Triage</h2>
        {report.data ? (
          <span className="text-xs text-muted">
            {findings.length === 0 ? "nothing stands out" : `${findings.length} ${findings.length === 1 ? "finding" : "findings"}`} · compared with the{" "}
            {baselineText(report.data)} before the range
            {hidden.length > 0 ? ` · ${hidden.length} dismissed or ignored` : ""}
          </span>
        ) : null}
      </div>
      {findings.length + hidden.length > 0 ? (
        <div className="flex flex-col gap-2">
          <FilterChips
            label="Severity"
            value={severity}
            onChange={(next) => setSeverity(next as typeof severity)}
            options={SEVERITY_FILTERS.map((key) => ({ key, label: key === "all" ? "All" : SEVERITY_LABELS[key], count: key === "all" ? findings.length : (severities.get(key) ?? 0) }))}
          />
          <FilterChips
            label="Kind"
            value={kind}
            onChange={(next) => setKind(next as typeof kind)}
            options={[{ key: "all" as const, label: "Every kind" }, ...kindsPresent(findings).map((key) => ({ key, label: TRIAGE_KIND_LABELS[key], count: kinds.get(key) ?? 0 }))]}
          />
        </div>
      ) : null}

      <QueryState
        query={report}
        errorMessage="Couldn't read the fleet for triage."
        loadingLabel="Reading every app…"
        isEmpty={(data) => data.findings.length === 0 && data.hidden.length === 0}
        empty={<EmptyState title="Nothing stands out" description="No failures, slowdowns, hotspots or alerts crossed a line over this range. Widen the range to look further back." />}
      >
        {() => (
          <div className="lg:grid lg:grid-cols-[minmax(0,24rem)_minmax(0,1fr)] lg:items-start lg:gap-4 xl:grid-cols-[minmax(0,28rem)_minmax(0,1fr)]">
            <div className="space-y-2">
              <FindingList
                findings={shown}
                apps={apps.data}
                selected={id ?? null}
                onSelect={open}
                empty={findings.length === 0 ? "Everything that stands out has been dismissed or ignored." : "None of this kind."}
              />
              {hidden.length > 0 ? (
                <div>
                  <button
                    type="button"
                    onClick={() => setShowHidden((open) => !open)}
                    aria-expanded={showHidden}
                    className="inline-flex items-center gap-1 rounded-[var(--radius-control)] px-1 py-0.5 text-xs text-muted hover:text-foreground"
                  >
                    {showHidden ? <ChevronDown className="h-3.5 w-3.5" aria-hidden /> : <ChevronRight className="h-3.5 w-3.5" aria-hidden />}
                    {hidden.length} dismissed or ignored
                    {shownHidden.length < hidden.length ? ` (${shownHidden.length} of this kind)` : ""}
                  </button>
                  {showHidden ? (
                    <div className="mt-1.5">
                      <FindingList findings={shownHidden} apps={apps.data} selected={id ?? null} onSelect={open} empty="None of this kind." />
                    </div>
                  ) : null}
                </div>
              ) : null}
            </div>
            {wide ? (
              <aside aria-label="Finding" className="sticky top-4 max-h-[calc(100dvh-7.5rem)] overflow-y-auto rounded-[var(--radius-card)] border border-border bg-surface">
                {id ? (
                  <FindingDetail id={id} from={from} to={to} finding={selected} apps={apps.data} onAnswered={answered} />
                ) : (
                  <EmptyState title="Pick a finding" description="Its evidence, what to do about it, and a brief to hand an agent open here. j and k step through the list." />
                )}
              </aside>
            ) : null}
          </div>
        )}
      </QueryState>

      {!wide && id ? (
        <Sheet open onClose={close} title={selected?.title ?? "Finding"} size="lg">
          <FindingDetail id={id} from={from} to={to} finding={selected} apps={apps.data} onAnswered={answered} bare />
        </Sheet>
      ) : null}
    </PageBody>
  );
}

function FindingList({
  findings,
  apps,
  selected,
  onSelect,
  empty,
}: {
  findings: TriageFinding[];
  apps: App[] | undefined;
  selected: string | null;
  onSelect: (finding: TriageFinding) => void;
  empty: string;
}) {
  if (findings.length === 0) return <p className="rounded-[var(--radius-card)] border border-border bg-surface px-3 py-6 text-center text-sm text-muted">{empty}</p>;
  return (
    <ul className="divide-y divide-border overflow-hidden rounded-[var(--radius-card)] border border-border bg-surface" aria-label="Findings">
      {findings.map((finding) => {
        const on = finding.id === selected;
        const set = finding.dismissal && !finding.dismissal.regressed;
        return (
          <li key={finding.id}>
            <button
              type="button"
              onClick={() => onSelect(finding)}
              aria-current={on ? "true" : undefined}
              className={cn("flex w-full gap-3 px-3 py-2.5 text-left transition-colors hover:bg-surface-raised", on && "bg-primary/10 hover:bg-primary/10")}
            >
              <SeverityBar severity={finding.severity} />
              <span className={cn("min-w-0 flex-1", set && !on && "opacity-70")}>
                <span className="flex flex-wrap items-center gap-x-2 gap-y-0.5 text-xs text-muted">
                  <span className="font-medium text-foreground/80">{TRIAGE_KIND_LABELS[finding.kind]}</span>
                  {finding.app ? (
                    <span className="inline-flex items-center gap-1">
                      <AppDot app={apps?.find((app) => app.slug === finding.app)} />
                      {finding.app}
                    </span>
                  ) : null}
                  {finding.dismissal ? <DismissalBadge dismissal={finding.dismissal} /> : null}
                  <span className="tabular ml-auto font-mono" title="Score, 0–100">
                    {Math.round(finding.score)}
                  </span>
                </span>
                <span className={cn("mt-0.5 block break-words text-sm font-medium", on ? "text-primary" : "text-foreground")}>{finding.title}</span>
                <span className="mt-0.5 line-clamp-2 block break-words text-xs text-muted">{finding.summary}</span>
              </span>
            </button>
          </li>
        );
      })}
    </ul>
  );
}

function DismissalBadge({ dismissal }: { dismissal: NonNullable<TriageFinding["dismissal"]> }) {
  if (dismissal.regressed) return <Badge tone="warning">Worse since dismissed</Badge>;
  return <Badge>{dismissal.mode === "ignored" ? "Ignored" : "Dismissed"}</Badge>;
}

const SEVERITY_BARS: Record<TriageSeverity, string> = { critical: "bg-negative", warning: "bg-warning", notice: "bg-border" };

function SeverityBar({ severity }: { severity: TriageSeverity }) {
  return <span className={cn("w-1 shrink-0 self-stretch rounded-full", SEVERITY_BARS[severity])} title={SEVERITY_LABELS[severity]} aria-label={SEVERITY_LABELS[severity]} />;
}

function FindingDetail({
  id,
  from,
  to,
  finding,
  apps,
  onAnswered,
  bare = false,
}: {
  id: string;
  from: number;
  to: number;
  finding: TriageFinding | undefined;
  apps: App[] | undefined;
  onAnswered: (id: string) => void;
  bare?: boolean;
}) {
  const detail = useQuery({
    queryKey: keys.triage.detail(id, from, to),
    queryFn: ({ signal }) => api.get<TriageDetail>(`/triage/${id}?from=${from}&to=${to}`, { signal }),
    retry: false,
  });
  if (detail.isPending) return <LoadingState label="Gathering the evidence…" />;
  if (detail.isError) {
    return (
      <div className="p-4">
        {finding ? <p className="mb-2 text-sm font-medium text-foreground">{finding.title}</p> : null}
        <ErrorState message={apiErrorMessage(detail.error, "Couldn't work up this finding.")} onRetry={() => void detail.refetch()} />
      </div>
    );
  }
  const data = detail.data;
  const app = apps?.find((candidate) => candidate.slug === data.app);

  return (
    <article className={cn("space-y-5", !bare && "p-4 sm:p-5")}>
      <header className="space-y-2">
        <div className="flex flex-wrap items-center gap-2 text-xs text-muted">
          <Badge tone={SEVERITY_TONES[data.severity]}>{SEVERITY_LABELS[data.severity]}</Badge>
          <Badge>{TRIAGE_KIND_LABELS[data.kind]}</Badge>
          {data.app ? (
            <ScopedLink to={`/apps/${data.app}`} className="inline-flex items-center gap-1 hover:text-foreground">
              <AppDot app={app} />
              {app?.name ?? data.app}
            </ScopedLink>
          ) : null}
          <span className="tabular font-mono">score {Math.round(data.score)}</span>
        </div>
        {bare ? null : <h3 className="break-words text-base font-semibold text-foreground">{data.title}</h3>}
        <p className="text-sm text-foreground">{data.summary}</p>
        <DetailActions detail={data} />
        <DismissalControls detail={data} onAnswered={onAnswered} />
      </header>

      <Section title="What this is">
        <p className="text-sm leading-relaxed text-muted">{data.description}</p>
      </Section>

      {data.facts.length > 0 ? (
        <Section title="Facts">
          <FactList className="md:grid-cols-2 xl:grid-cols-3">
            {data.facts.map((fact) => (
              <Fact key={fact.label} label={fact.label} value={fact.value} />
            ))}
          </FactList>
        </Section>
      ) : null}

      <Section title="Evidence">
        <div className="space-y-3">
          {data.evidence.map((evidence, index) => (
            <EvidenceBlock key={`${evidence.type}-${index}`} evidence={evidence} app={data.app} apps={apps} />
          ))}
        </div>
      </Section>

      <Section title="Suggested steps">
        <ol className="list-decimal space-y-1.5 pl-5 text-sm text-foreground marker:text-muted">
          {data.steps.map((step) => (
            <li key={step}>{step}</li>
          ))}
        </ol>
      </Section>

      <Section title="The brief an agent gets">
        <p className="mb-2 text-xs text-muted">Everything above as Markdown. The `triage` MCP tool hands over the same text.</p>
        <CodeBlock value={data.brief} className="max-h-72 whitespace-pre-wrap break-words" />
      </Section>
    </article>
  );
}

function DetailActions({ detail }: { detail: TriageDetail }) {
  const { copied, copy } = useCopied();
  const explore = useExploreHref();
  const download = () => {
    const url = URL.createObjectURL(new Blob([detail.brief], { type: "text/markdown" }));
    const link = document.createElement("a");
    link.href = url;
    link.download = `triage-${detail.kind}-${(detail.app ?? "fleet").replace(/[^a-z0-9-]+/gi, "-")}.md`;
    link.click();
    URL.revokeObjectURL(url);
  };
  return (
    <div className="flex flex-wrap gap-2 pt-1">
      <Button size="sm" onClick={() => void copy(detail.brief)}>
        {copied ? <Check className="h-4 w-4" aria-hidden /> : <ClipboardCopy className="h-4 w-4" aria-hidden />}
        {copied ? "Copied" : "Copy for an agent"}
      </Button>
      <Button size="sm" variant="secondary" onClick={download}>
        <Download className="h-4 w-4" aria-hidden />
        Download .md
      </Button>
      <Link to={rowsHref(detail, explore)} className="inline-flex h-8 items-center gap-1.5 rounded-[var(--radius-control)] border border-border bg-surface-raised px-3 text-sm text-foreground hover:bg-border/40">
        <ExternalLink className="h-4 w-4" aria-hidden />
        The rows
      </Link>
    </div>
  );
}

/**
 * Dismiss (out of the list until it is worse than now) or ignore (out for
 * good) — and, once answered, what that means and the way back.
 */
function DismissalControls({ detail, onAnswered }: { detail: TriageDetail; onAnswered: (id: string) => void }) {
  const { user } = useAuth();
  // Both answer inline beside the buttons, so neither is toasted as well.
  const answer = useFormMutation({
    mutationFn: (mode: TriageDismissalMode) => api.put(`/triage/${detail.id}/dismissal`, { mode, from: detail.from, to: detail.to }),
    meta: { invalidates: [keys.triage.all] },
    fallback: "Couldn't save that.",
    onSuccess: () => {
      // Moving on: the list it moves along is the one the person was looking at.
      if (!detail.dismissal || detail.dismissal.regressed) onAnswered(detail.id);
    },
  });
  const restore = useFormMutation({
    mutationFn: () => api.delete(`/triage/${detail.id}/dismissal`),
    meta: { invalidates: [keys.triage.all] },
    fallback: "Couldn't put that back.",
  });
  const dismissal = detail.dismissal;
  const guest = user?.role === "guest";
  const busy = answer.isPending || restore.isPending;
  const error = answer.errorMessage ?? restore.errorMessage;

  const dismiss = (
    <Button key="dismissed" size="sm" variant="secondary" disabled={busy} onClick={() => answer.mutate("dismissed")} title="Out of the list until it is worse than it is now">
      <EyeOff className="h-4 w-4" aria-hidden />
      {dismissal?.mode === "ignored" ? "Dismiss instead" : "Dismiss"}
    </Button>
  );
  const ignore = (
    <Button key="ignored" size="sm" variant="ghost" disabled={busy} onClick={() => answer.mutate("ignored")} title="Out of the list for good, whatever it does">
      <BellOff className="h-4 w-4" aria-hidden />
      {dismissal?.mode === "dismissed" && !dismissal.regressed ? "Ignore instead" : "Ignore"}
    </Button>
  );
  const buttons = (() => {
    if (guest) return [];
    if (!dismissal || dismissal.regressed) return [dismiss, ignore];
    return [
      <Button key="restore" size="sm" variant="secondary" disabled={busy} onClick={() => restore.mutate()}>
        <Undo2 className="h-4 w-4" aria-hidden />
        Put back
      </Button>,
      dismissal.mode === "ignored" ? dismiss : ignore,
    ];
  })();
  if (!dismissal && buttons.length === 0) return null;

  return (
    <div className="space-y-1.5">
      {dismissal ? (
        <p className={cn("rounded-[var(--radius-control)] border px-2.5 py-1.5 text-xs", dismissal.regressed ? "border-warning/25 bg-warning/10 text-warning" : "border-border bg-surface-raised text-muted")}>
          {dismissalText(dismissal)}
        </p>
      ) : null}
      {buttons.length > 0 ? <div className="flex flex-wrap gap-2">{buttons}</div> : null}
      <FormError message={error} className="text-xs" />
    </div>
  );
}

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section>
      <h4 className="mb-2 text-[11px] font-semibold uppercase tracking-wider text-muted">{title}</h4>
      {children}
    </section>
  );
}
