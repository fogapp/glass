import { Fragment, useState, type FormEvent } from "react";
import { useMutation, useQuery } from "@tanstack/react-query";
import { api } from "@/api/client";
import { useDraft } from "@/hooks/useDraft";
import { useFormMutation } from "@/hooks/useFormMutation";
import { keys } from "@/lib/queryKeys";
import { relativeTime } from "@/lib/time";
import {
  API_TOKEN_SCOPE_HINTS,
  API_TOKEN_SCOPE_LABELS,
  MCP_TOOL_SUMMARIES,
  claudeCodeAddCommand,
  claudeCodeProjectConfig,
  mcpConfigSnippet,
  mcpUrl,
} from "@/lib/tokens";
import { Badge } from "@/components/ui/Badge";
import { CodeBlock } from "@/components/ui/CodeBlock";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { FormError, FormFooter } from "@/components/ui/Form";
import { Input } from "@/components/ui/Input";
import { ResourceRow, ResourceSection } from "@/components/ui/ResourceSection";
import { SectionHeader } from "@/components/ui/SectionHeader";
import { Select } from "@/components/ui/Select";
import { API_TOKEN_SCOPES, MCP_TOOLS, type ApiToken, type ApiTokenCreated, type ApiTokenScope } from "@/types";
import { RevealedSecret } from "@/components/ui/RevealedSecret";

/**
 * Long-lived credentials for integrations and MCP clients. The plaintext is
 * shown exactly once, on creation; afterwards only its prefix identifies it.
 */
export function ApiTokens() {
  const [revealed, setRevealed] = useState<ApiTokenCreated | null>(null);
  const list = useQuery({
    queryKey: keys.apiTokens.list(),
    queryFn: () => api.get<ApiToken[]>("/api_tokens"),
  });
  const origin = typeof window === "undefined" ? "" : window.location.origin;

  return (
    <div className="space-y-10">
      <ResourceSection
        title="API tokens"
        description="Long-lived credentials for your own tools, MCP clients, and a friend's Glass. Each one carries your access; revoking it is one click."
        addLabel="New token"
        above={revealed ? <RevealedSecret name={revealed.name} secret={revealed.token} onDismiss={() => setRevealed(null)} /> : null}
        form={(close) => (
          <TokenForm
            onCreated={(created) => {
              setRevealed(created);
              close();
            }}
            onCancel={close}
          />
        )}
        query={list}
        errorMessage="Could not load tokens."
        empty={{ title: "No tokens yet", description: "Create one to connect an MCP client or another app to Glass." }}
      >
        {(tokens) => tokens.map((token) => <TokenRow key={token.id} token={token} />)}
      </ResourceSection>

      <section className="space-y-4">
        <SectionHeader
          title="MCP"
          description="Any MCP client — Claude, or anything that speaks the protocol — can read Glass with a token. Every tool only looks, so a read-only token is all an agent needs."
        />
        <div className="space-y-3 text-sm text-foreground">
          <p>
            Connect to <span className="font-mono">{mcpUrl(origin)}</span> and send{" "}
            <span className="font-mono">Authorization: Bearer &lt;token&gt;</span> on every request. Streamable HTTP, JSON mode, no sessions.
          </p>
          <ul className="grid gap-x-6 gap-y-2 md:grid-cols-2">
            {MCP_TOOLS.map((tool) => (
              <li key={tool}>
                <span className="font-mono text-foreground">{tool}</span>
                <span className="block text-xs text-muted">{MCP_TOOL_SUMMARIES[tool]}</span>
              </li>
            ))}
          </ul>
          <p className="text-xs text-muted">A generic client entry — swap in your token:</p>
          <CodeBlock value={mcpConfigSnippet(origin, revealed?.token ?? "glass_…")} />
        </div>
      </section>

      <section className="space-y-4">
        <SectionHeader
          title="Claude Code"
          description="Register Glass once and any Claude Code session can answer “why was hook slow at 3 am?” from the data."
        />
        <ol className="list-decimal space-y-4 pl-5 text-sm text-foreground marker:text-muted">
          <li>
            Create a <span className="font-medium">Read-only</span> token above.
          </li>
          <li className="space-y-2">
            <p>
              {revealed ? `Run this in a terminal — it already carries “${revealed.name}”:` : "Run this in a terminal, with your token in place of glass_…:"}
            </p>
            <CodeBlock copyable value={claudeCodeAddCommand(origin, revealed?.token ?? "glass_…")} />
            <p className="text-xs text-muted">
              <span className="font-mono">--scope user</span> makes Glass available in every project. Drop it to register Glass for the
              current directory only.
            </p>
          </li>
          <li>
            Start Claude Code and run <span className="font-mono">/mcp</span> — <span className="font-mono">glass</span> should be
            connected. Then just ask: “which endpoints is hook spending its time in today?”
          </li>
        </ol>
        <div className="space-y-2 text-sm text-foreground">
          <p className="text-xs text-muted">
            To share Glass with everyone working in a repository, commit a <span className="font-mono">.mcp.json</span> instead. Each
            person exports <span className="font-mono">GLASS_TOKEN</span>, so no token lands in git:
          </p>
          <CodeBlock copyable value={claudeCodeProjectConfig(origin)} />
        </div>
      </section>
    </div>
  );
}

