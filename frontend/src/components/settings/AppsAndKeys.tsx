import { useState, type FormEvent } from "react";
import { useMutation, useQuery } from "@tanstack/react-query";
import { useApps } from "@/hooks/useApps";
import { api } from "@/api/client";
import { useAuth } from "@/hooks/useAuth";
import { useDraft } from "@/hooks/useDraft";
import { useFormMutation } from "@/hooks/useFormMutation";
import { keys } from "@/lib/queryKeys";
import { relativeTime } from "@/lib/time";
import { formatAgo } from "@/lib/format";
import { AppDot } from "@/components/scope/AppDot";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { CodeBlock } from "@/components/ui/CodeBlock";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { FormError, FormFooter } from "@/components/ui/Form";
import { Input } from "@/components/ui/Input";
import { QueryState } from "@/components/ui/PageState";
import { ResourceSection } from "@/components/ui/ResourceSection";
import { RevealedSecret } from "@/components/ui/RevealedSecret";
import { SectionHeader } from "@/components/ui/SectionHeader";
import { Select } from "@/components/ui/Select";
import { Toggle } from "@/components/ui/Toggle";
import { IDENTITY_MODES, LOG_LEVELS, type App, type AppCreated, type IdentityMode, type IngestKey, type IngestKeyCreated, type LogLevel } from "@/types";

const IDENTITY_LABELS: Record<IdentityMode, string> = {
  anonymous: "Anonymous — a daily-rotating hash; the same person cannot be followed across days",
  pseudonymous: "Pseudonymous — a stable hash; return visits are knowable, who is not (default)",
  named: "Named — the app's user name; it is your household",
};

/**
 * Settings › Apps: the things that report, and the two values each needs.
 * Creating an app reveals its key once, beside the manifest lines that use
 * it — the whole of setup is copying those.
 */
export function AppsAndKeys() {
  const { user } = useAuth();
  const admin = user?.role === "admin";
  const apps = useApps();
  const [revealed, setRevealed] = useState<{ app: App; token: string; keyName: string } | null>(null);

  return (
    <div className="space-y-8">
      <ResourceSection
        title="Apps"
        description="Each app reports with its own key. An app needs GLASS_URL and GLASS_API_KEY, and nothing else."
        addLabel="Add app"
        query={apps}
        errorMessage="Couldn't load the apps."
        empty={{ title: "No apps yet", description: "Add the first one to get its ingest key.", offerAdd: admin }}
        above={
          revealed ? (
            <RevealedSecret
              name={`${revealed.app.name} · ${revealed.keyName}`}
              heading="Copy this key now — it is shown once."
              secret={revealed.token}
              onDismiss={() => setRevealed(null)}
            >
              <ManifestSnippet token={revealed.token} />
            </RevealedSecret>
          ) : null
        }
        form={(close) =>
          admin ? (
            <NewAppForm
              onCreated={(created) => {
                setRevealed({ app: created, token: created.ingest_key, keyName: "default" });
                close();
              }}
              onCancel={close}
            />
          ) : (
            <p className="text-sm text-muted">Only an admin can add apps.</p>
          )
        }
      >
        {(rows) => rows.map((app) => <AppRow key={app.id} app={app} admin={admin} onRevealed={(token, keyName) => setRevealed({ app, token, keyName })} />)}
      </ResourceSection>
    </div>
  );
}

function ManifestSnippet({ token }: { token: string }) {
  // On the fog network every app reaches Glass by its name.
  const url = "http://glass";
  return (
    <div className="space-y-2 text-sm">
      <p className="text-muted">In the app's fog manifest, or its environment:</p>
      <CodeBlock copyable value={`env:\n  GLASS_URL: ${url}\nsecrets:\n  - GLASS_API_KEY   # ${token}`} />
      <p className="text-muted">
        And in its Gemfile, after <span className="font-mono">gem "rails"</span>: <span className="font-mono">gem "glass", path: "vendor/gems/glass"</span>. Requests, SQL, jobs, the
        runtime, profiles and logs report from the next boot.
      </p>
    </div>
  );
}

