import { useEffect, useMemo, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { PageBody } from "@/components/layout/PageBody";
import { Panel, QueryBody } from "@/components/charts/Panel";
import { QueryResultView } from "@/components/telemetry/QueryResultView";
import { QueryBar, useCatalog } from "@/components/telemetry/QueryBar";
import { Segmented } from "@/components/ui/Segmented";
import { ScopedLink } from "@/components/scope/ScopedLink";
import { useGlassQuery } from "@/lib/glassQuery";
import { useScope, withScope } from "@/lib/scope";
import { DEFAULT_EXPLORE, METRIC_SHAPES, isEmptyResult, limitFor, parseExplore, specFor, term, useExploreHref, type ExploreState } from "@/lib/explore";
import { fieldsInScope, railFields } from "@/lib/workFields";
import { ComputeEditor } from "@/pages/explore/ComputeEditor";
import { Facet } from "@/pages/explore/Facet";
import { GroupEditor } from "@/pages/explore/GroupEditor";
import { PinButton } from "@/pages/explore/PinButton";
import type { QueryResult, QueryShape, QuerySource } from "@/types";

const SOURCES: { key: QuerySource; label: string }[] = [
  { key: "transactions", label: "Requests, jobs & runs" },
  { key: "spans", label: "Spans" },
  { key: "logs", label: "Logs" },
  { key: "profiles", label: "Profiles" },
  { key: "page_events", label: "Visitor events" },
  { key: "visits", label: "Visits" },
  { key: "model_calls", label: "Model calls" },
  { key: "metrics", label: "Metrics" },
];
const SHAPES: { key: QueryShape; label: string }[] = [
  { key: "timeseries", label: "Over time" },
  { key: "table", label: "Top list" },
  { key: "heatmap", label: "Heatmap" },
  { key: "histogram", label: "Distribution" },
  { key: "list", label: "Rows" },
];
const FACETS: Record<QuerySource, string[]> = {
  transactions: ["app", "kind", "name", "status", "http_status", "method", "release", "process", "origin", "error"],
  spans: ["app", "kind", "name", "status"],
  logs: ["app", "level", "source", "process"],
  profiles: ["app", "transaction", "state", "process", "release"],
  page_events: ["app", "kind", "route", "name", "device", "browser", "origin", "referrer"],
  visits: ["app", "entry_route", "device", "browser", "origin", "referrer", "user"],
  model_calls: ["app", "provider", "model", "purpose", "origin", "agent", "status", "stop", "error"],
  metrics: ["app"],
};

/**
 * The Explorer: one query bar, one time range, every
 * signal. Source, shape, what to compute and how to group, in the URL.
 * The facet rail at the left is the same filter, clickable.
 */
export function Explore() {
  const explore = useExploreHref();
  const scope = useScope();
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const state = useMemo(() => parseExplore(params), [params]);
  const [draft, setDraft] = useState(state.filter);
  useEffect(() => setDraft(state.filter), [state.filter]);
  const catalog = useCatalog();

  const update = (patch: Partial<ExploreState>) => navigate(explore({ ...state, ...patch }));
  const addTerm = (text: string) => update({ filter: `${state.filter} ${text}`.trim() });

  const spec = useMemo(() => specFor(state, scope), [state, scope]);
  const query = useGlassQuery<QueryResult>(spec, { live: scope.live });
  // A monitor watches the same question, in the app the scope names.
  const monitor = new URLSearchParams({ new: "1", source: state.source, filter: withScope(scope, state.filter), compute: state.compute[0] ?? "count", metric: state.metric });

  // The fields worth offering are the ones the kinds in scope carry: tokens for a run, not an HTTP status.
  const fields = fieldsInScope(catalog.data, state.source, state.filter);
  const measures = fields.filter((field) => field.measure).map((field) => field.name);
  const dimensions = fields.filter((field) => !field.measure).map((field) => field.name);
  const metric = catalog.data?.metrics.find((entry) => entry.name === state.metric);
  const functions = state.source === "metrics" ? (catalog.data?.functions.metrics ?? []) : (catalog.data?.functions.events ?? []);

  return (
    <div className="flex min-h-full">
      <aside className="hidden w-56 shrink-0 border-r border-border bg-surface/50 lg:block">
        <div className="sticky top-0 max-h-[calc(100dvh-4.5rem)] overflow-y-auto p-3 scrollbar-thin">
          <p className="mb-2 text-[11px] font-semibold uppercase tracking-wider text-muted">Facets</p>
          {(state.source === "transactions" ? railFields(catalog.data, state.filter) : FACETS[state.source]).map((facet) => (
            <Facet key={facet} source={state.source} facet={facet} filter={withScope(scope, state.filter)} metric={state.metric} onPick={(value) => addTerm(term(facet, value))} />
          ))}
        </div>
      </aside>

      <PageBody className="min-w-0 flex-1 space-y-3 py-4">
        <div className="flex flex-wrap items-center gap-2">
          <select
            aria-label="Source"
            value={state.source}
            onChange={(event) => {
              const next = event.target.value as QuerySource;
              update({ source: next, compute: next === "metrics" ? [] : DEFAULT_EXPLORE.compute, group_by: [], field: next === "profiles" ? "ms" : next === "page_events" ? "lcp" : "duration", filter: "" });
            }}
            className="h-9 rounded-[var(--radius-control)] border border-border bg-input px-2 text-sm text-foreground"
          >
            {SOURCES.map((option) => (
              <option key={option.key} value={option.key}>
                {option.label}
              </option>
            ))}
          </select>
          {state.source === "metrics" ? (
            <select
              aria-label="Metric"
              value={state.metric}
              onChange={(event) => update({ metric: event.target.value, compute: [] })}
              className="h-9 max-w-72 rounded-[var(--radius-control)] border border-border bg-input px-2 font-mono text-xs text-foreground"
            >
              <option value="">Pick a metric…</option>
              {(catalog.data?.metrics ?? []).map((entry) => (
                <option key={entry.name} value={entry.name}>
                  {entry.name} ({entry.kind})
                </option>
              ))}
            </select>
          ) : null}
          <QueryBar value={draft} onChange={setDraft} onSubmit={(text) => update({ filter: text.trim() })} source={state.source} metric={state.metric} className="min-w-64 flex-1" />
        </div>

        <div className="flex flex-wrap items-center gap-x-4 gap-y-2 text-xs">
          <Segmented segments={SHAPES.filter((shape) => state.source !== "metrics" || METRIC_SHAPES.includes(shape.key))} value={state.shape} onChange={(shape) => update({ shape })} label="Shape" size="sm" />
          {state.shape !== "list" ? (
            <ComputeEditor
              computes={state.compute}
              source={state.source}
              functions={functions}
              measures={measures}
              dimensions={dimensions}
              metricKind={metric?.kind}
              onChange={(compute) => update({ compute })}
            />
          ) : null}
          {state.shape === "timeseries" || state.shape === "table" ? (
            <GroupEditor
              groups={state.group_by}
              options={state.source === "metrics" ? ["app", ...(metric?.tags ?? [])] : dimensions}
              onChange={(group_by) => update({ group_by })}
            />
          ) : null}
          {state.shape === "heatmap" || state.shape === "histogram" ? (
            <label className="flex items-center gap-1 text-muted">
              of
              <select value={state.field} onChange={(event) => update({ field: event.target.value })} className="h-7 rounded-[var(--radius-control)] border border-border bg-input px-1.5 font-mono text-xs text-foreground" aria-label="Field">
                {measures.map((field) => (
                  <option key={field} value={field}>
                    {field}
                  </option>
                ))}
              </select>
            </label>
          ) : null}
        </div>

        <Panel
          actions={
            <>
              <PinButton state={state} limit={spec?.limit ?? limitFor(state.shape)} />
              <ScopedLink to={`/monitors?${monitor.toString()}`} className="rounded-[var(--radius-control)] border border-border px-2 py-1 text-xs text-foreground hover:bg-surface-raised">
                Monitor this
              </ScopedLink>
            </>
          }
        >
          {spec === null ? (
            <p className="py-12 text-center text-sm text-muted">Pick a metric to draw.</p>
          ) : (
            <QueryBody query={query} height={260} isEmpty={isEmptyResult}>
              {(data) => <QueryResultView state={state} data={data} height={280} />}
            </QueryBody>
          )}
        </Panel>
      </PageBody>
    </div>
  );
}
