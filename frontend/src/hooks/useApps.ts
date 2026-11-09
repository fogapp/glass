import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import type { App } from "@/types";

/** How often the console re-asks which apps exist and whether they report. */
const APPS_POLL_MS = 30_000;

/** Every app in the household: one query, one polling cadence, shared by every page. */
export function useApps() {
  return useQuery({ queryKey: keys.apps.list(), queryFn: () => api.get<App[]>("/apps"), refetchInterval: APPS_POLL_MS, staleTime: 10_000 });
}

/** The household's apps by slug. */
export function useAppsBySlug(): Map<string, App> {
  const apps = useApps();
  return useMemo(() => new Map((apps.data ?? []).map((app) => [app.slug, app])), [apps.data]);
}