function NewAppForm({ onCreated, onCancel }: { onCreated: (created: AppCreated) => void; onCancel: () => void }) {
  const { draft, set } = useDraft({ name: "", slug: "" });
  const create = useFormMutation<AppCreated, void>({
    mutationFn: () => api.post<AppCreated>("/apps", { name: draft.name.trim(), slug: draft.slug.trim() || undefined }),
    meta: { invalidates: [keys.apps.all] },
    onSuccess: onCreated,
    fallback: "Couldn't add the app.",
  });
  const submit = (event: FormEvent) => {
    event.preventDefault();
    create.mutate();
  };
  return (
    <form onSubmit={submit} className="space-y-3">
      <div className="grid gap-3 sm:grid-cols-2">
        <Input label="Name" value={draft.name} onChange={(event) => set("name", event.target.value)} placeholder="Hook" required autoFocus />
        <Input label="Slug" hint="Lowercase; how the query bar names it (app:hook). Defaults from the name." value={draft.slug} onChange={(event) => set("slug", event.target.value)} placeholder="hook" />
      </div>
      <FormError message={create.errorMessage} />
      <FormFooter label="Add app and mint a key" pending={create.isPending} disabled={draft.name.trim() === ""} onCancel={onCancel} />
    </form>
  );
}

function AppRow({ app, admin, onRevealed }: { app: App; admin: boolean; onRevealed: (token: string, keyName: string) => void }) {
  const [open, setOpen] = useState(false);
  const remove = useMutation({
    mutationFn: () => api.delete(`/apps/${app.id}`),
    // Removing an app fog runs also adds it to Settings › Fog's removed list.
    meta: { invalidates: [keys.apps.all, keys.settings.all] },
  });
  // Fog goes on running it; say that removing here stops Glass following it.
  const question = app.fog_name
    ? `Remove ${app.name}? Its keys stop working, what it reported ages out, and Glass stops following it in fog (Settings › Fog brings it back).`
    : `Remove ${app.name}? Its keys stop working; what it reported ages out.`;
  return (
    <div className="border-b border-border py-3 last:border-b-0">
      <div className="flex flex-wrap items-center gap-3">
        <AppDot app={app} live={app.reporting} className="h-2.5 w-2.5" />
        <span className="font-medium text-foreground">{app.name}</span>
        <span className="font-mono text-xs text-muted">app:{app.slug}</span>
        {app.reporting ? <Badge tone="success">reporting</Badge> : <Badge tone="warning">{app.last_seen_at ? `silent since ${formatAgo(app.last_seen_at)}` : "never reported"}</Badge>}
        <span className="ml-auto flex items-center gap-2">
          <Button variant="ghost" size="sm" onClick={() => setOpen((value) => !value)} aria-expanded={open}>
            {open ? "Hide" : "Keys & settings"}
          </Button>
          {admin ? (
            <ConfirmButton question={question} onConfirm={() => remove.mutate()} variant="ghost" size="sm" disabled={remove.isPending}>
              Remove
            </ConfirmButton>
          ) : null}
        </span>
      </div>
      {open ? (
        <div className="mt-3 grid gap-6 lg:grid-cols-2">
          <IngestKeys app={app} admin={admin} onRevealed={onRevealed} />
          <AgentSettingsForm app={app} admin={admin} />
        </div>
      ) : null}
    </div>
  );
}

function IngestKeys({ app, admin, onRevealed }: { app: App; admin: boolean; onRevealed: (token: string, keyName: string) => void }) {
  const list = useQuery({ queryKey: keys.apps.keys(app.id), queryFn: () => api.get<IngestKey[]>(`/apps/${app.id}/ingest_keys`) });
  const [name, setName] = useState("");
  const create = useFormMutation<IngestKeyCreated, void>({
    mutationFn: () => api.post<IngestKeyCreated>(`/apps/${app.id}/ingest_keys`, { name: name.trim() || "key" }),
    meta: { invalidates: [keys.apps.keys(app.id)] },
    onSuccess: (created) => {
      onRevealed(created.token, created.name);
      setName("");
    },
    fallback: "Couldn't mint a key.",
  });
  const revoke = useMutation({
    mutationFn: (id: string) => api.delete(`/apps/${app.id}/ingest_keys/${id}`),
    meta: { invalidates: [keys.apps.keys(app.id)] },
  });
  return (
    <section className="space-y-2">
      <SectionHeader title="Ingest keys" description="Write-only: a key can report for this app and read nothing." />
      <QueryState query={list} errorMessage="Couldn't load the keys." empty={<p className="text-xs text-muted">No keys — mint one below.</p>} isEmpty={(rows) => rows.length === 0}>
        {(rows) => (
          <ul className="divide-y divide-border rounded-[var(--radius-card)] border border-border">
            {rows.map((key) => (
              <li key={key.id} className="flex flex-wrap items-center gap-2 px-3 py-1.5 text-sm">
                <span className="text-foreground">{key.name}</span>
                <span className="font-mono text-xs text-muted">{key.prefix}…</span>
                <span className="text-xs text-muted">{key.last_used_at ? `used ${relativeTime(key.last_used_at)}` : "never used"}</span>
                {key.revoked ? <Badge tone="danger">revoked</Badge> : null}
                {admin && !key.revoked ? (
                  <ConfirmButton question="Revoke this key? The app stops reporting until it gets a new one." onConfirm={() => revoke.mutate(key.id)} variant="ghost" size="sm" disabled={revoke.isPending}>
                    Revoke
                  </ConfirmButton>
                ) : null}
              </li>
            ))}
          </ul>
        )}
      </QueryState>
      {admin ? (
        <form
          onSubmit={(event) => {
            event.preventDefault();
            create.mutate();
          }}
          className="flex items-end gap-2"
        >
          <Input label="New key" value={name} onChange={(event) => setName(event.target.value)} placeholder="production" className="flex-1" />
          <Button type="submit" size="sm" disabled={create.isPending}>
            Mint
          </Button>
        </form>
      ) : null}
      <FormError message={create.errorMessage} />
    </section>
  );
}

