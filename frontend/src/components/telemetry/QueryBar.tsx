import { useEffect, useMemo, useRef, useState, type KeyboardEvent } from "react";
import { useQuery } from "@tanstack/react-query";
import { Search } from "lucide-react";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { roundRange } from "@/lib/glassQuery";
import { cn } from "@/lib/cn";
import { fieldsInScope } from "@/lib/workFields";
import { useScope } from "@/lib/scope";
import { useDebouncedValue } from "@/hooks/useDebouncedValue";
import type { FacetValue, QueryCatalog } from "@/types";

export function useCatalog() {
  return useQuery({ queryKey: keys.query.catalog(), queryFn: () => api.get<QueryCatalog>("/query/sources"), staleTime: 60_000 });
}

/**
 * The query bar: filter text with completion for field
 * names and, after a colon, the values seen in range. `/` focuses it from
 * anywhere; Enter applies; Escape closes the suggestions.
 */
export function QueryBar({
  value,
  onChange,
  onSubmit,
  source,
  metric,
  placeholder = "app:hook status:error duration:>250ms",
  className,
  autoFocus,
}: {
  value: string;
  onChange: (next: string) => void;
  onSubmit: (next: string) => void;
  source: string;
  metric?: string;
  placeholder?: string;
  className?: string;
  autoFocus?: boolean;
}) {
  const input = useRef<HTMLInputElement>(null);
  const [open, setOpen] = useState(false);
  const [cursor, setCursor] = useState(0);
  const catalog = useCatalog();
  const scope = useScope();

  useEffect(() => {
    const onKey = (event: globalThis.KeyboardEvent) => {
      const target = event.target as HTMLElement | null;
      if (event.key === "/" && target?.tagName !== "INPUT" && target?.tagName !== "TEXTAREA" && !event.metaKey && !event.ctrlKey) {
        event.preventDefault();
        input.current?.focus();
      }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);

  // The token under the caret: what completion is about.
  const token = useMemo(() => {
    const start = value.lastIndexOf(" ") + 1;
    return { start, text: value.slice(start) };
  }, [value]);
  const colon = token.text.indexOf(":");
  const key = colon >= 0 ? token.text.slice(0, colon).replace(/^-/, "") : null;
  const prefix = colon >= 0 ? token.text.slice(colon + 1).replace(/^"/, "") : token.text;
  const debouncedPrefix = useDebouncedValue(prefix, 150);

  const bounds = roundRange(scope.range);
  const values = useQuery({
    queryKey: keys.query.values(source, key ?? "", bounds.from, bounds.to, "", debouncedPrefix, metric ?? ""),
    queryFn: () =>
      api.get<FacetValue[]>(
        `/query/values?source=${source}&key=${encodeURIComponent(key ?? "")}&from=${bounds.from}&to=${bounds.to}&q=${encodeURIComponent(debouncedPrefix)}${metric ? `&metric=${encodeURIComponent(metric)}` : ""}`,
      ),
    enabled: open && key !== null && key !== "" && !key.startsWith("@") && !/^[<>]/.test(prefix),
    staleTime: 30_000,
  });

  const suggestions = useMemo(() => {
    if (key !== null) {
      return (values.data ?? []).map((facet) => ({ text: `${token.text.slice(0, colon + 1)}${quote(String(facet.value ?? ""))}`, label: String(facet.value ?? "(none)"), hint: facet.count === null ? "" : String(Math.round(facet.count)) }));
    }
    const fields =
      source === "metrics"
        ? ["app", ...(catalog.data?.metrics.find((entry) => entry.name === metric)?.tags ?? [])].map((name) => ({ name, label: name }))
        : fieldsInScope(catalog.data, source, value).map((field) => ({ name: field.name, label: field.label }));
    const needle = prefix.replace(/^-/, "").toLowerCase();
    return fields
      .filter((field) => field.name.toLowerCase().startsWith(needle))
      .slice(0, 10)
      .map((field) => ({ text: `${prefix.startsWith("-") ? "-" : ""}${field.name}:`, label: field.name, hint: field.label }));
  }, [key, values.data, token.text, colon, source, catalog.data, metric, prefix, value]);

  useEffect(() => setCursor(0), [suggestions.length, value]);

  const accept = (text: string) => {
    const next = `${value.slice(0, token.start)}${text}${text.endsWith(":") ? "" : " "}`;
    onChange(next);
    if (!text.endsWith(":")) setOpen(false);
    input.current?.focus();
  };

  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (open && suggestions.length > 0) {
      if (event.key === "ArrowDown") {
        event.preventDefault();
        setCursor((current) => Math.min(current + 1, suggestions.length - 1));
        return;
      }
      if (event.key === "ArrowUp") {
        event.preventDefault();
        setCursor((current) => Math.max(current - 1, 0));
        return;
      }
      if (event.key === "Tab" || (event.key === "Enter" && token.text !== "" && !token.text.endsWith(" "))) {
        const chosen = suggestions[cursor];
        if (chosen && (event.key === "Tab" || chosen.text !== token.text)) {
          event.preventDefault();
          accept(chosen.text);
          return;
        }
      }
    }
    if (event.key === "Enter") {
      setOpen(false);
      onSubmit(value);
    } else if (event.key === "Escape") {
      setOpen(false);
      input.current?.blur();
    }
  };

  return (
    <div className={cn("relative", className)}>
      <div className="flex h-9 items-center gap-2 rounded-[var(--radius-control)] border border-border bg-input px-2.5 focus-within:border-primary/60">
        <Search className="h-4 w-4 shrink-0 text-muted" aria-hidden />
        <input
          ref={input}
          value={value}
          onChange={(event) => {
            onChange(event.target.value);
            setOpen(true);
          }}
          onFocus={() => setOpen(true)}
          onBlur={() => window.setTimeout(() => setOpen(false), 150)}
          onKeyDown={onKeyDown}
          placeholder={placeholder}
          aria-label="Filter"
          autoFocus={autoFocus}
          spellCheck={false}
          autoComplete="off"
          className="min-w-0 flex-1 bg-transparent font-mono text-[13px] text-foreground outline-none placeholder:text-muted/70"
        />
        <kbd className="hidden rounded border border-border px-1 text-[10px] text-muted sm:inline">/</kbd>
      </div>
      {open && suggestions.length > 0 ? (
        <ul className="absolute left-0 right-0 top-10 z-30 max-h-64 overflow-y-auto rounded-[var(--radius-card)] border border-border bg-surface py-1 shadow-xl" role="listbox">
          {suggestions.map((suggestion, index) => (
            <li key={suggestion.text} role="option" aria-selected={index === cursor}>
              <button
                type="button"
                onMouseDown={(event) => event.preventDefault()}
                onClick={() => accept(suggestion.text)}
                onMouseEnter={() => setCursor(index)}
                className={cn("flex w-full items-center justify-between gap-3 px-3 py-1 text-left font-mono text-xs", index === cursor ? "bg-primary/10 text-foreground" : "text-foreground/90")}
              >
                <span className="truncate">{suggestion.label}</span>
                <span className="shrink-0 text-muted">{suggestion.hint}</span>
              </button>
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}

function quote(value: string): string {
  return /[\s"]/.test(value) ? `"${value.replaceAll('"', '\\"')}"` : value;
}
