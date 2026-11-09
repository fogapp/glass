import { useMemo, useState, type FormEvent, type ReactNode } from "react";
import { useParams } from "react-router-dom";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Pencil, Plus, Trash2 } from "lucide-react";
import { api, apiErrorMessage } from "@/api/client";
import { PageBody } from "@/components/layout/PageBody";
import { Panel, QueryBody } from "@/components/charts/Panel";
import { Button } from "@/components/ui/Button";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { IconButton } from "@/components/ui/IconButton";
import { Input } from "@/components/ui/Input";
import { GridLayout } from "@/components/ui/GridLayout";
import { Menu } from "@/components/ui/Menu";
import { toast } from "@/components/ui/Toast";
import { DashboardHeader, HeaderSheet, type HeaderFields } from "@/pages/dashboards/HeaderWidget";
import { ChartLabelsSheet, type ChartLabels } from "@/pages/dashboards/ChartLabelsSheet";
import { widgetLabels } from "@/lib/widgetLabels";
import { HEADER_SIZE_STYLES, headerMinRows } from "@/lib/headerIcons";
import { EmptyState, ErrorState, LoadingState } from "@/components/ui/PageState";
import { useGlassQueries, isQueryError } from "@/lib/glassQuery";
import { keys } from "@/lib/queryKeys";
import { useScope } from "@/lib/scope";
import { useScopedNavigate } from "@/lib/scopeHref";
import { ScopedLink } from "@/components/scope/ScopedLink";
import { isEmptyResult, specFor, useExploreHref, withDefaults, type ExploreState } from "@/lib/explore";
import { QueryResultView } from "@/components/telemetry/QueryResultView";
import { cn } from "@/lib/cn";
import { compact, settle, type Cell } from "@/lib/dashboardLayout";
import { useDashboards } from "@/hooks/useDashboards";
import { useElementSize } from "@/hooks/useElementSize";
import type { Dashboard, HeaderWidget, QueryAnswer, QueryWidget, Widget } from "@/types";

/**
 * Dashboards: grids of saved queries. A widget is the
 * Explorer state that made it; every widget still obeys the scope bar.
 * Editing arranges them: drag to move, the corner to resize, the rest make
 * way (`GridLayout`) — and adds headers that name the stretch below them.
 */
export function Dashboards() {
  const { id } = useParams();
  return id ? <DashboardView id={id} /> : <DashboardList />;
}

function DashboardList() {
  const dashboards = useDashboards();
  const queryClient = useQueryClient();
  const navigate = useScopedNavigate();
  const [name, setName] = useState("");
  const create = useMutation({
    mutationFn: () => api.post<Dashboard>("/dashboards", { name: name.trim(), widgets: [] }),
    onSuccess: (created) => {
      void queryClient.invalidateQueries({ queryKey: keys.dashboards.all });
      navigate(`/dashboards/${created.id}`);
    },
  });
  if (dashboards.isPending) return <LoadingState />;
  if (dashboards.isError) return <ErrorState message="Couldn't load dashboards." onRetry={() => void dashboards.refetch()} />;
  return (
    <PageBody className="space-y-4 py-4">
      <form
        onSubmit={(event: FormEvent) => {
          event.preventDefault();
          if (name.trim()) create.mutate();
        }}
        className="flex items-end gap-2"
      >
        <Input label="New dashboard" value={name} onChange={(event) => setName(event.target.value)} placeholder="Evening traffic" className="max-w-xs" />
        <Button type="submit" size="sm" disabled={create.isPending || !name.trim()}>
          Create
        </Button>
      </form>
      {dashboards.data.length === 0 ? (
        <EmptyState title="No dashboards yet" description="Create one, then pin any Explorer query to it with its ⌘ Pin button." />
      ) : (
        <ul className="divide-y divide-border rounded-[var(--radius-card)] border border-border bg-surface">
          {dashboards.data.map((dashboard) => (
            <li key={dashboard.id}>
              <ScopedLink to={`/dashboards/${dashboard.id}`} className="flex items-center gap-3 px-3 py-2.5 hover:bg-surface-raised">
                <span className="font-medium text-foreground">{dashboard.name}</span>
                {dashboard.description ? <span className="truncate text-xs text-muted">{dashboard.description}</span> : null}
                <span className="ml-auto text-xs text-muted">
                  {dashboard.widgets.length} {dashboard.widgets.length === 1 ? "widget" : "widgets"}
                </span>
              </ScopedLink>
            </li>
          ))}
        </ul>
      )}
    </PageBody>
  );
}

