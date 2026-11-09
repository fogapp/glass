import { useEffect, useMemo, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { api } from "@/api/client";
import { PageBody } from "@/components/layout/PageBody";
import { Panel, QueryBody } from "@/components/charts/Panel";
import { Flamegraph, functionTotals } from "@/components/charts/Flamegraph";
import { Timeseries } from "@/components/charts/Timeseries";
import { QueryBar } from "@/components/telemetry/QueryBar";
import { useFilterParam, type LegacyTerms } from "@/hooks/useFilterParam";
import { DataTable } from "@/components/ui/DataTable";
import { Segmented } from "@/components/ui/Segmented";
import { useUrlEnum } from "@/hooks/useSearchParamState";
import { keys } from "@/lib/queryKeys";
import { useGlassQuery } from "@/lib/glassQuery";
import { useMarkers } from "@/lib/markers";
import { useScope, withScope } from "@/lib/scope";
import { absoluteRange, describeRange, previousRange } from "@/lib/timeRange";
import { formatCount, formatMs, formatPercent } from "@/lib/format";
import { cn } from "@/lib/cn";
import type { Column, SortState } from "@/lib/dataTable";
import { PROFILE_STATES, type Flamegraph as FlamegraphData, type ProfileState, type TimeseriesResult } from "@/types";

/** What a sample's thread was doing, in words; every state the profiler records has one. */
const STATE_LABELS: Record<ProfileState, string> = { running: "Running", stalled: "Stalled (GVL)", idle: "Idle (I/O)", gc: "GC" };
const STATES: { key: StateKey; label: string }[] = [{ key: "", label: "All states" }, ...PROFILE_STATES.map((key) => ({ key, label: STATE_LABELS[key] }))];
type StateKey = ProfileState | "";
const STATE_KEYS: readonly StateKey[] = STATES.map((entry) => entry.key);
const COMPARES = ["none", "previous", "custom"] as const;
/** An endpoint's "profile it" link names its transaction outright. */
const LEGACY_TERMS: LegacyTerms = { transaction: (name) => `transaction:"${name}"` };

/**
 * Where the time actually goes: the merged flamegraph for
 * any filter, its top functions, a diff against a baseline, and CPU time
 * by endpoint over the range.
 */
export function Profiles() {
  const scope = useScope();
  const [params] = useSearchParams();
  const { filter: filterParam, draft, setDraft, apply } = useFilterParam("q", LEGACY_TERMS);
  const [state, setState] = useUrlEnum<StateKey>("state", STATE_KEYS, "");
  const [search, setSearch] = useState("");
  const [focus, setFocus] = useState<number | null>(null);
  // A deploy's diff arrives with its baseline in the URL, and compares against it until told otherwise.
  const [compare, setCompare] = useUrlEnum("compare", COMPARES, params.get("baseline_from") ? "custom" : "none");

  const filter = withScope(scope, filterParam, state ? `state:${state}` : "");
  const baseline = useMemo(() => {
    if (compare === "previous") return previousRange(scope.range);
    if (compare === "custom" && params.get("baseline_from") && params.get("baseline_to")) return absoluteRange(Number(params.get("baseline_from")), Number(params.get("baseline_to")));
    return null;
  }, [compare, scope.range, params]);

  const body = useMemo(
    () => ({ from: scope.range.from, to: scope.range.to, filter, baseline: baseline ? { from: baseline.from, to: baseline.to, filter } : undefined }),
    [scope.range.from, scope.range.to, filter, baseline],
  );
  const flamegraph = useQuery({
    queryKey: keys.profiles.flamegraph(body),
    queryFn: ({ signal }) => api.post<FlamegraphData>("/profiles/flamegraph", body, { signal }),
    placeholderData: (previous) => previous,
    staleTime: 10_000,
  });
  useEffect(() => setFocus(null), [body]);

  const byTransaction = useGlassQuery<TimeseriesResult>(
    { source: "profiles", shape: "timeseries", from: scope.range.from, to: scope.range.to, filter: withScope(scope, filterParam, "state:running"), compute: ["sum(ms)"], group_by: ["transaction"], limit: 8 },
    { live: scope.live },
  );
  const byState = useGlassQuery<TimeseriesResult>(
    { source: "profiles", shape: "timeseries", from: scope.range.from, to: scope.range.to, filter: withScope(scope, filterParam), compute: ["sum(ms)"], group_by: ["state"], limit: 4 },
    { live: scope.live },
  );
  const markers = useMarkers(scope.range, scope.app, scope.live);

  const data = flamegraph.data;
  const crumbs = useMemo(() => {
    if (!data || focus === null) return [];
    const path: number[] = [];
    for (let cursor = focus; cursor > 0; cursor = data.nodes[cursor]?.[1] ?? 0) path.unshift(cursor);
    return path;
  }, [data, focus]);

  return (
    <PageBody className="space-y-3 py-4">
      <div className="flex flex-wrap items-center gap-2">
        <QueryBar value={draft} onChange={setDraft} onSubmit={apply} source="profiles" className="min-w-64 flex-1" placeholder='app:hook transaction:"Api::V1::WantsController#index" process:web release:3df7786' />
        <Segmented segments={STATES} value={state} onChange={setState} label="Thread state" size="sm" />
        <select
          aria-label="Compare against"
          value={compare}
          onChange={(event) => setCompare(event.target.value as typeof compare)}
          className="h-8 rounded-[var(--radius-control)] border border-border bg-input px-2 text-xs text-foreground"
        >
          <option value="none">No comparison</option>
          <option value="previous">vs the previous window</option>
          {params.get("baseline_from") ? <option value="custom">vs the window before the deploy</option> : null}
        </select>
      </div>

      <Panel
        title={data?.diff ? "Flamegraph — change vs baseline" : "Flamegraph"}
        subtitle={
          data
            ? `${formatMs(data.total_ms)} sampled · ${formatCount(data.samples[0])} samples${data.diff ? ` · baseline ${formatMs(data.baseline_total_ms ?? 0)} (${baseline ? describeRange(baseline) : ""})` : ""}`
            : undefined
        }
        actions={
          <input
            value={search}
            onChange={(event) => setSearch(event.target.value)}
            placeholder="find a function…"
            aria-label="Search functions"
            className="h-7 w-44 rounded-[var(--radius-control)] border border-border bg-input px-2 font-mono text-xs text-foreground"
          />
        }
      >
        {crumbs.length > 0 && data ? (
          <p className="mb-1 flex flex-wrap items-center gap-1 font-mono text-[11px] text-muted">
            <button type="button" className="hover:text-foreground" onClick={() => setFocus(null)}>
              all
            </button>
            {crumbs.map((node) => (
              <span key={node} className="flex items-center gap-1">
                <span>›</span>
                <button type="button" className={cn("hover:text-foreground", node === focus && "text-foreground")} onClick={() => setFocus(node)}>
                  {data.functions[data.nodes[node]?.[0] ?? 0]?.name}
                </button>
              </span>
            ))}
          </p>
        ) : null}
        <QueryBody query={flamegraph} height={256}>
          {(graph) =>
            graph.nodes.length <= 1 ? (
              <p className="py-12 text-center text-sm text-muted">No profile samples match this filter and range.</p>
            ) : (
              <Flamegraph data={graph} search={search} focus={focus ?? undefined} onFocus={setFocus} />
            )
          }
        </QueryBody>
        {data?.diff ? (
          <p className="mt-2 text-[11px] text-muted">
            Warmer frames took a larger share of the profile than in the baseline; cooler frames a smaller one. Grey moved less than 5%.
          </p>
        ) : (
          <p className="mt-2 flex flex-wrap gap-3 text-[11px] text-muted">
            <Legend color="var(--color-series-1)" label="app code" />
            <Legend color="var(--color-series-7)" label="dependencies" />
            <Legend color="var(--color-series-4)" label="the runtime" />
            <Legend color="var(--color-series-3)" label="native" />
          </p>
        )}
      </Panel>

      <div className="grid gap-3 lg:grid-cols-2">
        <Panel title="Top functions" subtitle="by self time — where the samples actually landed">
          <QueryBody query={flamegraph} height={160}>
            {(graph) => (graph.nodes.length <= 1 ? <p className="py-6 text-center text-xs text-muted">Nothing sampled</p> : <TopFunctions data={graph} onPick={setSearch} />)}
          </QueryBody>
        </Panel>
        <div className="space-y-3">
          <Panel title="CPU time by endpoint" subtitle="running samples, per bucket">
            <QueryBody query={byTransaction} height={180} isEmpty={(result) => result.series.length === 0}>
              {(result) => <Timeseries result={result} markers={markers.data} height={180} stacked onBrush={(from, to) => scope.setRange(absoluteRange(from, to))} />}
            </QueryBody>
          </Panel>
          <Panel title="Thread state" subtitle="running · stalled waiting for the GVL · idle in I/O">
            <QueryBody query={byState} height={140} isEmpty={(result) => result.series.length === 0}>
              {(result) => <Timeseries result={result} markers={markers.data} height={140} stacked onBrush={(from, to) => scope.setRange(absoluteRange(from, to))} />}
            </QueryBody>
          </Panel>
        </div>
      </div>
    </PageBody>
  );
}

type FunctionTotal = ReturnType<typeof functionTotals>[number];
/** A function's total against the baseline's, as a fraction; new code counts as all change. */
const change = (row: FunctionTotal) => (row.baseTotal > 0 ? (row.total - row.baseTotal) / row.baseTotal : row.total > 0 ? 1 : 0);

/** The functions the samples landed in, by self time; picking one finds it in the flamegraph. */
function TopFunctions({ data, onPick }: { data: FlamegraphData; onPick: (name: string) => void }) {
  const [sort, setSort] = useState<SortState>({ key: "self", direction: "desc" });
  const rows = useMemo(() => functionTotals(data).sort((a, b) => b.self - a.self).slice(0, 40), [data]);
  const columns = useMemo<Column<FunctionTotal>[]>(() => {
    const name = (row: FunctionTotal) => data.functions[row.fn]?.name ?? "?";
    const base: Column<FunctionTotal>[] = [
      {
        key: "function",
        header: "Function",
        sortValue: name,
        cell: (row) => {
          const fn = data.functions[row.fn];
          return (
            <>
              <button type="button" className="block w-full truncate text-left font-mono text-xs text-foreground hover:text-primary" onClick={() => onPick(name(row))} title={fn ? `${fn.file}:${fn.line}` : undefined}>
                {name(row)}
              </button>
              <span className="block truncate font-mono text-[10px] text-muted">{fn?.file}</span>
            </>
          );
        },
      },
      {
        key: "self",
        header: "Self",
        className: "w-32 text-right",
        sortValue: (row) => row.self,
        cell: (row) => (
          <span className="tabular font-mono text-xs">
            {formatMs(row.self)} <span className="text-muted">{formatPercent(row.self / (data.total_ms || 1), 0)}</span>
          </span>
        ),
      },
      { key: "total", header: "Total", className: "w-20 text-right", sortValue: (row) => row.total, cell: (row) => <span className="tabular font-mono text-xs">{formatMs(row.total)}</span> },
    ];
    if (!data.diff) return base;
    return [
      ...base,
      {
        key: "change",
        header: "Δ total",
        className: "w-20 text-right",
        sortValue: change,
        cell: (row) => {
          const delta = change(row);
          return (
            <span className={cn("tabular font-mono text-xs", delta > 0.05 ? "text-negative" : delta < -0.05 ? "text-primary" : "text-muted")}>
              {delta >= 0 ? "+" : ""}
              {formatPercent(delta, 0)}
            </span>
          );
        },
      },
    ];
  }, [data, onPick]);
  return <DataTable caption="Top functions by self time" columns={columns} rows={rows} rowKey={(row) => String(row.fn)} sort={sort} onSortChange={setSort} fluid />;
}

function Legend({ color, label }: { color: string; label: string }) {
  return (
    <span className="flex items-center gap-1">
      <span className="inline-block h-2 w-2 rounded-sm" style={{ background: color }} aria-hidden />
      {label}
    </span>
  );
}
