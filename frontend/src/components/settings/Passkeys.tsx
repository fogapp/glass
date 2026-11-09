import { useState, type FormEvent } from "react";
import { useMutation, useQuery } from "@tanstack/react-query";
import { KeyRound } from "lucide-react";
import { api } from "@/api/client";
import { useFormMutation } from "@/hooks/useFormMutation";
import { keys } from "@/lib/queryKeys";
import { passkeyErrorMessage, passkeysSupported, registerPasskey } from "@/lib/passkeys";
import { relativeTime } from "@/lib/time";
import { Button } from "@/components/ui/Button";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { FormError } from "@/components/ui/Form";
import { Input } from "@/components/ui/Input";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import { SectionHeader } from "@/components/ui/SectionHeader";
import type { WebauthnCredential } from "@/types";

/**
 * The signed-in member's passkeys. Enrolling runs the WebAuthn creation
 * ceremony in the browser; password sign-in stays available, so removing
 * the last passkey is allowed.
 */
export function Passkeys() {
  const [nickname, setNickname] = useState("");
  const supported = passkeysSupported();

  const credentials = useQuery({
    queryKey: keys.passkeys.list(),
    queryFn: () => api.get<WebauthnCredential[]>("/webauthn_credentials"),
  });

  const enrol = useFormMutation({
    mutationFn: () => registerPasskey(nickname.trim()),
    meta: { invalidates: [keys.passkeys.all] },
    onSuccess: () => setNickname(""),
    fallback: passkeyErrorMessage,
  });

  const remove = useMutation({
    mutationFn: (id: string) => api.delete(`/webauthn_credentials/${id}`),
    meta: { invalidates: [keys.passkeys.all] },
  });

  function onSubmit(event: FormEvent) {
    event.preventDefault();
    enrol.mutate();
  }

  return (
    <section className="space-y-3">
      <SectionHeader
        title="Your passkeys"
        description="Sign in with a fingerprint, face, or security key instead of the password. Each device you enrol is one passkey."
      />
      <QueryState
        query={credentials}
        errorMessage="Could not load passkeys."
        empty={<EmptyState title="No passkeys yet" description="Add one below to sign in without typing the password." />}
      >
        {(rows) => (
        <ul className="divide-y divide-border">
          {rows.map((credential) => (
            <li key={credential.id} className="flex items-center justify-between gap-4 py-3">
              <div className="flex min-w-0 items-center gap-3">
                <KeyRound className="h-4 w-4 shrink-0 text-muted" aria-hidden />
                <div className="min-w-0">
                  <p className="truncate text-sm text-foreground">{credential.nickname ?? "Unnamed device"}</p>
                  <p className="text-xs text-muted">
                    Added {relativeTime(credential.created_at)}
                    {credential.last_used_at ? ` · last used ${relativeTime(credential.last_used_at)}` : " · never used"}
                  </p>
                </div>
              </div>
              <ConfirmButton
                variant="ghost"
                size="sm"
                question="Remove this passkey?"
                onConfirm={() => remove.mutate(credential.id)}
                disabled={remove.isPending}
              >
                Remove
              </ConfirmButton>
            </li>
          ))}
        </ul>
        )}
      </QueryState>

      {supported ? (
        <form onSubmit={onSubmit} className="flex flex-wrap items-end gap-3">
          <Input
            label="Nickname"
            name="passkey-nickname"
            value={nickname}
            placeholder="This laptop"
            onChange={(event) => setNickname(event.target.value)}
          />
          <Button type="submit" disabled={enrol.isPending}>
            {enrol.isPending ? "Waiting for the authenticator…" : "Add a passkey"}
          </Button>
          <FormError message={enrol.errorMessage} className="w-full" />
        </form>
      ) : (
        <p className="text-sm text-muted">This browser can't create passkeys.</p>
      )}
    </section>
  );
}