function TokenRow({ token }: { token: ApiToken }) {
  const revoke = useMutation({
    mutationFn: () => api.delete(`/api_tokens/${token.id}`),
    meta: { invalidates: [keys.apiTokens.all] },
  });
  return (
    <ResourceRow
      spacing="sm"
      name={token.name}
      badges={
        <>
          <Badge tone={token.scope === "read" ? "info" : "neutral"}>{API_TOKEN_SCOPE_LABELS[token.scope]}</Badge>
          {token.expired ? <Badge tone="danger">expired</Badge> : null}
        </>
      }
      meta={[
        <span key="prefix" className="font-mono">{token.prefix}…</span>,
        <Fragment key="use">
          {token.last_used_at ? `Last used ${relativeTime(token.last_used_at)}` : "Never used"}
          {token.expires_at ? ` · expires ${new Date(token.expires_at).toLocaleDateString()}` : " · no expiry"}
          {` · created ${relativeTime(token.created_at)}`}
        </Fragment>,
      ]}
      actions={
        <ConfirmButton question="Revoke this token? Anything using it stops working." onConfirm={() => revoke.mutate()} disabled={revoke.isPending}>
          Revoke
        </ConfirmButton>
      }
    />
  );
}

function TokenForm({ onCreated, onCancel }: { onCreated: (created: ApiTokenCreated) => void; onCancel: () => void }) {
  const { draft, set } = useDraft<{ name: string; days: string; scope: ApiTokenScope }>({ name: "", days: "", scope: "full" });
  const create = useFormMutation({
    mutationFn: () =>
      api.post<ApiTokenCreated>("/api_tokens", {
        name: draft.name,
        scope: draft.scope,
        expires_in_days: draft.days === "" ? undefined : Number(draft.days),
      }),
    meta: { invalidates: [keys.apiTokens.all] },
    onSuccess: onCreated,
    fallback: "Could not create the token",
  });

  function onSubmit(event: FormEvent) {
    event.preventDefault();
    create.mutate();
  }

  return (
    <form onSubmit={onSubmit} className="space-y-4">
      <div className="grid gap-4 md:grid-cols-3">
        <Input label="Name" name="token_name" placeholder="Claude on the laptop" value={draft.name} onChange={(e) => set("name", e.target.value)} required />
        <Input label="Expires in (days)" name="expires_in_days" type="number" min={1} max={3650} value={draft.days} onChange={(e) => set("days", e.target.value)} hint="Leave blank for no expiry." />
        <Select label="Scope" name="scope" value={draft.scope} onChange={(e) => set("scope", e.target.value as ApiTokenScope)} hint={API_TOKEN_SCOPE_HINTS[draft.scope]}>
          {API_TOKEN_SCOPES.map((option) => (
            <option key={option} value={option}>
              {API_TOKEN_SCOPE_LABELS[option]}
            </option>
          ))}
        </Select>
      </div>
      <FormError message={create.errorMessage} />
      <FormFooter label="Create token" pendingLabel="Creating…" pending={create.isPending} disabled={draft.name.trim() === ""} onCancel={onCancel} />
    </form>
  );
}
