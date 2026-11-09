import type { BadgeTone } from "@/components/ui/Badge";
import { exploreHref } from "@/lib/explore";
import { formatAgo } from "@/lib/format";
import { TRIAGE_KINDS, type TriageDetail, type TriageDismissal, type TriageFinding, type TriageKind, type TriageSeverity } from "@/types";

/** What each kind of finding is called on a chip and a badge. */
export const TRIAGE_KIND_LABELS: Record<TriageKind, string> = {
  incident: "Alerting",
  stuck: "Stuck",
  failing: "Failing",
  regression: "Slower",
  stall: "Stalls",
  reporting: "Reporting",
  hotspot: "Hotspot",
  n_plus_one: "N+1",
  queue: "Queue wait",
  log_errors: "Error logs",
  model_errors: "Model errors",
  vitals: "Web vitals",
};

export const SEVERITY_LABELS: Record<TriageSeverity, string> = { critical: "Critical", warning: "Warning", notice: "Notice" };
export const SEVERITY_TONES: Record<TriageSeverity, BadgeTone> = { critical: "danger", warning: "warning", notice: "neutral" };

/** How many findings of each value of `key`. */
export function countBy<K extends string>(findings: TriageFinding[], key: (finding: TriageFinding) => K): Map<K, number> {
  const counts = new Map<K, number>();
  for (const finding of findings) counts.set(key(finding), (counts.get(key(finding)) ?? 0) + 1);
  return counts;
}

/** The kinds present, in the legend's order. */
export function kindsPresent(findings: TriageFinding[]): TriageKind[] {
  const present = new Set(findings.map((finding) => finding.kind));
  return TRIAGE_KINDS.filter((kind) => present.has(kind));
}

/** The rows behind a finding, over the range it was found in; `href` is a page's `useExploreHref()`, which keeps the rest of the scope. */
export function rowsHref(detail: Pick<TriageDetail, "source" | "filter" | "from" | "to">, href: typeof exploreHref = exploreHref): string {
  return href({ source: detail.source, shape: "list", filter: detail.filter }, { range: `${Math.floor(detail.from)}-${Math.ceil(detail.to)}` });
}

/** "compared with the 4 days before" */
export function baselineText(report: { from: number; baseline_from: number }): string {
  const hours = (report.from - report.baseline_from) / 3600;
  const [count, unit] = hours >= 24 ? [Number((hours / 24).toFixed(1)), "day"] : [Number(hours.toFixed(1)), "hour"];
  return count === 1 ? `${unit}` : `${count} ${unit}s`;
}

/**
 * Where a dismissal leaves a finding, in a sentence: "Dismissed by Ada 3h
 * ago at 52 (Warning) — it comes back at 62 or more, or once it is critical."
 */
export function dismissalText(dismissal: TriageDismissal, now = Date.now() / 1000): string {
  const who = `${dismissal.by ? ` by ${dismissal.by}` : ""} ${formatAgo(dismissal.at, now)}`;
  if (dismissal.mode === "ignored") return `Ignored${who} — it stays out of the list, whatever it does.`;
  const was = `Dismissed${who} at ${Math.round(dismissal.score)} (${SEVERITY_LABELS[dismissal.severity]})`;
  if (dismissal.regressed) return `${was} — it is worse now, so it is back.`;
  const worse = dismissal.severity === "critical" ? "" : `, or once it is ${dismissal.severity === "notice" ? "a warning" : "critical"}`;
  return `${was} — it comes back at ${Math.round(dismissal.returns_above ?? dismissal.score)} or more${worse}.`;
}
