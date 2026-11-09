import { lazy, type ComponentType } from "react";
import { QueryClientProvider } from "@tanstack/react-query";
import { BrowserRouter, Navigate, Route, Routes, useLocation } from "react-router-dom";
import { AuthProvider, useAuth } from "@/hooks/useAuth";
import { AppShell } from "@/components/layout/AppShell";
import { createQueryClient } from "@/lib/queryClient";
import { Login } from "@/pages/Login";
// Where a fog sign-in lands, outside the shell (and its Suspense boundary):
// eager, like Login, and as small.
import { SigninComplete, SigninLink } from "@/pages/SigninHandoff";

/**
 * Each page is its own chunk, fetched the first time its route renders.
 * AppShell wraps the outlet in Suspense inside the route error boundary, so
 * a page loading shows LoadingState and a page failing to load (a stale tab
 * after a deploy) offers a reload. Login stays in the entry chunk.
 */
function lazyPage<K extends string>(load: () => Promise<Record<K, ComponentType>>, name: K) {
  return lazy(async () => ({ default: (await load())[name] }));
}

const Overview = lazyPage(() => import("@/pages/Overview"), "Overview");
const Triage = lazyPage(() => import("@/pages/Triage"), "Triage");
const Apps = lazyPage(() => import("@/pages/Apps"), "Apps");
const AppShow = lazyPage(() => import("@/pages/AppShow"), "AppShow");
const Explore = lazyPage(() => import("@/pages/Explore"), "Explore");
const Traces = lazyPage(() => import("@/pages/Traces"), "Traces");
const Profiles = lazyPage(() => import("@/pages/Profiles"), "Profiles");
const Logs = lazyPage(() => import("@/pages/Logs"), "Logs");
const Visitors = lazyPage(() => import("@/pages/Visitors"), "Visitors");
const Dashboards = lazyPage(() => import("@/pages/Dashboards"), "Dashboards");
const Monitors = lazyPage(() => import("@/pages/Monitors"), "Monitors");
const Fleet = lazyPage(() => import("@/pages/Fleet"), "Fleet");
const ActivityLog = lazyPage(() => import("@/pages/ActivityLog"), "ActivityLog");
const Settings = lazyPage(() => import("@/pages/Settings"), "Settings");

const queryClient = createQueryClient();

function ProtectedRoutes() {
  const { isAuthenticated } = useAuth();
  const location = useLocation();
  if (!isAuthenticated) {
    // Only a deep link worth coming back to; the overview is the default.
    const back = location.pathname === "/" ? "" : `?return_to=${encodeURIComponent(location.pathname + location.search)}`;
    return <Navigate to={`/login${back}`} replace />;
  }

  return (
    <Routes>
      <Route element={<AppShell />}>
        <Route index element={<Overview />} />
        <Route path="triage" element={<Triage />} />
        <Route path="triage/:id" element={<Triage />} />
        <Route path="apps" element={<Apps />} />
        <Route path="apps/:slug" element={<AppShow />} />
        <Route path="apps/:slug/:tab" element={<AppShow />} />
        <Route path="apps/:slug/endpoints/:name" element={<AppShow />} />
        <Route path="apps/:slug/jobs/:job" element={<AppShow />} />
        <Route path="apps/:slug/sessions/:session" element={<AppShow />} />
        <Route path="explore" element={<Explore />} />
        <Route path="traces" element={<Traces />} />
        <Route path="traces/:id" element={<Traces />} />
        <Route path="profiles" element={<Profiles />} />
        <Route path="logs" element={<Logs />} />
        <Route path="visitors" element={<Visitors />} />
        <Route path="visitors/:tab" element={<Visitors />} />
        <Route path="visitors/:tab/:visit" element={<Visitors />} />
        <Route path="dashboards" element={<Dashboards />} />
        <Route path="dashboards/:id" element={<Dashboards />} />
        <Route path="monitors" element={<Monitors />} />
        <Route path="monitors/:id" element={<Monitors />} />
        <Route path="fleet" element={<Fleet />} />
        <Route path="activity" element={<ActivityLog />} />
        <Route path="settings" element={<Settings />} />
        <Route path="settings/:section" element={<Settings />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  );
}

export function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <BrowserRouter>
          <Routes>
            <Route path="/login" element={<Login />} />
            <Route path="/auth/complete" element={<SigninComplete />} />
            <Route path="/auth/link" element={<SigninLink />} />
            <Route path="/*" element={<ProtectedRoutes />} />
          </Routes>
        </BrowserRouter>
      </AuthProvider>
    </QueryClientProvider>
  );
}
