import { useQuery } from "@tanstack/react-query";
import { api } from "@/api/client";
import { PageBody } from "@/components/layout/PageBody";
import { ScopedLink } from "@/components/scope/ScopedLink";
import { Badge } from "@/components/ui/Badge";
import { Segmented } from "@/components/ui/Segmented";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import { useUrlEnum } from "@/hooks/useSearchParamState";
import { keys } from "@/lib/queryKeys";
import { relativeTime } from "@/lib/time";
import type { ActivityEntry } from "@/types";

const SEVERITIES = [
  { key: "", label: "All" },
  { key: "warn", label: "Warnings" },
  { key: "error", label: "Errors" },
] as const;
const SEVERITY_KEYS = SEVERITIES.map((entry) => entry.key);

/** Glass's own operational trail: what it did to itself, and what went wrong. */
export function ActivityLog() {
  const [severity, setSeverity] = useUrlEnum("severity", SEVERITY_KEYS, "");
  const entries = useQuery({
    queryKey: keys.activity.list(severity, 1),
    queryFn: () => api.get<ActivityEntry[]>(`/events?per=100${severity ? `&severity=${severity}` : ""}`),
    refetchInterval: 30_000,
  });
  return (
    <PageBody className="space-y-3 py-4">
      <Segmented segments={SEVERITIES} value={severity} onChange={setSeverity} label="Severity" size="sm" />
      <QueryState
        query={entries}
        errorMessage="Couldn't load the activity trail."
        empty={<EmptyState title="Nothing recorded" description="Maintenance, backups and configuration changes land here." />}
      >
        {(list) => (
          <ul className="divide-y divide-border rounded-[var(--radius-card)] border border-border bg-surface">
            {list.map((entry) => (
              <li key={entry.id} className="flex flex-wrap items-center gap-2 px-3 py-2 text-sm">
                <Badge tone={entry.severity === "error" ? "danger" : entry.severity === "warn" ? "warning" : "neutral"}>{entry.severity}</Badge>
                <span className="font-mono text-xs text-muted">{entry.source}</span>
                <span className="text-foreground">{entry.summary}</span>
                {entry.subject?.path ? (
                  <ScopedLink to={entry.subject.path} className="text-xs text-primary hover:underline">
                    {entry.subject.label}
                  </ScopedLink>
                ) : null}
                <span className="ml-auto text-xs text-muted" title={new Date(entry.created_at).toLocaleString()}>
                  {relativeTime(entry.created_at)}
                </span>
              </li>
            ))}
          </ul>
        )}
      </QueryState>
    </PageBody>
  );
}
