import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { api } from "@/api/client";
import { PageBody } from "@/components/layout/PageBody";
import { AppDot } from "@/components/scope/AppDot";
import { useApps } from "@/hooks/useApps";
import { DataTable } from "@/components/ui/DataTable";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import { keys } from "@/lib/queryKeys";
import { useScope } from "@/lib/scope";
import { formatAgo, formatCount, shortSha } from "@/lib/format";
import { cn } from "@/lib/cn";
import type { Column, SortState } from "@/lib/dataTable";
import type { AgentProcess, App } from "@/types";

const shedOf = (process: AgentProcess) => Object.values(process.dropped).reduce((sum, count) => sum + count, 0);

const COLUMNS: Column<AgentProcess>[] = [
  {
    key: "process",
    header: "Process",
    sortValue: (process) => process.kind,
    cell: (process) => (
      <span className="flex items-center gap-1.5">
        <span className={cn("inline-block h-1.5 w-1.5 rounded-full", process.live ? "bg-primary shadow-[0_0_6px_var(--color-primary)]" : "bg-muted")} aria-hidden />
        <span className="font-mono text-xs text-foreground">{process.kind}</span>
      </span>
    ),
  },
  { key: "host", header: "Host · pid", sortValue: (process) => process.host, cell: (process) => <span className="font-mono text-xs">{process.host} · {process.pid}</span> },
  { key: "release", header: "Release", sortValue: (process) => process.release, cell: (process) => <span className="font-mono text-xs">{shortSha(process.release)}</span> },
  {
    key: "runtime",
    header: "Runtime",
    cell: (process) => (
      <span className="font-mono text-xs text-muted">
        {["ruby", "rails", "agent"]
          .filter((key) => process.runtime[key])
          .map((key) => `${key} ${process.runtime[key]}`)
          .join(" · ")}
      </span>
    ),
  },
  {
    key: "records",
    header: "Records",
    className: "text-right",
    sortValue: (process) => process.records,
    cell: (process) => (
      <span className="tabular font-mono text-xs">
        {formatCount(process.records)} <span className="text-muted">in {formatCount(process.batches)} batches</span>
      </span>
    ),
  },
  {
    key: "shed",
    header: "Shed",
    className: "text-right",
    sortValue: shedOf,
    cell: (process) => {
      const shed = shedOf(process);
      return (
        <span className={cn("tabular font-mono text-xs", shed > 0 && "text-warning")} title={JSON.stringify(process.dropped)}>
          {shed > 0 ? formatCount(shed) : "—"}
        </span>
      );
    },
  },
  { key: "last", header: "Last report", className: "text-right", sortValue: (process) => process.last_seen_at, cell: (process) => <span className="tabular text-xs">{formatAgo(process.last_seen_at)}</span> },
];

/**
 * Every reporting process: what it runs, how fresh its heartbeat is, what
 * its agent has shed. The page that answers "is it them or is it us".
 */
export function Fleet() {
  const scope = useScope();
  const fleet = useQuery({ queryKey: keys.fleet.list(), queryFn: () => api.get<AgentProcess[]>("/fleet"), refetchInterval: 10_000 });
  return (
    <PageBody className="py-4">
      <QueryState
        query={fleet}
        errorMessage="Couldn't load the fleet."
        isEmpty={(all) => !all.some((process) => !scope.app || process.app === scope.app)}
        empty={<EmptyState title="Nothing has reported yet" description="A process appears here on its first batch. Add an app under Settings to get an ingest key." />}
      >
        {(all) => <FleetTable processes={all.filter((process) => !scope.app || process.app === scope.app)} />}
      </QueryState>
    </PageBody>
  );
}

function FleetTable({ processes }: { processes: AgentProcess[] }) {
  const apps = useApps();
  const [sort, setSort] = useState<SortState>({ key: "last", direction: "desc" });
  const group = useMemo(
    () => ({
      of: (process: AgentProcess) => process.app ?? "?",
      header: (slug: string, rows: readonly AgentProcess[]) => <AppHeader slug={slug} app={apps.data?.find((candidate) => candidate.slug === slug)} rows={rows} />,
    }),
    [apps.data],
  );
  return (
    <div className="rounded-[var(--radius-card)] border border-border bg-surface">
      <DataTable
        caption="Reporting processes, grouped by app"
        columns={COLUMNS}
        rows={processes}
        rowKey={(process) => String(process.id)}
        sort={sort}
        onSortChange={setSort}
        group={group}
        rowClassName={(process) => (process.live ? undefined : "opacity-60")}
      />
    </div>
  );
}

function AppHeader({ slug, app, rows }: { slug: string; app: App | undefined; rows: readonly AgentProcess[] }) {
  return (
    <span className="flex items-center gap-2">
      <AppDot app={app} live={rows.some((process) => process.live)} />
      <span className="text-sm font-medium text-foreground">{app?.name ?? slug}</span>
      <span className="text-xs font-normal text-muted">
        {rows.filter((process) => process.live).length} of {rows.length} live
      </span>
    </span>
  );
}
