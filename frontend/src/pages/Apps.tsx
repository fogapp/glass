import { Link } from "react-router-dom";
import { ScopedLink } from "@/components/scope/ScopedLink";
import { PageBody } from "@/components/layout/PageBody";
import { AppDot } from "@/components/scope/AppDot";
import { useApps } from "@/hooks/useApps";
import { Badge } from "@/components/ui/Badge";
import { EmptyState, ErrorState, LoadingState } from "@/components/ui/PageState";
import { formatAgo, shortSha } from "@/lib/format";
import { containerOnly } from "@/lib/apps";

/** Every app Glass knows: reporting, silent or known only through fog, and where to configure them. */
export function Apps() {
  const apps = useApps();
  if (apps.isPending) return <LoadingState />;
  if (apps.isError) return <ErrorState message="Couldn't load the apps." onRetry={() => void apps.refetch()} />;
  if (apps.data.length === 0) {
    return (
      <EmptyState
        title="No apps yet"
        description="Add one to mint its ingest key — two values and it is instrumented."
        action={
          <Link to="/settings/apps" className="text-primary underline">
            Settings › Apps
          </Link>
        }
      />
    );
  }
  return (
    <PageBody className="py-4">
      <ul className="divide-y divide-border rounded-[var(--radius-card)] border border-border bg-surface">
        {apps.data.map((app) => (
          <li key={app.slug}>
            <ScopedLink to={`/apps/${app.slug}`} className="flex items-center gap-3 px-3 py-2.5 hover:bg-surface-raised">
              <AppDot app={app} live={app.reporting} className="h-2.5 w-2.5" />
              <span className="font-medium text-foreground">{app.name}</span>
              <span className="font-mono text-xs text-muted">{app.slug}</span>
              <span className="ml-auto font-mono text-xs text-muted">{shortSha(app.release)}</span>
              {app.reporting ? (
                <Badge tone="success">{app.live_processes} live</Badge>
              ) : containerOnly(app) ? (
                <Badge tone={app.fog?.healthy === false || app.fog?.state !== "running" ? "danger" : "neutral"} title="no agent — what fog says of its container">
                  fog: {app.fog?.healthy === false ? "unhealthy" : (app.fog?.state ?? "?")}
                </Badge>
              ) : (
                <Badge tone="warning">silent · {app.last_seen_at ? formatAgo(app.last_seen_at) : "never"}</Badge>
              )}
            </ScopedLink>
          </li>
        ))}
      </ul>
      <p className="mt-3 text-xs text-muted">
        Keys, identity mode and agent settings are under{" "}
        <Link to="/settings/apps" className="text-primary hover:underline">
          Settings › Apps
        </Link>
        .
      </p>
    </PageBody>
  );
}