function AgentSettingsForm({ app, admin }: { app: App; admin: boolean }) {
  const { draft, set } = useDraft({ identity_mode: app.identity_mode, link_template: app.link_template ?? "", ...app.agent_settings });
  const save = useFormMutation<App, void>({
    mutationFn: () =>
      api.patch<App>(`/apps/${app.id}`, {
        identity_mode: draft.identity_mode,
        link_template: draft.link_template,
        agent_settings: {
          trace_sample_rate: draft.trace_sample_rate,
          profiling: draft.profiling,
          profile_hz: draft.profile_hz,
          log_level: draft.log_level,
          browser: draft.browser,
        },
      }),
    meta: { invalidates: [keys.apps.all] },
    fallback: "Couldn't save.",
  });
  return (
    <form
      onSubmit={(event) => {
        event.preventDefault();
        save.mutate();
      }}
      className="space-y-3"
    >
      <SectionHeader title="Agent settings" description="Delivered to every process of this app on its next flush — no redeploy." />
      <Select label="Visitor identity" value={draft.identity_mode} onChange={(event) => set("identity_mode", event.target.value as IdentityMode)} disabled={!admin}>
        {IDENTITY_MODES.map((mode) => (
          <option key={mode} value={mode}>
            {IDENTITY_LABELS[mode]}
          </option>
        ))}
      </Select>
      <div className="grid gap-3 sm:grid-cols-2">
        <Input
          label="Trace sample rate"
          hint="Share of ordinary traces whose spans are kept. Errors, slow outliers and first sightings are always kept."
          type="number"
          min={0}
          max={1}
          step={0.05}
          value={draft.trace_sample_rate}
          onChange={(event) => set("trace_sample_rate", Number(event.target.value))}
          disabled={!admin}
        />
        <Input label="Profile rate (Hz)" type="number" min={10} max={1000} value={draft.profile_hz} onChange={(event) => set("profile_hz", Number(event.target.value))} disabled={!admin} />
        <Select label="Ship logs at or above" value={draft.log_level} onChange={(event) => set("log_level", event.target.value as LogLevel)} disabled={!admin}>
          {LOG_LEVELS.map((level) => (
            <option key={level} value={level}>
              {level}
            </option>
          ))}
        </Select>
      </div>
      <Input
        label="Link into the app's own console"
        hint="For what Glass is never sent — what a run said, what a tool was given. {run}, {session}, {trace} and any attribute a row carries are filled in: https://assistant.example.net/traces/{run}"
        placeholder="https://…/{run}"
        value={draft.link_template}
        onChange={(event) => set("link_template", event.target.value)}
        disabled={!admin}
      />
      <div className="flex flex-wrap gap-6">
        <Toggle label="Continuous profiling" checked={draft.profiling} onChange={(checked) => set("profiling", checked)} disabled={!admin} />
        <Toggle label="Browser analytics (inject glass.js)" checked={draft.browser} onChange={(checked) => set("browser", checked)} disabled={!admin} />
      </div>
      <FormError message={save.errorMessage} />
      {admin ? <FormFooter label={save.isSuccess ? "Saved" : "Save"} pending={save.isPending} /> : null}
    </form>
  );
}
