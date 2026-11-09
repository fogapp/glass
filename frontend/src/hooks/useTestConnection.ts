import { useMutation, useQueryClient, type QueryKey } from "@tanstack/react-query";
import { api } from "@/api/client";
import type { TestResult } from "@/types";

/**
 * A Settings Test button's state: posts to the connection's test endpoint,
 * keeps the latest answer (the mutation's own data) to show beside it, and
 * refreshes the resource so its stored last-test line catches up.
 */
export function useTestConnection(path: string, invalidate: QueryKey | readonly QueryKey[]) {
  const queryClient = useQueryClient();
  const refresh = (Array.isArray(invalidate[0]) ? invalidate : [invalidate]) as readonly QueryKey[];
  const mutation = useMutation({
    mutationFn: () => api.post<TestResult>(path),
    onSuccess: () => {
      for (const queryKey of refresh) void queryClient.invalidateQueries({ queryKey });
    },
  });
  return { run: () => mutation.mutate(), pending: mutation.isPending, result: mutation.data ?? null };
}

export type TestConnection = ReturnType<typeof useTestConnection>;
