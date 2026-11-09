import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { api, ApiError, tokenStore } from "@/api/client";
import { AuthProvider } from "@/hooks/useAuth";
import { SigninComplete, SigninLink } from "./SigninHandoff";

vi.mock("@/api/client", async (original) => ({
  ...(await original<typeof import("@/api/client")>()),
  api: { get: vi.fn(), post: vi.fn(), postForm: vi.fn(), delete: vi.fn() },
}));

const session = {
  token: "t",
  user: { id: "u", email: "kim.0123456789ab@fog.invalid", name: "Kim", role: "member" as const, household_id: "h" },
};

function renderAt(path: string, hash: string) {
  window.history.replaceState(null, "", `${path}${hash}`);
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={client}>
      <AuthProvider>
        <MemoryRouter initialEntries={[path]}>
          <Routes>
            <Route path="/auth/complete" element={<SigninComplete />} />
            <Route path="/auth/link" element={<SigninLink />} />
            <Route path="/traces" element={<p>traces page</p>} />
            <Route path="/login" element={<p>login page</p>} />
            <Route path="/" element={<p>home page</p>} />
          </Routes>
        </MemoryRouter>
      </AuthProvider>
    </QueryClientProvider>,
  );
}

beforeEach(() => {
  vi.mocked(api.post).mockReset();
  tokenStore.clear();
});

afterEach(() => vi.unstubAllGlobals());

describe("SigninComplete", () => {
  it("trades the one-time code for a session and goes where the person was headed", async () => {
    vi.mocked(api.post).mockResolvedValue(session);
    renderAt("/auth/complete", "#handoff=abc&return_to=%2Ftraces");

    expect(await screen.findByText("traces page")).toBeInTheDocument();
    expect(api.post).toHaveBeenCalledTimes(1);
    expect(api.post).toHaveBeenCalledWith("/handoff", { handoff: "abc" });
    expect(tokenStore.get()).toBe("t");
    // The code is gone from the address bar once read.
    expect(window.location.hash).toBe("");
  });

  it("never follows a return path off this host", async () => {
    vi.mocked(api.post).mockResolvedValue(session);
    renderAt("/auth/complete", "#handoff=abc&return_to=%2F%2Fevil.example%2F");

    expect(await screen.findByText("home page")).toBeInTheDocument();
  });

  it("says so when the code has expired", async () => {
    vi.mocked(api.post).mockRejectedValue(new ApiError(401, ["This sign-in link has expired; sign in again."]));
    renderAt("/auth/complete", "#handoff=old");

    expect(await screen.findByRole("button", { name: "Back to sign-in" })).toBeInTheDocument();
    expect(screen.getByRole("alert")).toHaveTextContent("This sign-in link has expired; sign in again.");
    expect(tokenStore.get()).toBeNull();
  });

  it("says so when there is no code at all", async () => {
    renderAt("/auth/complete", "");

    expect(await screen.findByText(/incomplete/)).toBeInTheDocument();
    expect(api.post).not.toHaveBeenCalled();
  });
});

describe("SigninLink", () => {
  it("sends someone without a pending sign-in back to the login page", async () => {
    renderAt("/auth/link", "");

    expect(await screen.findByText("login page")).toBeInTheDocument();
  });

  it("connects an existing account by its password, then signs in", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValue(new Response(JSON.stringify({ handoff: "h1", return_to: "/traces" }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    vi.mocked(api.post).mockResolvedValue(session);
    renderAt("/auth/link", "#pending=sealed");

    fireEvent.change(screen.getByLabelText("Email"), { target: { value: "kim@example.com" } });
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "passwordpassword" } });
    fireEvent.click(screen.getByRole("button", { name: "Connect my account" }));

    expect(await screen.findByText("traces page")).toBeInTheDocument();
    expect(fetchMock).toHaveBeenCalledWith(
      "/auth/oidc/link",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ pending: "sealed", login: "kim@example.com", password: "passwordpassword" }),
      }),
    );
    expect(api.post).toHaveBeenCalledWith("/handoff", { handoff: "h1" });
    expect(tokenStore.get()).toBe("t");
  });

  it("starts fresh when the person has no account", async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({ handoff: "h2", return_to: "/" }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    vi.mocked(api.post).mockResolvedValue(session);
    renderAt("/auth/link", "#pending=sealed");

    fireEvent.click(screen.getByRole("button", { name: "I don't have one — start fresh" }));

    expect(await screen.findByText("home page")).toBeInTheDocument();
    expect(fetchMock).toHaveBeenCalledWith(
      "/auth/oidc/link",
      expect.objectContaining({ body: JSON.stringify({ pending: "sealed", fresh: "true" }) }),
    );
  });

  it("shows the server's refusal and stays put", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        new Response(JSON.stringify({ errors: ["That isn't the password for that account."] }), { status: 401 }),
      ),
    );
    renderAt("/auth/link", "#pending=sealed");

    fireEvent.change(screen.getByLabelText("Email"), { target: { value: "kim@example.com" } });
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "nope-nope-nope" } });
    fireEvent.click(screen.getByRole("button", { name: "Connect my account" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("That isn't the password for that account.");
    expect(api.post).not.toHaveBeenCalled();
    expect(tokenStore.get()).toBeNull();
  });
});
