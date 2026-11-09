import { useEffect, useRef, useState, type FormEvent, type ReactNode } from "react";
import { Navigate } from "react-router-dom";
import { api, apiErrorMessage } from "@/api/client";
import { useAuth } from "@/hooks/useAuth";
import { safeReturnPath } from "@/lib/returnPath";
import { Button } from "@/components/ui/Button";
import { Card, CardBody } from "@/components/ui/Card";
import { FormError } from "@/components/ui/Form";
import { Input } from "@/components/ui/Input";
import { LoadingState } from "@/components/ui/PageState";
import type { SessionResponse } from "@/types";

/** The fragment the sign-in callback left, read once and cleared from the
 *  address bar so the one-time code never lingers in history. */
function takeFragment(): URLSearchParams {
  const params = new URLSearchParams(window.location.hash.slice(1));
  window.history.replaceState(null, "", window.location.pathname);
  return params;
}

/** /auth/complete — fog sent the person back signed in; trade the one-time
 *  code for the session token, as a password sign-in would have answered.
 *  The console-minted recovery link (bin/rails glass:recovery_link) lands
 *  here too. */
export function SigninComplete() {
  const { adoptSession } = useAuth();
  const [error, setError] = useState<string | null>(null);
  const [to, setTo] = useState<string | null>(null);
  // The code is good once: StrictMode's second effect run must not spend it
  // again and report the first, successful exchange as expired.
  const started = useRef(false);

  useEffect(() => {
    if (started.current) return;
    started.current = true;
    const params = takeFragment();
    const handoff = params.get("handoff");
    if (!handoff) {
      setError("This sign-in link is incomplete. Sign in again.");
      return;
    }
    api
      .post<SessionResponse>("/handoff", { handoff })
      .then((session) => {
        adoptSession(session);
        setTo(safeReturnPath(params.get("return_to")));
      })
      .catch((caught: unknown) =>
        setError(apiErrorMessage(caught, "This sign-in link has expired. Sign in again.")),
      );
  }, [adoptSession]);

  if (to) return <Navigate to={to} replace />;
  return (
    <SigninCard>
      {error ? (
        <>
          <FormError message={error} />
          <Button className="mt-4 w-full" onClick={() => window.location.assign("/login")}>
            Back to sign-in
          </Button>
        </>
      ) : (
        <LoadingState label="Signing you in…" />
      )}
    </SigninCard>
  );
}

interface LinkResponse {
  handoff?: string;
  return_to?: string;
  errors?: string[];
}

/** /auth/link — fog says who this is, but Glass already has accounts and
 *  none is linked to them. Never guessed by email: the person proves an
 *  account is theirs by signing in to it once, or starts a fresh one. */
export function SigninLink() {
  const { adoptSession } = useAuth();
  const [pending] = useState(() => takeFragment().get("pending") ?? "");
  const [login, setLogin] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [to, setTo] = useState<string | null>(null);

  // /auth/oidc/link sits outside /api/v1 (it is the shared kit's door, like
  // the callback), so it is fetched directly rather than through `api`.
  async function send(body: Record<string, string>) {
    setError(null);
    setBusy(true);
    try {
      const res = await fetch("/auth/oidc/link", {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({ pending, ...body }),
      });
      const data = (await res.json().catch(() => ({}))) as LinkResponse;
      if (!res.ok || !data.handoff) {
        throw new Error(data.errors?.join(" ") || "That didn't work. Sign in again.");
      }
      adoptSession(await api.post<SessionResponse>("/handoff", { handoff: data.handoff }));
      setTo(safeReturnPath(data.return_to));
    } catch (caught) {
      setError(apiErrorMessage(caught, caught instanceof Error ? caught.message : "That didn't work."));
    } finally {
      setBusy(false);
    }
  }

  function onSubmit(event: FormEvent) {
    event.preventDefault();
    void send({ login, password });
  }

  if (to) return <Navigate to={to} replace />;
  if (!pending) return <Navigate to="/login" replace />;
  return (
    <SigninCard>
      <h1 className="text-xl font-semibold text-foreground">Connect your Glass account</h1>
      <p className="mt-1 text-sm text-muted">
        fog signed you in, and Glass already has accounts. Sign in to yours once to connect it —
        from then on fog signs you in.
      </p>
      <form onSubmit={onSubmit} className="mt-6 space-y-4">
        <Input
          label="Email"
          name="email"
          type="email"
          autoComplete="username"
          value={login}
          onChange={(e) => setLogin(e.target.value)}
          required
        />
        <Input
          label="Password"
          name="password"
          type="password"
          autoComplete="current-password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          required
        />
        <FormError message={error} />
        <Button type="submit" className="w-full" disabled={busy}>
          {busy ? "Working…" : "Connect my account"}
        </Button>
        <Button
          type="button"
          variant="secondary"
          className="w-full"
          disabled={busy}
          onClick={() => void send({ fresh: "true" })}
        >
          I don't have one — start fresh
        </Button>
      </form>
    </SigninCard>
  );
}

function SigninCard({ children }: { children: ReactNode }) {
  return (
    <div className="flex min-h-screen items-center justify-center px-4">
      <Card className="w-full max-w-sm">
        <CardBody>{children}</CardBody>
      </Card>
    </div>
  );
}
