import { NavLink, useParams } from "react-router-dom";
import { cn } from "@/lib/cn";
import { PageBody } from "@/components/layout/PageBody";
import { About } from "@/components/settings/About";
import { ApiTokens } from "@/components/settings/ApiTokens";
import { AppsAndKeys } from "@/components/settings/AppsAndKeys";
import { BackgroundJobs } from "@/components/settings/BackgroundJobs";
import { Notifications } from "@/components/settings/Notifications";
import { FogSettings } from "@/components/settings/FogSettings";
import { Passkeys } from "@/components/settings/Passkeys";
import { Retention } from "@/components/settings/Retention";
import { Users } from "@/components/settings/Users";

const SECTIONS = [
  { key: "apps", label: "Apps & keys" },
  { key: "fog", label: "Fog" },
  { key: "notifications", label: "Notifications" },
  { key: "retention", label: "Retention & storage" },
  { key: "people", label: "People" },
  { key: "tokens", label: "API tokens" },
  { key: "passkeys", label: "Passkeys" },
  { key: "jobs", label: "Background jobs" },
  { key: "about", label: "About" },
] as const;
type SectionKey = (typeof SECTIONS)[number]["key"];

export function Settings() {
  const { section } = useParams();
  const active: SectionKey = SECTIONS.some((entry) => entry.key === section) ? (section as SectionKey) : "apps";
  return (
    <div className="flex min-h-full">
      <nav aria-label="Settings sections" className="hidden w-52 shrink-0 border-r border-border bg-surface/50 p-3 md:block">
        {SECTIONS.map((entry) => (
          <NavLink
            key={entry.key}
            to={entry.key === "apps" ? "/settings" : `/settings/${entry.key}`}
            end
            className={({ isActive }) =>
              cn("block rounded-[var(--radius-control)] px-2.5 py-1.5 text-sm", isActive || (entry.key === "apps" && active === "apps") ? "bg-primary/10 text-primary" : "text-muted hover:bg-surface-raised hover:text-foreground")
            }
          >
            {entry.label}
          </NavLink>
        ))}
      </nav>
      <PageBody className="min-w-0 flex-1 space-y-6 py-4">
        <div className="flex gap-2 overflow-x-auto scrollbar-none md:hidden">
          {SECTIONS.map((entry) => (
            <NavLink key={entry.key} to={entry.key === "apps" ? "/settings" : `/settings/${entry.key}`} end className={({ isActive }) => cn("whitespace-nowrap rounded-full border px-3 py-1 text-xs", isActive ? "border-primary/40 bg-primary/10 text-primary" : "border-border text-muted")}>
              {entry.label}
            </NavLink>
          ))}
        </div>
        {active === "apps" ? <AppsAndKeys /> : null}
        {active === "fog" ? <FogSettings /> : null}
        {active === "notifications" ? <Notifications /> : null}
        {active === "retention" ? <Retention /> : null}
        {active === "people" ? <Users /> : null}
        {active === "tokens" ? <ApiTokens /> : null}
        {active === "passkeys" ? <Passkeys /> : null}
        {active === "jobs" ? <BackgroundJobs /> : null}
        {active === "about" ? <About /> : null}
      </PageBody>
    </div>
  );
}
