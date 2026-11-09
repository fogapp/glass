import { EmptyState, LoadingState } from "@/components/ui/PageState";
import { useMarkers } from "@/lib/markers";
import { useScope } from "@/lib/scope";
import { useScopedNavigate } from "@/lib/scopeHref";
import { absoluteRange } from "@/lib/timeRange";
import { rangeParam } from "@/lib/explore";
import { formatAgo, shortSha } from "@/lib/format";
import { containerOnly } from "@/lib/apps";
import type { App } from "@/types";

/** The app's deploys in range, newest first. */
export function DeploysTab({ app }: { app: App }) {
  const scope = useScope();
  const markers = useMarkers(scope.range, app.slug, scope.live);
  const deploys = (markers.data ?? []).filter((marker) => marker.kind === "deploy");
  const navigate = useScopedNavigate();
  const bare = containerOnly(app);
  if (markers.isPending) return <LoadingState />;
  if (deploys.length === 0) return <EmptyState title="No deploys in this range" description="A deploy is inferred when a process reports a release the app has not reported before, or told by fog." />;
  return (
    <ul className="divide-y divide-border rounded-[var(--radius-card)] border border-border bg-surface">
      {deploys.map((deploy, index) => {
        const next = deploys[index - 1];
        const previous = deploys[index + 1];
        const after = { from: deploy.ts, to: next ? next.ts : scope.range.to };
        const before = previous ? { from: previous.ts, to: deploy.ts } : { from: deploy.ts - (after.to - after.from), to: deploy.ts };
        return (
          <li key={`${deploy.ts}-${index}`} className="flex flex-wrap items-center gap-3 px-3 py-2 text-sm">
            {deploy.release ? <span className="font-mono text-foreground">{shortSha(deploy.release)}</span> : <span className="text-foreground">{deploy.title}</span>}
            <span className="text-muted">{new Date(deploy.ts * 1000).toLocaleString()}</span>
            <span className="text-xs text-muted">({formatAgo(deploy.ts)})</span>
            <span className="ml-auto flex gap-2 text-xs">
              <button type="button" className="text-primary hover:underline" onClick={() => scope.setRange(absoluteRange(before.from - (before.to - before.from) * 0.1, after.to))}>
                Frame it
              </button>
              {bare ? null : (
                <button
                  type="button"
                  className="text-primary hover:underline"
                  onClick={() =>
                    // The window after the deploy is the scope's own range, so the Profiles page reads it as any other.
                    navigate(
                      `/profiles?app=${app.slug}&range=${rangeParam(after.from, after.to).range}&baseline_from=${Math.floor(before.from)}&baseline_to=${Math.floor(before.to)}`,
                    )
                  }
                >
                  Flamegraph diff
                </button>
              )}
            </span>
          </li>
        );
      })}
    </ul>
  );
}
