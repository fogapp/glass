import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { api, tokenStore } from "@/api/client";
import type { SessionResponse, User } from "@/types";

interface AuthValue {
  user: User | null;
  isAuthenticated: boolean;
  signIn: (email: string, password: string) => Promise<void>;
  completeSetup: (input: {
    household_name: string;
    email: string;
    name: string;
    password: string;
  }) => Promise<void>;
  signOut: () => void;
  /** Sign in with a session the server already issued (a passkey ceremony). */
  adoptSession: (session: SessionResponse) => void;
}

const AuthContext = createContext<AuthValue | null>(null);
const USER_KEY = "glass_user";

function readStoredUser(): User | null {
  try {
    const raw = localStorage.getItem(USER_KEY);
    return raw ? (JSON.parse(raw) as User) : null;
  } catch {
    return null;
  }
}

/**
 * Forget the signed-in session outside React — for the 401 handler, which
 * runs in the query client and bounces to /login with a full reload.
 */
export function clearSession() {
  tokenStore.clear();
  try {
    localStorage.removeItem(USER_KEY);
  } catch {
    // Storage unavailable: nothing was stored to forget.
  }
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUserState] = useState<User | null>(readStoredUser);
  const queryClient = useQueryClient();

  const setUser = useCallback((next: User | null) => {
    setUserState(next);
    try {
      if (next) localStorage.setItem(USER_KEY, JSON.stringify(next));
      else localStorage.removeItem(USER_KEY);
    } catch {
      // Storage unavailable: the session lasts as long as the tab.
    }
  }, []);

  const adopt = useCallback(
    (session: SessionResponse) => {
      // Whatever is cached belongs to whoever was signed in before (or to
      // nobody) — a different user on the same tab must never see it.
      queryClient.clear();
      tokenStore.set(session.token);
      setUser(session.user);
    },
    [queryClient, setUser],
  );

  const signIn = useCallback(
    async (email: string, password: string) => {
      adopt(await api.post<SessionResponse>("/session", { email, password }));
    },
    [adopt],
  );

  const completeSetup = useCallback(
    async (input: { household_name: string; email: string; name: string; password: string }) => {
      adopt(await api.post<SessionResponse>("/setup", input));
    },
    [adopt],
  );

  const signOut = useCallback(() => {
    void api.delete("/session").catch(() => undefined);
    clearSession();
    // Drop every cached response so the next person to sign in on this tab
    // starts from the server, not from the last household's wants.
    queryClient.clear();
    setUserState(null);
  }, [queryClient]);

  const value = useMemo<AuthValue>(
    () => ({
      user,
      isAuthenticated: Boolean(user && tokenStore.get()),
      signIn,
      completeSetup,
      signOut,
      adoptSession: adopt,
    }),
    [user, signIn, completeSetup, signOut, adopt],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const context = useContext(AuthContext);
  if (!context) throw new Error("useAuth must be used inside AuthProvider");
  return context;
}
