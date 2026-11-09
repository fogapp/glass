import { useEffect, useRef, useState, type FormEvent, type ReactNode } from "react";
import { Navigate } from "react-router-dom";
import { safeReturnPath } from "@/lib/returnPath";
import { useQuery } from "@tanstack/react-query";
import { api, ApiError, apiErrorMessage } from "@/api/client";
import { loginWithPasskey, passkeyErrorMessage, passkeysSupported } from "@/lib/passkeys";
import { keys } from "@/lib/queryKeys";
import { useAuth } from "@/hooks/useAuth";
import { Button } from "@/components/ui/Button";
import { Card, CardBody } from "@/components/ui/Card";
import { Checkbox } from "@/components/ui/Checkbox";
import { FormError } from "@/components/ui/Form";
import { Input } from "@/components/ui/Input";
import { ErrorState, LoadingState } from "@/components/ui/PageState";
import type { SetupStatus } from "@/types";

/** Login doubles as the first-run wizard: a fresh fog deploy has no users, so
 *  the same screen creates the household and its first admin — or restores a
 *  fog-backup/2 artifact and recovers the previous instance instead.
 *
 *  Signing in with fog (fog-signin/1) sits above Glass's own form when Glass
 *  is pointed at an OpenID provider, and is the only way in once Glass has
 *  proven it runs on fog: then the first person through fog is the admin,
 *  and there is no wizard, no password and no passkey. */
