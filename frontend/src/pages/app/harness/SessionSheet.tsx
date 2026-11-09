import { useMemo } from "react";
import { ExternalLink } from "lucide-react";
import { Panel, QueryBody } from "@/components/charts/Panel";
import { PhaseBar } from "@/components/charts/PhaseBar";
import { RunList } from "@/components/telemetry/RunList";
import { Kpi } from "@/components/ui/Kpi";
import { Sheet } from "@/components/ui/Sheet";
import { Failures } from "@/components/ui/Failures";
import { useGlassBatch } from "@/lib/glassQuery";
import { ScopedLink } from "@/components/scope/ScopedLink";
import { useExploreHref, term } from "@/lib/explore";
import { formatCount, formatDateTime, formatMs, formatPercent, formatUsd, num, optionalNum } from "@/lib/format";
import { useNow } from "@/hooks/useNow";
import { linkFor, PHASE_COMPUTES } from "@/lib/runs";
import type { App, ListResult, TableResult, TransactionRow } from "@/types";
import { phasesOf } from "@/pages/app/harness/shared";

/** A session of a harness: its runs in order, as a visit is its pages in order. */
export function SessionSheet({ app, session, onClose }: { app: App; session: string; onClose: () => void }) {
  const explore = useExploreHref();
  const now = useNow();
  // A conversation is not bounded by the scope bar's range: it is looked for where transactions are kept.
  const range = useMemo(() => ({ from: now - 30 * 86_400, to: now + 60 }), [now]);
  const filter = `app:${app.slug} kind:run ${term("session", session)}`;
  const { batch, answer, failures } = useGlassBatch({
    runs: { source: "transactions", shape: "list", ...range, filter, limit: 200 },
    totals: { source: "transactions", shape: "table", ...range, filter, compute: ["count", "sum(cost)", "sum(active)", "sum(wait)", "sum(input_total)", "sum(tokens_out)", "ratio(cache_read, input_total)", ...PHASE_COMPUTES] },
  });
  const rows = [...((answer<ListResult>("runs")?.rows ?? []) as unknown as TransactionRow[])].reverse();
  const totals = answer<TableResult>("totals")?.rows[0];
  const link = linkFor(app, { session, attrs: rows[0]?.attrs });

  return (
    <Sheet open onClose={onClose} title="Conversation" description={`${app.name} · ${session}`} size="lg">
      <div className="space-y-4">
      <Failures messages={failures} />
        <div className="flex flex-wrap items-center gap-3 text-xs">
          {rows.length > 0 ? (
            <span className="text-muted">
              {formatDateTime(rows[0]!.ts)} → {formatDateTime(rows.at(-1)!.ts)}
            </span>
          ) : null}
          <ScopedLink to={explore({ shape: "list", filter })} className="text-primary hover:underline">
            As rows
          </ScopedLink>
          <ScopedLink to={explore({ source: "model_calls", shape: "list", filter: `app:${app.slug} ${term("session", session)}` })} className="text-primary hover:underline">
            Its model calls
          </ScopedLink>
          {link ? (
            <a href={link} target="_blank" rel="noreferrer" className="flex items-center gap-1 text-primary hover:underline" title="Glass is never sent what was said; the app's own console has it">
              Open in {app.name} <ExternalLink className="h-3 w-3" aria-hidden />
            </a>
          ) : null}
        </div>
        <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
          <Kpi label="Runs" value={formatCount(num(totals?.count))} />
          <Kpi label="Spent" value={formatUsd(num(totals?.["sum(cost)"]))} hint={`${formatCount(num(totals?.["sum(input_total)"]))} in · ${formatCount(num(totals?.["sum(tokens_out)"]))} out`} />
          <Kpi label="Active" value={formatMs(num(totals?.["sum(active)"]))} hint={num(totals?.["sum(wait)"]) > 0 ? `+ ${formatMs(num(totals?.["sum(wait)"]))} waiting on a person` : undefined} />
          <Kpi label="From cache" value={formatPercent(optionalNum(totals?.["ratio(cache_read, input_total)"]), 0)} hint="of input tokens" />
        </div>
        <Panel title="Where the time went" subtitle="mean per run">
          <QueryBody query={batch} height={52}>{() => <PhaseBar parts={phasesOf(totals)} format={formatMs} />}</QueryBody>
        </Panel>
        <Panel title="In order" subtitle="oldest first — a row opens its trace">
          <QueryBody query={batch} height={160}>{() => <RunList rows={rows} emptyLabel="No runs under this session in the last thirty days" />}</QueryBody>
        </Panel>
      </div>
    </Sheet>
  );
}
