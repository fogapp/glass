import { useQuery } from "@tanstack/react-query";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import type { Dashboard } from "@/types";

/** The household's dashboards, for the list and for "add to dashboard" in the Explorer. */
export function useDashboards() {
  return useQuery({ queryKey: keys.dashboards.list(), queryFn: () => api.get<Dashboard[]>("/dashboards") });
}
