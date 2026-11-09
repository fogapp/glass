import { useParams } from "react-router-dom";
import { PageBody } from "@/components/layout/PageBody";
import { PAGE_X } from "@/components/layout/pageLayout";
import { cn } from "@/lib/cn";
import { Tabs } from "@/components/ui/Tabs";
import { useScopedNavigate } from "@/lib/scopeHref";
import { OverviewTab } from "@/pages/visitors/Overview";
import { PagesTab } from "@/pages/visitors/Pages";
import { InteractionsTab } from "@/pages/visitors/Interactions";
import { JourneysTab } from "@/pages/visitors/Journeys";
import { VitalsTab } from "@/pages/visitors/Vitals";
import { LiveTab } from "@/pages/visitors/Live";
import { VisitSheet } from "@/pages/visitors/VisitSheet";

const TABS = [
  { key: "overview", label: "Overview" },
  { key: "pages", label: "Pages" },
  { key: "interactions", label: "Interactions" },
  { key: "journeys", label: "Journeys" },
  { key: "vitals", label: "Vitals" },
  { key: "live", label: "Live" },
] as const;
type TabKey = (typeof TABS)[number]["key"];

/**
 * How the household actually uses the apps: visitors and
 * visits, the pages they see, what they click, the paths they take, how
 * fast pages feel, and who is on right now — each visit openable as a
 * timeline.
 */
export function Visitors() {
  const { tab, visit } = useParams();
  const go = useScopedNavigate();
  const active: TabKey = TABS.some((entry) => entry.key === tab) ? (tab as TabKey) : "overview";
  return (
    <div>
      <div className={cn("border-b border-border", PAGE_X)}>
        <Tabs tabs={TABS} active={active} onChange={(next) => go(next === "overview" ? "/visitors" : `/visitors/${next}`)} label="Visitor sections" />
      </div>
      <PageBody className="py-4">
        {active === "overview" ? <OverviewTab /> : null}
        {active === "pages" ? <PagesTab /> : null}
        {active === "interactions" ? <InteractionsTab /> : null}
        {active === "journeys" ? <JourneysTab /> : null}
        {active === "vitals" ? <VitalsTab /> : null}
        {active === "live" ? <LiveTab /> : null}
      </PageBody>
      {visit ? <VisitSheet visit={visit} onClose={() => go(active === "overview" ? "/visitors" : `/visitors/${active}`)} /> : null}
    </div>
  );
}
