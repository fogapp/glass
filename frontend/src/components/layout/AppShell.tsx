import { Suspense, useEffect, useState } from "react";
import { Outlet, useLocation } from "react-router-dom";
import { Command, LogOut, Menu as MenuIcon, Moon, Sun, X } from "lucide-react";
import { useAuth } from "@/hooks/useAuth";
import { BREAKPOINTS, useMediaQuery } from "@/hooks/useMediaQuery";
import { useTheme } from "@/hooks/useTheme";
import { cn } from "@/lib/cn";
import { ScopeProvider } from "@/lib/scope";
import { useScopedNavigate } from "@/lib/scopeHref";
import { ScopedNavLink } from "@/components/scope/ScopedLink";
import { Toasts } from "@/components/ui/Toast";
import { RouteErrorBoundary } from "@/components/layout/RouteErrorBoundary";
import { LoadingState } from "@/components/ui/PageState";
import { IconButton } from "@/components/ui/IconButton";
import { NAV } from "@/components/layout/nav";
import { AppPicker } from "@/components/scope/AppPicker";
import { TimeRangePicker } from "@/components/scope/TimeRangePicker";
import { isTyping } from "@/lib/keyboard";
import { StatusLine } from "@/components/layout/StatusLine";
import { CommandPalette } from "@/components/layout/CommandPalette";

/**
 * The console frame: an icon rail at the left, a scope bar
 * across the top that every page obeys, the page, and a status line along
 * the bottom. The frame never reloads; pages change the canvas. Below `lg`
 * the rail folds into a drawer.
 *
 * Keyboard: ⌘K the palette; `g` then a letter jumps to a section; `?` lists
 * the rest; the scope bar has its own (`t`, `[`, `]`, `l`).
 */
export function AppShell() {
  return (
    <ScopeProvider>
      <Frame />
    </ScopeProvider>
  );
}

