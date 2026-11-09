import { useNavigate, useParams, useSearchParams } from "react-router-dom";
import { PageBody } from "@/components/layout/PageBody";
import { Panel, QueryBody } from "@/components/charts/Panel";
import { Heatmap } from "@/components/charts/Heatmap";
import { TransactionList } from "@/components/telemetry/TransactionList";
import { TraceView } from "@/components/telemetry/TraceView";
import { useApps } from "@/hooks/useApps";
import { Sheet } from "@/components/ui/Sheet";
import { Segmented } from "@/components/ui/Segmented";
import { QueryBar } from "@/components/telemetry/QueryBar";
import { CursorPager } from "@/components/telemetry/CursorPager";
import { useCursor } from "@/hooks/useCursor";
import { useFilterParam } from "@/hooks/useFilterParam";
import { useUrlEnum } from "@/hooks/useSearchParamState";
import { listRows } from "@/lib/listRows";
import { useGlassQuery } from "@/lib/glassQuery";
import { useScope, withScope } from "@/lib/scope";
import { absoluteRange } from "@/lib/timeRange";
import type { HeatmapResult, ListResult, TransactionRow } from "@/types";

const VIEWS = [
  { key: "all", label: "All" },
  { key: "kept", label: "With spans" },
  { key: "errors", label: "Errors" },
  { key: "slow", label: "Slow" },
] as const;
type View = (typeof VIEWS)[number]["key"];
const VIEW_KEYS = VIEWS.map((entry) => entry.key);

/**
 * Requests and jobs, newest first, with the latency heatmap above them so
 * an outlier is a click away; a trace opens beside the list.
 */
export function Traces() {
  const scope = useScope();
  const apps = useApps();
  const navigate = useNavigate();
  const { id } = useParams();
  const [params] = useSearchParams();
  const [view, setView] = useUrlEnum<View>("view", VIEW_KEYS, "all");
  const { filter, draft, setDraft, apply } = useFilterParam("q");

  const extra = view === "kept" ? "kept:true" : view === "errors" ? "status:error" : view === "slow" ? "duration:>1s" : "";
  const full = withScope(scope, filter, extra);
  const { before, setBefore } = useCursor(`${full}|${scope.range.from}|${scope.range.to}`);
  const list = useGlassQuery<ListResult>(
    { source: "transactions", shape: "list", from: scope.range.from, to: scope.range.to, filter: full, limit: 100, before: before ?? undefined },
    { live: scope.live && before === null },
  );
  const heat = useGlassQuery<HeatmapResult>({ source: "transactions", shape: "heatmap", from: scope.range.from, to: scope.range.to, filter: full, field: "duration" }, { live: scope.live });

  return (
    <PageBody className="space-y-3 py-4">
      <div className="flex flex-wrap items-center gap-2">
        <QueryBar value={draft} onChange={setDraft} onSubmit={apply} source="transactions" className="min-w-64 flex-1" placeholder="status:error name:*Wants* duration:>250ms @want_id:…" />
        <Segmented segments={VIEWS} value={view} onChange={setView} label="Which traces" size="sm" />
      </div>
      <Panel title="Latency" subtitle="every request and job in range, by duration — click a cell">
        <QueryBody query={heat} height={140} isEmpty={(data) => data.cells.length === 0}>
          {(data) => (
            <Heatmap
              result={data}
              height={140}
              onCell={(from, to, low, high) => {
                scope.setRange(absoluteRange(from, to));
                apply(`${filter} duration:${low.toFixed(1)}..${high.toFixed(1)}`.trim());
              }}
            />
          )}
        </QueryBody>
      </Panel>
      <Panel title={before ? "Earlier" : "Newest first"}>
        <QueryBody query={list} height={200} isEmpty={(data) => data.rows.length === 0}>
          {(data) => (
            <>
              <TransactionList rows={listRows<TransactionRow>(data)} apps={apps.data} onSelect={(row) => navigate(`/traces/${row.trace}?${params.toString()}`)} selected={id ?? null} />
              <CursorPager before={before} next={data.next_before} onChange={setBefore} className="mt-2" />
            </>
          )}
        </QueryBody>
      </Panel>
      {id ? (
        <Sheet open onClose={() => navigate(`/traces?${params.toString()}`)} title="Trace" size="lg">
          <TraceView id={id} />
        </Sheet>
      ) : null}
    </PageBody>
  );
}
