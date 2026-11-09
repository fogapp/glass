import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { api, ApiError } from "@/api/client";
import { AuthProvider } from "@/hooks/useAuth";
import type { SetupStatus } from "@/types";
import { Login } from "./Login";

vi.mock("@/api/client", async (original) => ({
  ...(await original<typeof import("@/api/client")>()),
  api: { get: vi.fn(), post: vi.fn(), postForm: vi.fn(), delete: vi.fn() },
}));

function status(overrides: Partial<SetupStatus> = {}): SetupStatus {
  return { setup_required: false, signin: { enabled: false, fog_only: false }, ...overrides };
}

function renderLogin() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={client}>
      <AuthProvider>
        <MemoryRouter initialEntries={["/login"]}>
          <Login />
        </MemoryRouter>
      </AuthProvider>
    </QueryClientProvider>,
  );
}

describe("Login", () => {
  beforeEach(() => {
    vi.mocked(api.get).mockReset();
    window.history.replaceState(null, "", "/login");
    // A browser that can do passkeys, so their absence below means Glass
    // hid them, not that the test runtime lacks WebAuthn.
    vi.stubGlobal("PublicKeyCredential", function PublicKeyCredential() {});
  });

  afterEach(() => vi.unstubAllGlobals());

  it("offers Glass's own sign-in alone off any provider", async () => {
    vi.mocked(api.get).mockResolvedValue(status());
    renderLogin();

    expect(await screen.findByRole("button", { name: "Sign in" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Sign in with a passkey" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Sign in with fog" })).not.toBeInTheDocument();
  });

  it("shows the setup wizard on a fresh Glass", async () => {
    vi.mocked(api.get).mockResolvedValue(status({ setup_required: true }));
    renderLogin();

    expect(await screen.findByRole("heading", { name: "Set up Glass" })).toBeInTheDocument();
  });

  it("offers fog beside Glass's own sign-in while Glass is not yet fog-only", async () => {
    vi.mocked(api.get).mockResolvedValue(status({ signin: { enabled: true, fog_only: false } }));
    renderLogin();

    expect(await screen.findByRole("button", { name: "Sign in with fog" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Sign in" })).toBeInTheDocument();
  });

  it("sends the browser to fog's sign-in", async () => {
    const assign = vi.fn();
    vi.stubGlobal("location", { ...window.location, hash: "", assign });
    vi.mocked(api.get).mockResolvedValue(status({ signin: { enabled: true, fog_only: false } }));
    renderLogin();

    fireEvent.click(await screen.findByRole("button", { name: "Sign in with fog" }));
    expect(assign).toHaveBeenCalledWith("/auth/oidc/start?return_to=%2F");
  });

  it("carries a deep link through fog's sign-in", async () => {
    const assign = vi.fn();
    vi.stubGlobal("location", { ...window.location, hash: "", search: "?return_to=%2Fconnect%2Fabc", assign });
    vi.mocked(api.get).mockResolvedValue(status({ signin: { enabled: true, fog_only: false } }));
    renderLogin();

    fireEvent.click(await screen.findByRole("button", { name: "Sign in with fog" }));
    expect(assign).toHaveBeenCalledWith("/auth/oidc/start?return_to=%2Fconnect%2Fabc");
  });

  it("never carries a return address off this host", async () => {
    const assign = vi.fn();
    vi.stubGlobal("location", { ...window.location, hash: "", search: "?return_to=//evil.example", assign });
    vi.mocked(api.get).mockResolvedValue(status({ signin: { enabled: true, fog_only: false } }));
    renderLogin();

    fireEvent.click(await screen.findByRole("button", { name: "Sign in with fog" }));
    expect(assign).toHaveBeenCalledWith("/auth/oidc/start?return_to=%2F");
  });

  // Once Glass has proven it runs on fog, fog is the only door: no password
  // form, no passkeys and no setup wizard — the first person through fog is
  // the admin.
  it("shows only fog once Glass is fog-only", async () => {
    vi.mocked(api.get).mockResolvedValue(status({ signin: { enabled: true, fog_only: true } }));
    renderLogin();

    expect(await screen.findByRole("button", { name: "Sign in with fog" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Sign in" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Sign in with a passkey" })).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Password")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Restore from backup" })).not.toBeInTheDocument();
  });

  it("says why a fog sign-in came back refused", async () => {
    window.history.replaceState(null, "", "/login#signin_error=access_denied");
    vi.mocked(api.get).mockResolvedValue(status({ signin: { enabled: true, fog_only: true } }));
    renderLogin();

    expect(await screen.findByRole("alert")).toHaveTextContent("fog didn't let you in");
  });

  // A failed check must not fall through to a password form that a fog-only
  // Glass would refuse.
  it("says so when the server can't be reached, and tries again", async () => {
    vi.mocked(api.get).mockRejectedValue(new ApiError(0, ["Couldn't reach the server"]));
    renderLogin();

    expect(await screen.findByText("Couldn't reach Glass")).toBeInTheDocument();
    expect(screen.queryByLabelText("Password")).not.toBeInTheDocument();

    vi.mocked(api.get).mockResolvedValue(status());
    fireEvent.click(screen.getByRole("button", { name: "Try again" }));

    expect(await screen.findByRole("button", { name: "Sign in" })).toBeInTheDocument();
  });
});