export function Login() {
  const { signIn, completeSetup, adoptSession, isAuthenticated } = useAuth();
  // Where the person was headed when the console sent them here (an
  // approval page from fog's Integrations tab), kept through either sign-in.
  const returnTo = safeReturnPath(new URLSearchParams(window.location.search).get("return_to"));
  // Set once a restore is armed: the app restarts itself to recover.
  const [restarting, setRestarting] = useState(false);
  const setupQuery = useQuery({
    queryKey: keys.session.setup(),
    queryFn: () => api.get<SetupStatus>("/setup"),
    // While the restored instance comes up, keep asking until it answers
    // that setup is done. Failures in between are the restart itself.
    refetchInterval: restarting ? 5_000 : false,
  });
  const setup = setupQuery.data;

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [name, setName] = useState("");
  const [householdName, setHouseholdName] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const [mode, setMode] = useState<"create" | "restore">("create");
  const [confirmIdentity, setConfirmIdentity] = useState(false);
  const [needsIdentityConfirm, setNeedsIdentityConfirm] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);

  const isSetup = setup?.setup_required === true;
  const canPasskey = passkeysSupported();
  const fogSignin = setup?.signin?.enabled === true;
  const fogOnly = setup?.signin?.fog_only === true;
  // A sign-in that came back refused or broken says so here (the callback
  // puts the reason in the fragment).
  const [signinError] = useState(() => new URLSearchParams(window.location.hash.slice(1)).get("signin_error"));

  // The WebAuthn ceremony runs in the browser; the server hands back the
  // same session shape as a password sign-in.
  async function onPasskey() {
    setError(null);
    setBusy(true);
    try {
      adoptSession(await loginWithPasskey(email.trim() || undefined));
    } catch (caught) {
      setError(apiErrorMessage(caught, passkeyErrorMessage(caught)));
    } finally {
      setBusy(false);
    }
  }

  // After the restore is armed the app restarts itself; once it is back and
  // recovered (setup no longer required), reload into the login of the
  // restored instance.
  useEffect(() => {
    if (restarting && setup?.setup_required === false) window.location.reload();
  }, [restarting, setup?.setup_required]);

  async function onSubmit(event: FormEvent) {
    event.preventDefault();
    setError(null);
    setBusy(true);
    try {
      if (isSetup && mode === "restore") {
        const file = fileRef.current?.files?.[0];
        if (!file) {
          setError("Choose a backup artifact (.fogpack.tar) first");
          return;
        }
        const form = new FormData();
        form.append("artifact", file);
        if (confirmIdentity) form.append("confirm_identity", "true");
        await api.postForm("/setup/restore", form);
        setRestarting(true);
      } else if (isSetup) {
        await completeSetup({ household_name: householdName, email, name, password });
      } else {
        await signIn(email, password);
      }
    } catch (caught) {
      setError(apiErrorMessage(caught, "Something went wrong"));
      // Identity drift is refused until explicitly confirmed — surface the
      // checkbox only once the server has said that's the blocker.
      if (caught instanceof ApiError && caught.errors.join(" ").includes("confirm_identity")) setNeedsIdentityConfirm(true);
    } finally {
      setBusy(false);
    }
  }

  // A successful sign-in (form, passkey, or first-run setup) sets the user;
  // nothing else moves off /login, so this is where the redirect lives.
  if (isAuthenticated) return <Navigate to={returnTo} replace />;

  if (restarting) {
    return (
      <LoginCard>
        <h1 className="text-xl font-semibold text-foreground">Restoring…</h1>
        <p className="mt-2 text-sm text-muted">
          The artifact is armed and the app is restarting to recover. Large
          archives can take a few minutes — this page will reload when the
          restored instance is back.
        </p>
      </LoginCard>
    );
  }

  // Which form to show depends on the answer: a failed check must not fall
  // through to the sign-in form, which on a fresh instance has no one to
  // sign in as — and which a fog-only Glass would refuse.
  if (setupQuery.isPending) {
    return (
      <LoginCard>
        <LoadingState label="Checking Glass…" />
      </LoginCard>
    );
  }
  if (setupQuery.isError) {
    return (
      <LoginCard>
        <ErrorState
          title="Couldn't reach Glass"
          message={apiErrorMessage(setupQuery.error, "The server didn't say whether it's set up.")}
          onRetry={() => void setupQuery.refetch()}
        />
      </LoginCard>
    );
  }

  return (
    <div className="flex min-h-screen items-center justify-center px-4">
      <Card className="w-full max-w-sm">
        <CardBody>
          <div className="mb-6">
            <h1 className="text-xl font-semibold text-foreground">
              {isSetup ? "Set up Glass" : "Glass"}
            </h1>
            <p className="mt-1 text-sm text-muted">
              {isSetup
                ? mode === "restore"
                  ? "Recover a previous instance from a backup artifact."
                  : "Create your household and the first admin account."
                : "Sign in to the curation console."}
            </p>
          </div>

          {fogSignin ? (
            <div className={fogOnly ? "" : "mb-6"}>
              <Button
                type="button"
                className="w-full"
                onClick={() => window.location.assign(`/auth/oidc/start?return_to=${encodeURIComponent(returnTo)}`)}
              >
                Sign in with fog
              </Button>
              {signinError ? (
                <FormError
                  className="mt-3"
                  message={
                    signinError === "access_denied"
                      ? "fog didn't let you in. Ask whoever runs it to share Glass with you."
                      : "Signing in with fog didn't work. Try again."
                  }
                />
              ) : null}
              {fogOnly ? (
                <p className="mt-3 text-xs text-muted">Glass signs everyone in with fog.</p>
              ) : (
                <p className="mt-3 text-center text-xs text-muted">or</p>
              )}
            </div>
          ) : null}

          {fogOnly ? null : isSetup ? (
            <div className="mb-4 flex gap-2">
              <Button
                type="button"
                size="sm"
                variant={mode === "create" ? "primary" : "secondary"}
                onClick={() => setMode("create")}
              >
                Start fresh
              </Button>
              <Button
                type="button"
                size="sm"
                variant={mode === "restore" ? "primary" : "secondary"}
                onClick={() => setMode("restore")}
              >
                Restore from backup
              </Button>
            </div>
          ) : null}

          {fogOnly ? null : (
            <form onSubmit={onSubmit} className="space-y-4">
              {isSetup && mode === "restore" ? (
                <>
                  <div>
                    <label className="mb-1 block text-sm font-medium text-foreground" htmlFor="artifact">
                      Backup artifact
                    </label>
                    <input
                      ref={fileRef}
                      id="artifact"
                      name="artifact"
                      type="file"
                      accept=".tar,application/x-tar"
                      className="block w-full text-sm text-foreground file:mr-3 file:rounded-[var(--radius-control)] file:border file:border-border file:bg-surface file:px-3 file:py-1.5 file:text-sm file:text-foreground"
                    />
                    <p className="mt-1 text-xs text-muted">
                      A .fogpack.tar produced by this app (fog keeps them under Backups).
                    </p>
                  </div>
                  {needsIdentityConfirm ? (
                    <Checkbox
                      checked={confirmIdentity}
                      onChange={setConfirmIdentity}
                      label="The artifact was made for a different host. I understand a host change breaks every passkey and stored peer connection — restore anyway."
                    />
                  ) : null}
                </>
              ) : (
                <>
                  {isSetup ? (
                    <>
                      <Input
                        label="Household name"
                        name="household_name"
                        value={householdName}
                        onChange={(e) => setHouseholdName(e.target.value)}
                        required
                      />
                      <Input
                        label="Your name"
                        name="name"
                        value={name}
                        onChange={(e) => setName(e.target.value)}
                        required
                      />
                    </>
                  ) : null}
                  <Input
                    label="Email"
                    name="email"
                    type="email"
                    autoComplete="username"
                    value={email}
                    onChange={(e) => setEmail(e.target.value)}
                    required
                  />
                  <Input
                    label="Password"
                    name="password"
                    type="password"
                    autoComplete={isSetup ? "new-password" : "current-password"}
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    hint={isSetup ? "At least 10 characters." : undefined}
                    required
                  />
                </>
              )}
              <FormError message={error} />
              <Button type="submit" className="w-full" disabled={busy}>
                {busy
                  ? "Working…"
                  : isSetup
                    ? mode === "restore"
                      ? "Restore"
                      : "Create household"
                    : "Sign in"}
              </Button>
              {!isSetup && canPasskey ? (
                <Button type="button" variant="secondary" className="w-full" disabled={busy} onClick={onPasskey}>
                  Sign in with a passkey
                </Button>
              ) : null}
            </form>
          )}
        </CardBody>
      </Card>
    </div>
  );
}

function LoginCard({ children }: { children: ReactNode }) {
  return (
    <div className="flex min-h-screen items-center justify-center px-4">
      <Card className="w-full max-w-sm">
        <CardBody>{children}</CardBody>
      </Card>
    </div>
  );
}
