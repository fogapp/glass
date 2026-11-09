import { useEffect, useMemo, useRef, useState } from "react";
import { Search } from "lucide-react";
import { cn } from "@/lib/cn";
import { useScope } from "@/lib/scope";
import { useScopedNavigate } from "@/lib/scopeHref";
import { RANGE_PRESETS, parseRange } from "@/lib/timeRange";
import { useApps } from "@/hooks/useApps";
import { NAV } from "@/components/layout/nav";

interface Command {
  id: string;
  label: string;
  hint?: string;
  keywords?: string;
  run: () => void;
}

/**
 * ⌘K: go anywhere, scope to any app, pick any range. Everything the rail
 * and scope bar do, from the keyboard, with the query bar's fuzziness.
 */
export function CommandPalette({ open, onClose }: { open: boolean; onClose: () => void }) {
  const navigate = useScopedNavigate();
  const scope = useScope();
  const apps = useApps();
  const [query, setQuery] = useState("");
  const [cursor, setCursor] = useState(0);
  const input = useRef<HTMLInputElement>(null);

  const commands = useMemo<Command[]>(() => {
    const go = (to: string) => () => navigate(to);
    return [
      ...NAV.map((item) => ({ id: `nav:${item.to}`, label: item.label, hint: "go", keywords: "go page", run: go(item.to) })),
      ...(apps.data ?? []).flatMap((app) => [
        { id: `app:${app.slug}`, label: `Scope to ${app.name}`, hint: "app", keywords: `app ${app.slug}`, run: () => scope.setApp(app.slug) },
        { id: `open:${app.slug}`, label: `Open ${app.name}`, hint: "app", keywords: `app ${app.slug}`, run: go(`/apps/${app.slug}`) },
      ]),
      { id: "app:all", label: "Scope to all apps", hint: "app", run: () => scope.setApp(null) },
      ...RANGE_PRESETS.map((preset) => ({
        id: `range:${preset.key}`,
        label: `Last ${preset.label}`,
        hint: "range",
        keywords: `time range ${preset.key}`,
        run: () => scope.setRange(parseRange(preset.key)),
      })),
      { id: "live", label: scope.live ? "Stop following the clock" : "Follow the clock (live)", hint: "live", run: () => scope.setLive(!scope.live) },
      { id: "markers", label: scope.markers ? "Hide marker lines on charts" : "Show marker lines on charts", hint: "markers", keywords: "deploys incidents lines", run: () => scope.setMarkers(!scope.markers) },
    ];
  }, [apps.data, navigate, scope]);

  const matches = useMemo(() => {
    const needle = query.trim().toLowerCase();
    if (!needle) return commands.slice(0, 14);
    return commands
      .map((command) => ({ command, score: score(`${command.label} ${command.keywords ?? ""}`.toLowerCase(), needle) }))
      .filter((entry) => entry.score > 0)
      .sort((a, b) => b.score - a.score)
      .slice(0, 14)
      .map((entry) => entry.command);
  }, [commands, query]);

  useEffect(() => {
    if (open) {
      setQuery("");
      setCursor(0);
      window.setTimeout(() => input.current?.focus(), 0);
    }
  }, [open]);
  useEffect(() => setCursor(0), [query]);

  if (!open) return null;

  const run = (command: Command | undefined) => {
    if (!command) return;
    command.run();
    onClose();
  };

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center bg-background/60 pt-[12vh] backdrop-blur-sm" onMouseDown={onClose}>
      <div
        role="dialog"
        aria-label="Command palette"
        className="w-full max-w-lg overflow-hidden rounded-[var(--radius-card)] border border-border bg-surface shadow-2xl"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <div className="flex items-center gap-2 border-b border-border px-3">
          <Search className="h-4 w-4 text-muted" aria-hidden />
          <input
            ref={input}
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "ArrowDown") {
                event.preventDefault();
                setCursor((value) => Math.min(value + 1, matches.length - 1));
              } else if (event.key === "ArrowUp") {
                event.preventDefault();
                setCursor((value) => Math.max(value - 1, 0));
              } else if (event.key === "Enter") run(matches[cursor]);
              else if (event.key === "Escape") onClose();
            }}
            placeholder="Go to a page, scope to an app, pick a range…"
            aria-label="Command"
            className="h-11 flex-1 bg-transparent text-sm text-foreground outline-none placeholder:text-muted"
          />
          <kbd className="rounded border border-border px-1.5 text-[10px] text-muted">esc</kbd>
        </div>
        <ul className="max-h-80 overflow-y-auto py-1" role="listbox">
          {matches.length === 0 ? <li className="px-3 py-4 text-center text-xs text-muted">Nothing matches</li> : null}
          {matches.map((command, index) => (
            <li key={command.id} role="option" aria-selected={index === cursor}>
              <button
                type="button"
                onMouseEnter={() => setCursor(index)}
                onClick={() => run(command)}
                className={cn(
                  "flex w-full items-center justify-between px-3 py-2 text-left text-sm",
                  index === cursor ? "bg-primary/10 text-foreground" : "text-foreground/90",
                )}
              >
                <span>{command.label}</span>
                {command.hint ? <span className="text-[10px] uppercase tracking-wider text-muted">{command.hint}</span> : null}
              </button>
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}

/** Subsequence match with a bonus for word starts; 0 when it does not match. */
function score(haystack: string, needle: string): number {
  let points = 0;
  let position = 0;
  for (const char of needle) {
    const found = haystack.indexOf(char, position);
    if (found < 0) return 0;
    points += found === position ? 3 : found === 0 || haystack[found - 1] === " " ? 2 : 1;
    position = found + 1;
  }
  return points + (haystack.startsWith(needle) ? 10 : 0);
}
