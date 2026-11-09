import { Link, useSearchParams } from "react-router-dom";
import { ArrowRight, Rocket } from "lucide-react";
import { Sparkline } from "@/components/charts/Sparkline";
import { AppDot, appColor } from "@/components/scope/AppDot";
import { Tabs } from "@/components/ui/Tabs";
import { Failures } from "@/components/ui/Failures";
import { useGlassBatch, type GlassBatch } from "@/lib/glassQuery";
import { useScope } from "@/lib/scope";
import { useScopedNavigate } from "@/lib/scopeHref";
import { shortSha } from "@/lib/format";
import { cn } from "@/lib/cn";
import { LENSES, TRAFFIC, lensFor, type Lens, type LensKey, type Tile } from "@/pages/overview/lenses";
import type { App, Marker } from "@/types";

/**
 * The Overview's tile per app, through the lens its tabs pick (`?lens=`, so
 * a slice can be pasted to someone). Traffic reads the Overview's own
 * batch, which opens with its queries; any other lens asks for its own only
 * while it is showing.
 */
export function AppGrid({ apps, loadFailed, traffic, markers }: { apps: App[] | undefined; loadFailed: boolean; traffic: GlassBatch; markers: Marker[] }) {
  const scope = useScope();
  const navigate = useScopedNavigate();
  const [params, setParams] = useSearchParams();
  const lens = lensFor(params.get("lens"));
  const own = lens.key !== TRAFFIC.key;

  const sliced = useGlassBatch(own ? lens.specs(scope) : {}, { live: scope.live, enabled: own });
  const { answer } = own ? sliced : traffic;

  const visibleApps = (apps ?? []).filter((app) => !scope.app || app.slug === scope.app);

  function choose(key: LensKey) {
    setParams(
      (current) => {
        const next = new URLSearchParams(current);
        if (key === TRAFFIC.key) next.delete("lens");
        else next.set("lens", key);
        return next;
      },
      { replace: true },
    );
  }

  return (
    <section>
      <h2 className="text-xs font-semibold uppercase tracking-wider text-muted">Apps</h2>
      <div className="mb-3 border-b border-border">
        <Tabs tabs={LENSES} active={lens.key} onChange={choose} label="What the app tiles show" />
      </div>
      {own ? <Failures messages={sliced.failures} /> : null}
      {loadFailed ? <p className="text-sm text-negative">Couldn't load the apps.</p> : null}
      {apps && visibleApps.length === 0 ? (
        <div className="rounded-[var(--radius-card)] border border-dashed border-border p-6 text-center text-sm text-muted">
          No apps yet.{" "}
          <Link to="/settings/apps" className="text-primary underline">
            Add one
          </Link>{" "}
          to get its ingest key.
        </div>
      ) : null}
      <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
        {visibleApps.map((app) => (
          <AppTile
            key={app.slug}
            app={app}
            lens={lens}
            tile={lens.tile(app, answer)}
            deploys={markers.filter((marker) => marker.app === app.slug && marker.kind === "deploy").length}
            onOpen={() => navigate(lens.href(app))}
          />
        ))}
      </div>
    </section>
  );
}

function AppTile({ app, lens, tile, deploys, onOpen }: { app: App; lens: Lens; tile: Tile | null; deploys: number; onOpen: () => void }) {
  return (
    <button
      type="button"
      onClick={onOpen}
      className="flex flex-col items-stretch rounded-[var(--radius-card)] border border-border bg-surface p-3 text-left hover:border-primary/40"
    >
      <div className="flex items-center gap-2">
        <AppDot app={app} live={app.reporting} />
        <span className="font-medium text-foreground">{app.name}</span>
        <span className="ml-auto font-mono text-[11px] text-muted">{shortSha(app.release)}</span>
        {!app.reporting ? (
          <span className="rounded-full border border-warning/40 bg-warning/10 px-1.5 text-[10px] font-medium uppercase tracking-wider text-warning">silent</span>
        ) : null}
      </div>
      {tile ? (
        <dl className={cn("tabular mt-3 grid gap-2 text-xs", tile.figures.length > 3 ? "grid-cols-4" : "grid-cols-3")}>
          {tile.figures.map((figure) => (
            <div key={figure.label} className="min-w-0">
              <dt className="truncate text-muted">{figure.label}</dt>
              <dd className={cn("truncate font-mono text-foreground", figure.tone === "negative" && "text-negative", figure.tone === "warning" && "text-warning")}>{figure.value}</dd>
            </div>
          ))}
        </dl>
      ) : (
        // As tall as the figures it stands in for, so the grid keeps its rows.
        <p className="mt-3 flex h-[34px] items-center text-xs text-muted">{lens.empty}</p>
      )}
      <div className="mt-auto flex items-end gap-3 pt-2">
        <span title={tile?.primary.label}>
          <Sparkline values={tile?.primary.values ?? []} width={140} height={28} color={appColor(app)} />
        </span>
        <span title={tile?.secondary.label}>
          <Sparkline values={tile?.secondary.values ?? []} width={140} height={28} color="var(--color-muted)" fill={false} />
        </span>
        <span className="ml-auto flex items-center gap-1 text-[11px] text-muted">
          <Rocket className="h-3 w-3" aria-hidden /> {deploys}
          <ArrowRight className="ml-1 h-3 w-3" aria-hidden />
        </span>
      </div>
    </button>
  );
}