function DashboardView({ id }: { id: string }) {
  const explore = useExploreHref();
  const scope = useScope();
  const queryClient = useQueryClient();
  const navigate = useScopedNavigate();
  const dashboard = useQuery({ queryKey: keys.dashboards.detail(id), queryFn: () => api.get<Dashboard>(`/dashboards/${id}`) });
  const [editing, setEditing] = useState(false);
  // The header sheet: open for a new header (no id) or for the one named.
  const [headerSheet, setHeaderSheet] = useState<{ id?: string } | null>(null);
  // The labels sheet, for the chart named.
  const [labelsSheet, setLabelsSheet] = useState<string | null>(null);
  const widgets = useMemo(() => dashboard.data?.widgets ?? [], [dashboard.data]);
  // Only queries ask anything; a header is text.
  const queries = useMemo(() => widgets.filter((widget): widget is QueryWidget => widget.kind === "query"), [widgets]);
  // Each widget asks what the Explorer asked when it was pinned (`specFor`); one still waiting for its metric asks nothing.
  const asked = useMemo(
    () => queries.flatMap((widget) => {
      const spec = specFor({ ...withDefaults(widget.spec), limit: widget.spec.limit }, scope);
      return spec ? [{ id: widget.id, spec }] : [];
    }),
    [queries, scope],
  );
  const specs = useMemo(() => asked.map((entry) => entry.spec), [asked]);
  const batch = useGlassQueries(specs, { live: scope.live, enabled: specs.length > 0 });
  const save = useMutation({
    mutationFn: (next: Partial<Dashboard>) => api.patch<Dashboard>(`/dashboards/${id}`, next),
    // A widget dropped somewhere new stays there while the change is saved.
    onMutate: (next) => {
      const previous = queryClient.getQueryData<Dashboard>(keys.dashboards.detail(id));
      if (previous) queryClient.setQueryData(keys.dashboards.detail(id), { ...previous, ...next });
      return { previous };
    },
    // Declaring onError opts out of the shared toast, so this one says it.
    onError: (error, _next, context) => {
      if (context?.previous) queryClient.setQueryData(keys.dashboards.detail(id), context.previous);
      toast.error(apiErrorMessage(error, "Couldn't save this dashboard."));
    },
    onSuccess: (updated) => {
      queryClient.setQueryData(keys.dashboards.detail(id), updated);
      void queryClient.invalidateQueries({ queryKey: keys.dashboards.list() });
    },
  });
  const remove = useMutation({
    mutationFn: () => api.delete(`/dashboards/${id}`),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: keys.dashboards.all });
      navigate("/dashboards");
    },
  });

  if (dashboard.isPending) return <LoadingState />;
  if (dashboard.isError) return <ErrorState message="Couldn't load this dashboard." onRetry={() => void dashboard.refetch()} />;
  const data = dashboard.data;
  // A header may be as short as its text allows; a chart needs room for its axes.
  const cellsOf = (list: Widget[]): Cell[] => list.map((widget) => (widget.kind === "header" ? { ...widget, minH: headerMinRows(widget) } : widget));
  const cells = cellsOf(widgets);
  const placed = (list: Widget[], layout: Cell[]): Widget[] => {
    const places = new Map(layout.map(({ id, x, y, w, h }) => [id, { x, y, w, h }]));
    return list.map((widget) => ({ ...widget, ...places.get(widget.id) })).sort((a, b) => a.y - b.y || a.x - b.x);
  };
  const arrange = (layout: Cell[]) => save.mutate({ widgets: placed(widgets, layout) });
  // A new header goes in at the top, where it can be seen, and the rest move down for it.
  const addHeader = (fields: HeaderFields) => {
    const header: HeaderWidget = { id: crypto.randomUUID().replace(/-/g, "").slice(0, 12), kind: "header", ...fields, x: 0, y: 0, w: 12, h: HEADER_SIZE_STYLES[fields.size].rows };
    return save.mutateAsync({ widgets: placed([header, ...widgets], settle([header, ...compact(cells)])) });
  };
  // A header that grows taller text grows to fit it, and what's below moves down.
  const editHeader = (headerId: string, fields: HeaderFields) => {
    const next = widgets.map((widget) => (widget.id === headerId ? { ...widget, ...fields } : widget));
    return save.mutateAsync({ widgets: placed(next, compact(cellsOf(next))) });
  };
  const answerOf = (widget: QueryWidget) => batch.data?.results[asked.findIndex((entry) => entry.id === widget.id)];
  const titleOf = (widget: Widget) => (widget.kind === "header" ? widget.title : widgetLabels(widget, answerOf(widget)).title);
  const relabel = (chartId: string, labels: ChartLabels) => save.mutateAsync({ widgets: widgets.map((widget) => (widget.id === chartId ? { ...widget, ...labels } : widget)) });
  const labelled = labelsSheet ? queries.find((widget) => widget.id === labelsSheet) : undefined;
  const removeWidget = (widgetId: string) => save.mutate({ widgets: widgets.filter((widget) => widget.id !== widgetId) });
  const editedHeader = headerSheet?.id ? widgets.find((widget): widget is HeaderWidget => widget.id === headerSheet.id && widget.kind === "header") : undefined;

  return (
    <PageBody className="space-y-3 py-4">
      <div className="flex flex-wrap items-center gap-2">
        <ScopedLink to="/dashboards" className="text-xs text-muted hover:text-foreground">
          Dashboards
        </ScopedLink>
        <span className="text-muted">/</span>
        {editing ? (
          <input
            defaultValue={data.name}
            aria-label="Dashboard name"
            onBlur={(event) => event.target.value.trim() && event.target.value !== data.name && save.mutate({ name: event.target.value.trim() })}
            className="h-8 rounded-[var(--radius-control)] border border-border bg-input px-2 text-sm font-medium text-foreground"
          />
        ) : (
          <h1 className="text-base font-semibold text-foreground">{data.name}</h1>
        )}
        <span className="ml-auto flex items-center gap-1">
          {editing ? (
            <Menu label="Add" icon={<span aria-hidden className="inline-flex items-center gap-1.5 text-xs"><Plus className="h-3.5 w-3.5" aria-hidden /> Add</span>} size="compact" className="mr-1">
              {(close) => (
                <div className="flex flex-col gap-1 text-sm">
                  <button
                    type="button"
                    className="rounded-[var(--radius-control)] px-2 py-1.5 text-left text-foreground hover:bg-surface"
                    onClick={() => {
                      close();
                      setHeaderSheet({});
                    }}
                  >
                    Header
                    <span className="block text-xs text-muted">A heading, a line under it, an icon</span>
                  </button>
                  <ScopedLink to={explore({})} className="rounded-[var(--radius-control)] px-2 py-1.5 text-foreground hover:bg-surface">
                    Chart
                    <span className="block text-xs text-muted">Build a query in Explore and pin it</span>
                  </ScopedLink>
                </div>
              )}
            </Menu>
          ) : null}
          <Button variant={editing ? "primary" : "secondary"} size="sm" onClick={() => setEditing((value) => !value)}>
            <Pencil className="h-3.5 w-3.5" aria-hidden /> {editing ? "Done" : "Edit"}
          </Button>
          {editing ? (
            <ConfirmButton question="Delete this dashboard?" onConfirm={() => remove.mutate()} variant="ghost" size="sm">
              <Trash2 className="h-3.5 w-3.5" aria-hidden /> Delete
            </ConfirmButton>
          ) : null}
        </span>
      </div>
      {widgets.length === 0 ? (
        <EmptyState
          title="Nothing pinned yet"
          description="Build a query in Explore and pin it here, or add a header with Edit › Add."
          action={
            <ScopedLink to={explore({})} className="text-primary underline">
              Open Explore
            </ScopedLink>
          }
        />
      ) : null}
      {editing && widgets.length > 0 ? <p className="hidden text-xs text-muted lg:block">Drag a widget to move it, its corner to resize it.</p> : null}
      <GridLayout
        cells={cells}
        editing={editing}
        onChange={arrange}
        label={(cell) => titleOf(widgets.find((widget) => widget.id === cell)!)}
      >
        {(cell) => {
          const widget = widgets.find((each) => each.id === cell.id)!;
          if (widget.kind === "header") {
            return (
              <DashboardHeader
                header={widget}
                editing={editing}
                actions={
                  editing ? (
                    <>
                      <IconButton label="Edit header" size="sm" onClick={() => setHeaderSheet({ id: widget.id })}>
                        <Pencil className="h-3.5 w-3.5" aria-hidden />
                      </IconButton>
                      <IconButton label="Remove header" size="sm" onClick={() => removeWidget(widget.id)}>
                        <Trash2 className="h-3.5 w-3.5" aria-hidden />
                      </IconButton>
                    </>
                  ) : null
                }
              />
            );
          }
          const answer = answerOf(widget);
          const labels = widgetLabels(widget, answer);
          return (
            <Panel
              title={labels.title}
              subtitle={labels.subtitle}
              className="flex h-full flex-col"
              bodyClassName={cn("min-h-0 flex-1", editing && "pointer-events-none")}
              actions={
                editing ? (
                  <>
                    <IconButton label="Edit labels" size="sm" onClick={() => setLabelsSheet(widget.id)}>
                      <Pencil className="h-3.5 w-3.5" aria-hidden />
                    </IconButton>
                    <IconButton label="Remove widget" size="sm" onClick={() => removeWidget(widget.id)}>
                      <Trash2 className="h-3.5 w-3.5" aria-hidden />
                    </IconButton>
                  </>
                ) : (
                  <ScopedLink to={explore(widget.spec)} className="text-xs text-muted hover:text-primary">
                    open
                  </ScopedLink>
                )
              }
            >
              <FitBody>
                {(height) => (
                  <QueryBody query={batch} height={height} fill>
                    {() => (answer ? <WidgetBody state={withDefaults(widget.spec)} answer={answer} height={height} /> : null)}
                  </QueryBody>
                )}
              </FitBody>
            </Panel>
          );
        }}
      </GridLayout>
      {labelled ? <ChartLabelsSheet widget={labelled} answer={answerOf(labelled)} onClose={() => setLabelsSheet(null)} onSave={(labels) => relabel(labelled.id, labels)} /> : null}
      {headerSheet ? (
        <HeaderSheet
          header={editedHeader}
          onClose={() => setHeaderSheet(null)}
          onSave={(fields) => (editedHeader ? editHeader(editedHeader.id, fields) : addHeader(fields))}
        />
      ) : null}
    </PageBody>
  );
}

/** A widget's body measured, so its chart can be exactly as tall as the cell leaves room for. */
function FitBody({ children }: { children: (height: number) => ReactNode }) {
  const [box, { height }] = useElementSize<HTMLDivElement>();
  return (
    <div ref={box} className="h-full">
      {height > 0 ? children(height) : null}
    </div>
  );
}

/** A widget's answer: what its query said went wrong, that there is nothing, or the chart the Explorer draws. */
function WidgetBody({ state, answer, height }: { state: ExploreState; answer: QueryAnswer; height: number }) {
  if (isQueryError(answer)) return <p className="text-xs text-negative">{answer.errors.join(", ")}</p>;
  if (isEmptyResult(answer)) return <p className="flex h-full items-center justify-center text-xs text-muted">No data in this range</p>;
  return <QueryResultView state={state} data={answer} height={height} fill />;
}
