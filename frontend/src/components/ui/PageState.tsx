import type { ReactNode } from "react";
import type { UseQueryResult } from "@tanstack/react-query";
import { AlertTriangle, Loader2 } from "lucide-react";
import { Button } from "./Button";

/**
 * A failed query must never render as an empty list — a list page doing
 * `{ data = [] }` with no isError branch makes outages indistinguishable
 * from "nothing here yet". Every list screen uses
 * these three states.
 */
export function LoadingState({ label = "Loading…" }: { label?: string }) {
  return (
    <div className="flex items-center justify-center gap-2 py-12 text-muted">
      <Loader2 className="h-4 w-4 animate-spin" aria-hidden />
      <span className="text-sm">{label}</span>
    </div>
  );
}

export function ErrorState({
  title = "Something went wrong",
  message,
  onRetry,
}: {
  title?: string;
  message?: string;
  onRetry?: () => void;
}) {
  return (
    <div className="flex flex-col items-center gap-3 py-12 text-center">
      <AlertTriangle className="h-6 w-6 text-negative" aria-hidden />
      <div>
        <p className="font-medium text-foreground">{title}</p>
        {message ? <p className="mt-1 text-sm text-muted">{message}</p> : null}
      </div>
      {onRetry ? (
        <Button variant="secondary" size="sm" onClick={onRetry}>
          Try again
        </Button>
      ) : null}
    </div>
  );
}

export function EmptyState({
  title,
  description,
  action,
}: {
  title: string;
  description?: string;
  action?: ReactNode;
}) {
  return (
    <div className="flex flex-col items-center gap-3 py-12 text-center">
      <div>
        <p className="font-medium text-foreground">{title}</p>
        {description ? <p className="mt-1 text-sm text-muted">{description}</p> : null}
      </div>
      {action}
    </div>
  );
}

/**
 * The loading / error / empty / data split a list screen needs, written once
 * so a failed query can never fall through to an empty list. `empty` renders
 * when the data is an empty array (or `isEmpty` says so); leave it out and an
 * empty result renders through `children` like any other.
 */
export function QueryState<T>({
  query,
  errorMessage,
  loadingLabel,
  empty,
  isEmpty,
  children,
}: {
  query: UseQueryResult<T>;
  errorMessage: string;
  loadingLabel?: string;
  empty?: ReactNode;
  isEmpty?: (data: T) => boolean;
  children: (data: T) => ReactNode;
}) {
  if (query.isPending) return <LoadingState label={loadingLabel} />;
  if (query.isError) return <ErrorState message={errorMessage} onRetry={() => void query.refetch()} />;
  const data = query.data;
  const blank = isEmpty ? isEmpty(data) : Array.isArray(data) && data.length === 0;
  if (empty !== undefined && empty !== null && blank) return <>{empty}</>;
  return <>{children(data)}</>;
}
