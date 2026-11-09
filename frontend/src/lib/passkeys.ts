import {
  startAuthentication,
  startRegistration,
  type PublicKeyCredentialCreationOptionsJSON,
  type PublicKeyCredentialRequestOptionsJSON,
} from "@simplewebauthn/browser";
import { api } from "@/api/client";
import type { SessionResponse, WebauthnCredential } from "@/types";

interface BeginResponse<O> {
  options: O;
  challenge_token: string;
}

/** Whether this browser can do passkeys at all — the buttons hide otherwise. */
export function passkeysSupported(): boolean {
  return typeof window !== "undefined" && typeof window.PublicKeyCredential === "function";
}

/** Sign in with a passkey. Email optional: without it the browser offers
 *  every discoverable passkey registered for this site. */
export async function loginWithPasskey(email?: string): Promise<SessionResponse> {
  const begin = await api.post<BeginResponse<PublicKeyCredentialRequestOptionsJSON>>(
    "/auth/passkey/login/begin",
    { email: email || undefined },
  );
  const credential = await startAuthentication({ optionsJSON: begin.options });
  return api.post<SessionResponse>("/auth/passkey/login/finish", {
    credential,
    challenge_token: begin.challenge_token,
  });
}

/** Enrol a new passkey for the signed-in member. */
export async function registerPasskey(nickname: string): Promise<WebauthnCredential> {
  const begin = await api.post<BeginResponse<PublicKeyCredentialCreationOptionsJSON>>(
    "/webauthn_credentials/register/begin",
  );
  const credential = await startRegistration({ optionsJSON: begin.options });
  return api.post<WebauthnCredential>("/webauthn_credentials/register/finish", {
    credential,
    challenge_token: begin.challenge_token,
    nickname: nickname || undefined,
  });
}

/** The browser's own cancellation/timeout reads as an error we can name. */
export function passkeyErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    if (error.name === "NotAllowedError") return "The passkey prompt was cancelled or timed out.";
    if (error.name === "InvalidStateError") return "This authenticator is already registered.";
    return error.message;
  }
  return "Passkey ceremony failed.";
}
