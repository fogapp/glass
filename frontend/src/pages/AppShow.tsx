import { useParams } from "react-router-dom";
import { Flame, ScrollText, Waypoints } from "lucide-react";
import { PageBody } from "@/components/layout/PageBody";
import { PAGE_X } from "@/components/layout/pageLayout";
import { AppDot } from "@/components/scope/AppDot";
import { useApps } from "@/hooks/useApps";
import { Tabs, type TabDescriptor } from "@/components/ui/Tabs";
import { Badge } from "@/components/ui/Badge";
import { EmptyState, ErrorState, LoadingState } from "@/components/ui/PageState";
import { useScopedNavigate } from "@/lib/scopeHref";
import { ScopedLink } from "@/components/scope/ScopedLink";
import { formatAgo, shortSha } from "@/lib/format";
import { containerOnly } from "@/lib/apps";
import { cn } from "@/lib/cn";
import type { App } from "@/types";
import { HarnessOverview, InteractionsTab, ModelsTab, SessionSheet, ToolsTab } from "@/pages/app/Harness";
import { OverviewTab } from "@/pages/app/Overview";
import { TransactionsTab } from "@/pages/app/Transactions";
import { SpansTab } from "@/pages/app/Spans";
import { RuntimeTab } from "@/pages/app/Runtime";
import { ContainerTab } from "@/pages/app/Container";
import { DeploysTab } from "@/pages/app/Deploys";
import { EndpointSheet } from "@/pages/app/EndpointSheet";

type TabKey = "overview" | "interactions" | "models" | "tools" | "endpoints" | "jobs" | "queries" | "external" | "runtime" | "container" | "deploys";

const AGENT_TABS: TabDescriptor<TabKey>[] = [
  { key: "overview", label: "Overview" },
  { key: "endpoints", label: "Endpoints" },
  { key: "jobs", label: "Jobs" },
  { key: "queries", label: "Queries" },
  { key: "external", label: "External" },
  { key: "runtime", label: "Runtime" },
];
/** What an agent harness reports is runs and model calls, so its page is built from those. */
const HARNESS_TABS: TabDescriptor<TabKey>[] = [
  { key: "overview", label: "Overview" },
  { key: "interactions", label: "Interactions" },
  { key: "models", label: "Models" },
  { key: "tools", label: "Tools" },
];
const CONTAINER_TAB: TabDescriptor<TabKey> = { key: "container", label: "Container" };
const DEPLOYS_TAB: TabDescriptor<TabKey> = { key: "deploys", label: "Deploys" };

/**
 * The sections an app has something to show in: what its agent reported,
 * what fog says of its container, or — for an image with no agent — only
 * the latter.
 */
function tabsFor(app: App): TabDescriptor<TabKey>[] {
  if (containerOnly(app)) return [CONTAINER_TAB, DEPLOYS_TAB];
  const agent = isHarness(app) ? harnessTabs(app) : AGENT_TABS;
  return app.fog ? [...agent, CONTAINER_TAB, DEPLOYS_TAB] : [...agent, DEPLOYS_TAB];
}

/** An app whose units of work are an agent's runs. */
const isHarness = (app: App): boolean => app.kinds.includes("run");

/** A harness's own sections, then whichever of an app's usual ones it has anything to show in. */
function harnessTabs(app: App): TabDescriptor<TabKey>[] {
  const usual = AGENT_TABS.filter((tab) => (tab.key === "endpoints" && app.kinds.includes("request")) || (tab.key === "jobs" && app.kinds.includes("job")) || tab.key === "external" || tab.key === "runtime");
  return [...HARNESS_TABS, ...usual];
}

/**
 * One app, auto-built from what it reported: no configuration. The
 * endpoint list is ranked by total time consumed (AppSignal's lesson), and
 * every number leads to the rows behind it.
 */