function Frame() {
  const { user, signOut } = useAuth();
  const { theme, toggle } = useTheme();
  const { pathname } = useLocation();
  // Moving between sections keeps the scope: the range you were reading in is the one you arrive in.
  const navigate = useScopedNavigate();
  const wide = useMediaQuery(BREAKPOINTS.lg);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [helpOpen, setHelpOpen] = useState(false);

  const section = NAV.find(({ to, end }) => (end ? pathname === to : pathname.startsWith(to)))?.label;
  useEffect(() => {
    document.title = section ? `${section} · Glass` : "Glass";
  }, [section]);

  useEffect(() => setDrawerOpen(false), [pathname]);
  useEffect(() => {
    if (wide) setDrawerOpen(false);
  }, [wide]);

  // `g` then a letter, within a second; ⌘K; `?`.
  useEffect(() => {
    let pendingGo = 0;
    const onKey = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        setPaletteOpen((open) => !open);
        return;
      }
      if (isTyping(event)) return;
      if (event.key === "Escape") {
        setHelpOpen(false);
        setDrawerOpen(false);
        return;
      }
      if (event.key === "?") {
        setHelpOpen((open) => !open);
        return;
      }
      const now = Date.now();
      if (event.key === "g") {
        pendingGo = now;
        return;
      }
      if (pendingGo && now - pendingGo < 1000) {
        const target = NAV.find((item) => item.key === event.key);
        if (target) navigate(target.to);
        pendingGo = 0;
      }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [navigate]);

  return (
    <div className="flex h-dvh overflow-hidden">
      {drawerOpen ? (
        <button type="button" aria-label="Close navigation" onClick={() => setDrawerOpen(false)} className="fixed inset-0 z-30 bg-background/60 lg:hidden" />
      ) : null}

      <aside
        id="app-navigation"
        aria-label="Navigation"
        className={cn(
          "flex h-dvh w-56 shrink-0 flex-col border-r border-border bg-surface lg:w-14",
          "lg:sticky lg:top-0 lg:flex lg:translate-x-0",
          drawerOpen ? "fixed inset-y-0 left-0 z-40 shadow-xl" : "hidden",
        )}
      >
        <div className="flex h-11 items-center justify-between px-3 lg:justify-center lg:px-0">
          <ScopedNavLink to="/" className="flex items-center gap-2" aria-label="Glass home">
            <span className="grid h-6 w-6 place-items-center rounded-md bg-primary text-primary-foreground" aria-hidden>
              <span className="block h-2 w-2 rounded-full bg-primary-foreground shadow-[0_0_8px_var(--color-primary-foreground)]" />
            </span>
            <span className="text-sm font-semibold text-foreground lg:hidden">Glass</span>
          </ScopedNavLink>
          <IconButton label="Close navigation" size="md" onClick={() => setDrawerOpen(false)} className="lg:hidden">
            <X className="h-4 w-4" aria-hidden />
          </IconButton>
        </div>

        <nav className="flex-1 space-y-0.5 overflow-y-auto px-2 py-1 lg:px-1.5">
          {NAV.map(({ to, label, icon: Icon, end, key }) => (
            <ScopedNavLink
              key={to}
              to={to}
              end={end}
              title={`${label} (g ${key})`}
              className={({ isActive }) =>
                cn(
                  "group flex items-center gap-2.5 rounded-[var(--radius-control)] px-2.5 py-2 text-sm lg:justify-center lg:px-0 lg:py-2.5",
                  isActive ? "bg-primary/10 text-primary" : "text-muted hover:bg-surface-raised hover:text-foreground",
                )
              }
            >
              <Icon className="h-[18px] w-[18px]" aria-hidden />
              <span className="lg:sr-only">{label}</span>
            </ScopedNavLink>
          ))}
        </nav>

        <div className="flex flex-col items-center gap-1 border-t border-border px-2 py-2 lg:px-0">
          <button
            type="button"
            onClick={() => setPaletteOpen(true)}
            title="Command palette (⌘K)"
            className="flex w-full items-center gap-2.5 rounded-[var(--radius-control)] px-2.5 py-2 text-sm text-muted hover:bg-surface-raised hover:text-foreground lg:w-auto lg:px-2"
          >
            <Command className="h-[18px] w-[18px]" aria-hidden />
            <span className="lg:sr-only">Command palette</span>
          </button>
          <IconButton label="Toggle theme" onClick={toggle}>
            {theme === "dark" ? <Sun className="h-4 w-4" aria-hidden /> : <Moon className="h-4 w-4" aria-hidden />}
          </IconButton>
          <IconButton label={`Sign out ${user?.name ?? ""}`} onClick={signOut}>
            <LogOut className="h-4 w-4" aria-hidden />
          </IconButton>
        </div>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex h-11 shrink-0 items-center gap-2 border-b border-border bg-surface px-2 sm:px-3">
          <IconButton
            label="Open navigation"
            onClick={() => setDrawerOpen(true)}
            aria-expanded={drawerOpen}
            aria-controls="app-navigation"
            className="lg:hidden"
          >
            <MenuIcon className="h-5 w-5" aria-hidden />
          </IconButton>
          <p className="hidden min-w-0 truncate text-sm font-medium text-foreground sm:block">{section ?? "Glass"}</p>
          <div className="ml-auto flex items-center gap-2 overflow-x-auto scrollbar-none">
            <AppPicker />
            <TimeRangePicker />
          </div>
        </header>

        <main className="min-w-0 flex-1 overflow-y-auto">
          <RouteErrorBoundary>
            <Suspense fallback={<LoadingState />}>
              <Outlet />
            </Suspense>
          </RouteErrorBoundary>
        </main>

        <StatusLine />
      </div>

      <CommandPalette open={paletteOpen} onClose={() => setPaletteOpen(false)} />
      {helpOpen ? <ShortcutHelp onClose={() => setHelpOpen(false)} /> : null}
      <Toasts />
    </div>
  );
}

function ShortcutHelp({ onClose }: { onClose: () => void }) {
  const rows: [string, string][] = [
    ["⌘K", "Command palette"],
    [`g then ${NAV.map((item) => item.key).join(" / ")}`, "Go to a section"],
    ["t", "Time range"],
    ["[ and ]", "Step the window back / forward"],
    ["l", "Follow the clock"],
    ["m", "Show / hide marker lines on charts"],
    ["/", "Focus the query bar"],
    ["+ − 0 and arrows", "Zoom and pan a focused flamegraph"],
    ["arrows and ⇧ arrows", "Move / resize a focused dashboard widget while editing"],
    ["j and k", "Next / previous finding in Triage"],
    ["Esc", "Close a drawer"],
    ["?", "This list"],
  ];
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-background/60 backdrop-blur-sm" onMouseDown={onClose}>
      <div role="dialog" aria-label="Keyboard shortcuts" className="w-full max-w-md rounded-[var(--radius-card)] border border-border bg-surface p-4 shadow-2xl" onMouseDown={(event) => event.stopPropagation()}>
        <h2 className="mb-3 text-sm font-semibold text-foreground">Keyboard</h2>
        <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1.5 text-sm">
          {rows.map(([key, what]) => (
            <div key={key} className="contents">
              <dt>
                <kbd className="rounded border border-border bg-surface-raised px-1.5 py-0.5 font-mono text-xs text-foreground">{key}</kbd>
              </dt>
              <dd className="text-muted">{what}</dd>
            </div>
          ))}
        </dl>
      </div>
    </div>
  );
}
