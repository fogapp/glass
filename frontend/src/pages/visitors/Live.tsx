import { Panel, QueryBody } from "@/components/charts/Panel";
import { AppDot } from "@/components/scope/AppDot";
import { useApps } from "@/hooks/useApps";
import { useGlassQuery } from "@/lib/glassQuery";
import { useScope, withScope } from "@/lib/scope";
import { useScopedNavigate } from "@/lib/scopeHref";
import { formatAgo } from "@/lib/format";
import { useNow } from "@/hooks/useNow";
import { cn } from "@/lib/cn";
import { listRows } from "@/lib/listRows";
import type { App, ListResult } from "@/types";

/** Who is on right now: the latest visits, each openable as a timeline. */
export function LiveTab() {
  const scope = useScope();
  const apps = useApps();
  const navigate = useScopedNavigate();
  // The clock the window and the glow are read on: stable between ticks, so a render is not a new window.
  const now = useNow(10_000);
  const list = useGlassQuery<ListResult>(
    { source: "visits", shape: "list", from: now - 2 * 86_400, to: now + 60, filter: withScope(scope), limit: 100 },
    { live: true },
  );
  const recent = listRows<VisitRow>(list.data).slice(0, 100);
  return (
    <Panel title="Recent visits" subtitle="newest first — the ones seen in the last five minutes glow">
      <QueryBody query={list} height={200} isEmpty={(data) => data.rows.length === 0}>
        {() => <VisitList rows={recent} apps={apps.data} onOpen={(visit) => navigate(`/visitors/live/${visit}`)} now={now} />}
      </QueryBody>
    </Panel>
  );
}

export interface VisitRow {
  ts: number;
  app: string | null;
  visit: string;
  visitor: string | null;
  user: string | null;
  entry_path: string | null;
  exit_path: string | null;
  referrer: string | null;
  browser: string | null;
  os: string | null;
  device: string | null;
  origin: string | null;
  pageviews: number;
  interactions: number;
  errors: number;
  duration: number;
}

export function VisitList({ rows, apps, onOpen, now }: { rows: VisitRow[]; apps: App[] | undefined; onOpen: (visit: string) => void; now: number }) {
  return (
    <ul className="divide-y divide-border">
      {rows.map((row) => {
        const active = row.ts + row.duration > now - 300;
        return (
          <li key={row.visit}>
            <button type="button" onClick={() => onOpen(row.visit)} className="flex w-full items-center gap-3 px-2 py-1.5 text-left text-sm hover:bg-surface-raised">
              <span className={cn("inline-block h-1.5 w-1.5 shrink-0 rounded-full", active ? "bg-primary shadow-[0_0_6px_var(--color-primary)]" : "bg-muted")} aria-hidden />
              <AppDot app={apps?.find((app) => app.slug === row.app)} />
              <span className="w-28 shrink-0 truncate font-mono text-xs text-foreground">{row.user ?? row.visitor ?? "anonymous"}</span>
              <span className="hidden w-24 shrink-0 text-xs text-muted sm:inline">
                {row.device ?? "?"} · {row.browser ?? "?"}
              </span>
              <span className="min-w-0 flex-1 truncate font-mono text-xs text-muted">
                {row.entry_path}
                {row.exit_path && row.exit_path !== row.entry_path ? ` → ${row.exit_path}` : ""}
              </span>
              <span className="tabular shrink-0 text-xs text-muted">
                {row.pageviews} pages · {row.interactions} clicks{row.errors ? ` · ${row.errors} errors` : ""}
              </span>
              <span className="tabular w-16 shrink-0 text-right text-xs text-muted">{formatAgo(row.ts + row.duration, now)}</span>
            </button>
          </li>
        );
      })}
    </ul>
  );
}
