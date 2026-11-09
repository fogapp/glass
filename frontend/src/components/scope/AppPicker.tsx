import { useApps } from "@/hooks/useApps";
import { useScope } from "@/lib/scope";
import { AppDot } from "@/components/scope/AppDot";

/** The scope bar's app selector: the whole fleet, or one app. */
export function AppPicker() {
  const scope = useScope();
  const apps = useApps();
  return (
    <div className="flex items-center gap-1">
      <span className="pl-1.5" aria-hidden>
        {scope.app ? <AppDot app={apps.data?.find((app) => app.slug === scope.app)} /> : <span className="inline-block h-2 w-2 rounded-full bg-muted" />}
      </span>
      <select
        aria-label="App"
        value={scope.app ?? ""}
        onChange={(event) => scope.setApp(event.target.value || null)}
        className="h-8 rounded-[var(--radius-control)] border border-border bg-input pl-2 pr-7 text-sm text-foreground"
      >
        <option value="">All apps</option>
        {(apps.data ?? []).map((app) => (
          <option key={app.slug} value={app.slug}>
            {app.name}
            {app.reporting ? "" : " · silent"}
          </option>
        ))}
      </select>
    </div>
  );
}