export function AppShow() {
  const { slug = "", tab, name, job, session } = useParams();
  const navigate = useScopedNavigate();
  const apps = useApps();
  const app = apps.data?.find((candidate) => candidate.slug === slug);

  if (apps.isPending) return <LoadingState />;
  if (apps.isError) return <ErrorState message="Couldn't load the apps." onRetry={() => void apps.refetch()} />;
  if (!app) return <EmptyState title="No such app" description={`Nothing is called “${slug}”.`} action={<ScopedLink to="/apps" className="text-primary underline">All apps</ScopedLink>} />;

  const tabs = tabsFor(app);
  const bare = containerOnly(app);
  const active: TabKey = tabs.some((entry) => entry.key === tab) ? (tab as TabKey) : name && !bare ? "endpoints" : job && !bare ? "jobs" : session && isHarness(app) ? "interactions" : tabs[0].key;

  return (
    <div>
      <header className={cn(PAGE_X, "flex flex-wrap items-center gap-3 border-b border-border py-3")}>
        <AppDot app={app} live={app.reporting} className="h-2.5 w-2.5" />
        <h1 className="text-lg font-semibold text-foreground">{app.name}</h1>
        {bare ? null : <span className="font-mono text-xs text-muted">{shortSha(app.release)}</span>}
        {app.fog ? (
          <Badge tone={app.fog.healthy === false ? "danger" : app.fog.state === "running" ? "neutral" : "warning"} title="what fog says">
            fog: {app.fog.state ?? "?"}
            {app.fog.rev ? ` · rev ${app.fog.rev}` : ""}
            {app.fog.healthy === false ? " · unhealthy" : ""}
          </Badge>
        ) : null}
        {app.reporting ? (
          <Badge tone="success">{app.live_processes} live</Badge>
        ) : bare ? (
          <Badge title="Nothing has reported for this app — what is shown is what fog says of its container">no agent</Badge>
        ) : (
          <Badge tone="warning" title={app.last_seen_at ? `last report ${formatAgo(app.last_seen_at)}` : "never reported"}>
            silent
          </Badge>
        )}
        <div className={cn("ml-auto flex items-center gap-1 text-xs", bare && "hidden")}>
          <ScopedLink to={`/profiles?app=${app.slug}`} className="flex items-center gap-1 rounded-[var(--radius-control)] px-2 py-1 text-muted hover:bg-surface-raised hover:text-foreground">
            <Flame className="h-3.5 w-3.5" aria-hidden /> Profiles
          </ScopedLink>
          <ScopedLink to={`/logs?app=${app.slug}`} className="flex items-center gap-1 rounded-[var(--radius-control)] px-2 py-1 text-muted hover:bg-surface-raised hover:text-foreground">
            <ScrollText className="h-3.5 w-3.5" aria-hidden /> Logs
          </ScopedLink>
          <ScopedLink to={`/traces?app=${app.slug}`} className="flex items-center gap-1 rounded-[var(--radius-control)] px-2 py-1 text-muted hover:bg-surface-raised hover:text-foreground">
            <Waypoints className="h-3.5 w-3.5" aria-hidden /> Traces
          </ScopedLink>
        </div>
        <div className="w-full">
          <Tabs tabs={tabs} active={active} onChange={(next) => navigate(next === tabs[0].key ? `/apps/${app.slug}` : `/apps/${app.slug}/${next}`)} label="App sections" />
        </div>
      </header>
      <PageBody className="py-4">
        {active === "overview" ? isHarness(app) ? <HarnessOverview app={app} /> : <OverviewTab app={app} /> : null}
        {active === "interactions" ? <InteractionsTab app={app} /> : null}
        {active === "models" ? <ModelsTab app={app} /> : null}
        {active === "tools" ? <ToolsTab app={app} /> : null}
        {active === "endpoints" ? <TransactionsTab app={app} kind="request" /> : null}
        {active === "jobs" ? <TransactionsTab app={app} kind="job" /> : null}
        {active === "queries" ? <SpansTab app={app} kind="sql" /> : null}
        {active === "external" ? <SpansTab app={app} kind="http" /> : null}
        {active === "runtime" ? <RuntimeTab app={app} /> : null}
        {active === "container" ? <ContainerTab app={app} /> : null}
        {active === "deploys" ? <DeploysTab app={app} /> : null}
      </PageBody>
      {name && !bare ? <EndpointSheet app={app} kind="request" name={decodeURIComponent(name)} onClose={() => navigate(`/apps/${app.slug}/endpoints`)} /> : null}
      {job && !bare ? <EndpointSheet app={app} kind="job" name={decodeURIComponent(job)} onClose={() => navigate(`/apps/${app.slug}/jobs`)} /> : null}
      {session ? <SessionSheet app={app} session={decodeURIComponent(session)} onClose={() => navigate(`/apps/${app.slug}/interactions`)} /> : null}
    </div>
  );
}
