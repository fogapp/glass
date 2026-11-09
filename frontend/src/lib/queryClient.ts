import { MutationCache, QueryCache, QueryClient, type QueryKey } from "@tanstack/react-query";
import { ApiError } from "@/api/client";
import { toast } from "@/components/ui/Toast";
import { clearSession } from "@/hooks/useAuth";

declare module "@tanstack/react-query" {
  interface Register {
    mutationMeta: {
      /**
       * What this mutation changes on the server, as query-key prefixes.
       * The MutationCache invalidates each one once the mutation succeeds, so
       * a mutation says *what* it touched and never hand-rolls the refresh —
       * the drift that left some want-changing actions skipping the
       * dashboard. Keys come from `keys`; a prefix cascades to everything
       * nested under it.
       */
      invalidates?: readonly QueryKey[];
    };
  }
}

/** A 401 anywhere means the token is gone or revoked — clear and bounce to
 *  login rather than leaving the console half-authenticated. */
function handleUnauthorized(error: unknown) {
  if (error instanceof ApiError && error.status === 401) {
    clearSession();
    if (window.location.pathname !== "/login") window.location.href = "/login";
  }
}

export function createQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: {
        staleTime: 30_000,
        // No retries on any 4xx: a 403/404/422 is deterministic — retrying
        // just multiplies backend load and delays the ErrorState.
        retry: (failureCount, error) =>
          error instanceof ApiError && error.status >= 400 && error.status < 500
            ? false
            : failureCount < 2,
      },
    },
    queryCache: new QueryCache({ onError: handleUnauthorized }),
    mutationCache: new MutationCache({
      onSuccess: (_data, _variables, _onMutateResult, mutation, context) => {
        // Not awaited: the mutation settles as soon as the server answers,
        // and the refetches land behind it — as the hand-written
        // `void invalidateQueries(...)` calls always did.
        for (const queryKey of mutation.meta?.invalidates ?? []) {
          void context.client.invalidateQueries({ queryKey });
        }
      },
      onError: (error, _variables, _onMutateResult, mutation) => {
        handleUnauthorized(error);
        if (error instanceof ApiError && error.status === 401) return;
        // A mutation that declares its own onError owns its error UI (the
        // forms with inline messages). Everything else gets the shared toast —
        // a silently failed mutation refetches the unchanged value and reads
        // as a no-op, and "silent failure is the enemy" applies here too.
        if (mutation.options.onError) return;
        toast.error(error instanceof ApiError ? error.message : "That didn't go through.");
      },
    }),
  });
}
