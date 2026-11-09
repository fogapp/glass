import { type FormEvent } from "react";
import { api } from "@/api/client";
import { useDraft } from "@/hooks/useDraft";
import { useFormMutation } from "@/hooks/useFormMutation";
import { useTestConnection } from "@/hooks/useTestConnection";
import { keys } from "@/lib/queryKeys";
import { relativeTime } from "@/lib/time";
import { Button } from "@/components/ui/Button";
import { FormError, FormFooter } from "@/components/ui/Form";
import { Input } from "@/components/ui/Input";
import { QueryState } from "@/components/ui/PageState";
import { SectionHeader } from "@/components/ui/SectionHeader";
import { Toggle } from "@/components/ui/Toggle";
import { TestButton } from "@/components/settings/TestButton";
import { TestResultLine } from "@/components/settings/TestResultLine";
import { useSettings } from "@/components/settings/Notifications";
import type { Settings } from "@/types";

/**
 * Settings › Fog: fog's URL and an MCP token, and Glass
 * reads the roster, container vitals, health and deploys every minute —
 * with no change to fog.
 */
export function FogSettings() {
  const settings = useSettings();
  return (
    <QueryState query={settings} errorMessage="Couldn't load settings.">
      {(data) => (
        <div className="max-w-xl space-y-8">
          <FogForm settings={data} />
          <IgnoredApps names={data.fog.ignored_apps} />
        </div>
      )}
    </QueryState>
  );
}

function FogForm({ settings }: { settings: Settings }) {
  const { draft, set } = useDraft({ fog_url: settings.fog.url ?? "", fog_token: "", fog_sync_enabled: settings.fog.sync_enabled });
  const save = useFormMutation<Settings, void>({
    mutationFn: () => api.patch<Settings>("/app_setting", { fog_url: draft.fog_url.trim(), fog_token: draft.fog_token || undefined, fog_sync_enabled: draft.fog_sync_enabled }),
    meta: { invalidates: [keys.settings.all] },
    fallback: "Couldn't save.",
  });
  const test = useTestConnection("/app_setting/test_fog", [keys.settings.all, keys.apps.all]);
  const submit = (event: FormEvent) => {
    event.preventDefault();
    save.mutate();
  };
  return (
    <form onSubmit={submit} className="space-y-4">
      <SectionHeader
        title="Fog"
        description="Paste a fog MCP token (fog › Settings › AI access) and Glass reads what fog knows: every app it manages, container CPU, memory, network and disk for each — including third-party images with no agent — health transitions and deploys, as markers on every chart."
      />
      <Input label="fog URL" hint="From a container on the fog network: http://host.docker.internal:8080" value={draft.fog_url} onChange={(event) => set("fog_url", event.target.value)} placeholder="http://host.docker.internal:8080" />
      <Input
        label="MCP token"
        hint={settings.fog.token_set ? "A token is stored. Leave blank to keep it." : "Read-only in fog; Glass uses only read tools."}
        type="password"
        value={draft.fog_token}
        onChange={(event) => set("fog_token", event.target.value)}
        autoComplete="off"
      />
      <Toggle label="Sync every minute" checked={draft.fog_sync_enabled} onChange={(checked) => set("fog_sync_enabled", checked)} />
      <FormError message={save.errorMessage} />
      <div className="flex items-center gap-2">
        <FormFooter label="Save" pending={save.isPending} />
        <TestButton connection={test} disabled={!settings.fog.url || !settings.fog.token_set} />
      </div>
      <TestResultLine ok={test.result?.ok ?? settings.fog.last_test_ok} message={test.result?.message ?? settings.fog.last_test_message} at={test.result ? null : settings.fog.last_tested_at} />
      <p className="text-xs text-muted">
        {settings.fog.last_synced_at ? `Last synced ${relativeTime(settings.fog.last_synced_at)}.` : "Never synced."}
        {settings.fog.last_error ? <span className="text-negative"> Last error: {settings.fog.last_error}</span> : null}
      </p>
    </form>
  );
}

/**
 * The fog apps removed in Settings › Apps. Fog still runs them, so Glass
 * remembers the removal instead of making them again every minute; this is
 * where one is taken back.
 */
function IgnoredApps({ names }: { names: string[] }) {
  const follow = useFormMutation<Settings, string>({
    mutationFn: (name) => api.patch<Settings>("/app_setting", { fog_ignored_apps: names.filter((other) => other !== name) }),
    meta: { invalidates: [keys.settings.all, keys.apps.all] },
    fallback: "Couldn't follow it again.",
  });
  if (names.length === 0) return null;
  return (
    <section className="space-y-2">
      <SectionHeader title="Removed from Glass" description="Fog still runs these, but you removed them in Settings › Apps, so the sync leaves them alone: no app, no container vitals, no markers." />
      <ul className="divide-y divide-border rounded-[var(--radius-card)] border border-border">
        {names.map((name) => (
          <li key={name} className="flex items-center gap-2 px-3 py-1.5 text-sm">
            <span className="min-w-0 truncate font-mono text-foreground">{name}</span>
            <Button className="ml-auto shrink-0" variant="ghost" size="sm" disabled={follow.isPending} onClick={() => follow.mutate(name)}>
              Follow again
            </Button>
          </li>
        ))}
      </ul>
      <FormError message={follow.errorMessage} />
    </section>
  );
}
