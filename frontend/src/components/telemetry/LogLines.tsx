import { useState } from "react";
import { AppDot } from "@/components/scope/AppDot";
import { ScopedLink } from "@/components/scope/ScopedLink";
import { formatClock } from "@/lib/format";
import { levelClass } from "@/lib/logLevels";
import { cn } from "@/lib/cn";
import type { App, LogRow } from "@/types";

/**
 * Log lines, newest first: when, level, app, message. A line opens in
 * place to show where it came from and the trace it was written under.
 */
export function LogLines({ rows, apps }: { rows: LogRow[]; apps: App[] | undefined }) {
  const [expanded, setExpanded] = useState<number | null>(null);
  return (
    <ul className="divide-y divide-border/70 font-mono text-xs">
      {rows.map((line, index) => (
        <li key={index}>
          <button
            type="button"
            onClick={() => setExpanded(expanded === index ? null : index)}
            className={cn("flex w-full items-start gap-2 px-2 py-1 text-left hover:bg-surface-raised", expanded === index && "bg-surface-raised")}
          >
            <span className="tabular w-24 shrink-0 whitespace-nowrap text-muted">{formatClock(line.ts)}</span>
            <span className={cn("w-11 shrink-0 uppercase", levelClass(line.level, false))}>{line.level}</span>
            <span className="flex w-16 shrink-0 items-center gap-1 truncate text-muted">
              <AppDot app={apps?.find((app) => app.slug === line.app)} />
              {line.app}
            </span>
            <span className={cn("min-w-0 flex-1 break-words text-foreground", expanded !== index && "line-clamp-2")}>{line.message}</span>
          </button>
          {expanded === index ? (
            <div className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5 border-t border-border/60 bg-surface-raised/50 px-3 py-2 text-[11px]">
              <span className="text-muted">source</span>
              <span className="text-foreground">{line.source}</span>
              <span className="text-muted">process</span>
              <span className="text-foreground">
                {line.process}
                {line.host ? ` @ ${line.host}` : ""}
              </span>
              <span className="text-muted">release</span>
              <span className="text-foreground">{line.release ?? "—"}</span>
              <span className="text-muted">trace</span>
              <span className="text-foreground">
                {line.trace ? (
                  <ScopedLink to={`/traces/${line.trace}`} className="text-primary hover:underline">
                    {line.trace}
                  </ScopedLink>
                ) : (
                  "—"
                )}
              </span>
              {Object.entries(line.attrs ?? {}).map(([key, value]) => (
                <span key={key} className="contents">
                  <span className="text-muted">@{key}</span>
                  <span className="break-all text-foreground">{String(value)}</span>
                </span>
              ))}
            </div>
          ) : null}
        </li>
      ))}
    </ul>
  );
}
