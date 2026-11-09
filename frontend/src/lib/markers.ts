import { useQuery } from "@tanstack/react-query";
import { api } from "@/api/client";
import { roundRange } from "@/lib/glassQuery";
import { keys } from "@/lib/queryKeys";
import type { TimeRange } from "@/lib/timeRange";
import type { Marker, TimeseriesResult } from "@/types";

/**
 * The markers a chart draws: those in its range, of the apps its query
 * read (`result.apps`, when its filter confined it) — and those of no app,
 * which belong to every chart.
 */
export function markersFor(markers: Marker[], result: Pick<TimeseriesResult, "from" | "to"> & { apps?: string[] }): Marker[] {
  const apps = result.apps ? new Set(result.apps) : null;
  return markers.filter((marker) => marker.ts >= result.from && marker.ts <= result.to && (marker.app === null || apps === null || apps.has(marker.app)));
}

/** Deploys and events in a range, for the lines on every chart. */
export function useMarkers(range: TimeRange, app: string | null, live = false) {
  const { from, to } = roundRange(range);
  return useQuery({
    queryKey: keys.markers.range(from, to, app ?? ""),
    queryFn: () => api.get<Marker[]>(`/markers?from=${from}&to=${to}${app ? `&app=${encodeURIComponent(app)}` : ""}`),
    refetchInterval: live ? 30_000 : false,
    staleTime: 30_000,
    placeholderData: (previous) => previous,
  });
}
