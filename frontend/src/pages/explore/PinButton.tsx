import { useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "@/api/client";
import { Menu } from "@/components/ui/Menu";
import { toast } from "@/components/ui/Toast";
import { ScopedLink } from "@/components/scope/ScopedLink";
import { useDashboards } from "@/hooks/useDashboards";
import { keys } from "@/lib/queryKeys";
import type { ExploreState } from "@/lib/explore";
import type { Dashboard } from "@/types";

/**
 * Pin the current query to a dashboard as a widget — with the limit it was
 * asked with, so the dashboard draws the series that were pinned.
 */
export function PinButton({ state, limit }: { state: ExploreState; limit: number }) {
  const dashboards = useDashboards();
  const queryClient = useQueryClient();
  const pin = useMutation({
    mutationFn: (dashboard: Dashboard) =>
      api.post<Dashboard>(`/dashboards/${dashboard.id}/widgets`, {
        // No title of its own: the dashboard reads its labels from the query (`lib/widgetLabels`).
        widget: { title: "", spec: { source: state.source, shape: state.shape, filter: state.filter, compute: state.compute, group_by: state.group_by, metric: state.metric, field: state.field, limit }, w: 4, h: 6 },
      }),
    onSuccess: (dashboard) => {
      void queryClient.invalidateQueries({ queryKey: keys.dashboards.all });
      toast.info(`Pinned to ${dashboard.name}`);
    },
  });
  return (
    <Menu label="Pin to dashboard" size="compact">
      {(close) => (
        <ul className="-mx-3 -mb-3">
          {(dashboards.data ?? []).length === 0 ? (
            <li className="px-3 pb-2 text-xs text-muted">
              No dashboards yet —{" "}
              <ScopedLink to="/dashboards" className="text-primary underline">
                create one
              </ScopedLink>
            </li>
          ) : null}
          {(dashboards.data ?? []).map((dashboard) => (
            <li key={dashboard.id}>
              <button type="button" onClick={() => pin.mutate(dashboard, { onSuccess: close })} className="w-full px-3 py-1.5 text-left text-sm text-foreground hover:bg-surface">
                {dashboard.name}
              </button>
            </li>
          ))}
        </ul>
      )}
    </Menu>
  );
}
