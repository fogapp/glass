import { useMemo } from "react";
import { useNavigate } from "react-router-dom";
import { Panel, QueryBody } from "@/components/charts/Panel";
import { Timeseries } from "@/components/charts/Timeseries";
import { useExploreHref } from "@/lib/explore";
import { formatAgo, formatDateTime, formatPercent, formatUnit, shortSha } from "@/lib/format";
import { useGlassQuery } from "@/lib/glassQuery";
import { useMarkers } from "@/lib/markers";
import { ScopedLink } from "@/components/scope/ScopedLink";
import { absoluteRange } from "@/lib/timeRange";
import { cn } from "@/lib/cn";
import { levelTone } from "@/lib/logLevels";
import { Meter } from "@/components/ui/Meter";
import type { App, TimeseriesResult, TriageColumn, TriageEvidence } from "@/types";

/**
 * A finding's evidence, drawn without knowing its detector: a closed set of
 * shapes (a chart is a QuerySpec the console asks itself, the rest are rows)
 * — the same set `Triage::Brief` writes as Markdown for an agent.
 */
export function EvidenceBlock({ evidence, app, apps }: { evidence: TriageEvidence; app: string | null; apps: App[] | undefined }) {
  const body = (() => {
    switch (evidence.type) {
      case "chart":
        return evidence.query ? <EvidenceChart evidence={evidence} app={app} apps={apps} /> : null;
      case "table":
        return <EvidenceTable columns={evidence.columns} rows={evidence.rows} />;
      case "traces":
        return <TraceRows rows={evidence.rows} />;
      case "logs":
        return <LogRows rows={evidence.rows} />;
      case "functions":
        return <FunctionRows rows={evidence.rows} />;
      case "markers":
        return <MarkerRows rows={evidence.rows} />;
    }
  })();
  if (evidence.type === "chart") return body;
  return (
    <Panel title={evidence.title} subtitle={evidence.note ?? undefined} bodyClassName="p-0">
      {evidence.rows.length === 0 ? <p className="px-3 py-3 text-xs text-muted">Nothing in range.</p> : body}
    </Panel>
  );
}

/** A chart's series, one panel per unit — counts and percentages on one axis read as neither. */
function EvidenceChart({ evidence, app, apps }: { evidence: TriageEvidence; app: string | null; apps: App[] | undefined }) {
  const explore = useExploreHref();
  const spec = evidence.query!;
  const navigate = useNavigate();
  const query = useGlassQuery<TimeseriesResult>(spec);
  const markers = useMarkers(absoluteRange(spec.from, spec.to), app);
  // One result per unit, split once per answer: a fresh object each render would rebuild the chart.
  const byUnit = useMemo(() => {
    const data = query.data;
    if (!data) return [];
    const units = [...new Set(data.series.map((series) => series.unit ?? ""))];
    return units.map((unit) => ({ unit, result: { ...data, series: data.series.filter((series) => (series.unit ?? "") === unit) } }));
  }, [query.data]);
  return (
    <Panel title={evidence.title} subtitle={evidence.note ?? "the comparison window and the range together"}>
      <QueryBody query={query} height={140} isEmpty={(data) => data.series.every((series) => series.values.every((value) => value === null || value === 0))}>
        {() => (
          <div className={cn("grid gap-3", byUnit.length > 1 && "xl:grid-cols-2")}>
            {byUnit.map(({ unit, result }) => (
              <Timeseries
                key={unit}
                result={result}
                apps={apps}
                markers={markers.data}
                height={140}
                onPoint={(time, step) =>
                  navigate(explore({ source: spec.source, shape: "list", filter: spec.filter ?? "", metric: spec.metric ?? "" }, { range: `${Math.floor(time)}-${Math.ceil(time + step)}` }))
                }
              />
            ))}
          </div>
        )}
      </QueryBody>
    </Panel>
  );
}

function EvidenceTable({ columns, rows }: { columns: TriageColumn[]; rows: Record<string, unknown>[] }) {
  const numeric = (column: TriageColumn) => rows.some((row) => typeof row[column.key] === "number") && column.unit !== "time";
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-xs">
        <thead>
          <tr className="text-left text-[11px] uppercase tracking-wider text-muted">
            {columns.map((column) => (
              <th key={column.key} className={cn("whitespace-nowrap px-3 py-1.5 font-semibold", numeric(column) && "text-right")}>
                {column.label}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, index) => (
            <tr key={index} className="border-t border-border/60">
              {columns.map((column) => (
                <td key={column.key} className={cn("px-3 py-1.5 align-top", numeric(column) ? "tabular whitespace-nowrap text-right font-mono" : "break-words text-foreground", column.key === "resource" && "font-mono")}>
                  <Cell value={row[column.key]} unit={column.unit} />
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function Cell({ value, unit }: { value: unknown; unit: string | null }) {
  if (value === null || value === undefined || value === "") return <span className="text-muted">—</span>;
  switch (unit) {
    case "time":
      return <span className="whitespace-nowrap">{formatDateTime(Number(value))}</span>;
    case "trace":
      return (
        <ScopedLink to={`/traces/${String(value)}`} className="font-mono text-primary hover:underline">
          {String(value).slice(0, 8)}
        </ScopedLink>
      );
    case "sha":
      return <span className="font-mono">{shortSha(String(value))}</span>;
    default:
      return <>{typeof value === "number" ? formatUnit(value, unit) : String(value)}</>;
  }
}

function TraceRows({ rows }: { rows: Record<string, unknown>[] }) {
  return (
    <ul className="divide-y divide-border/60 text-xs">
      {rows.map((row, index) => {
        const what = [row.method, row.path].filter(Boolean).join(" ") || String(row.name ?? "");
        const failed = row.status === "error";
        return (
          <li key={`${String(row.trace)}-${index}`}>
            <ScopedLink to={`/traces/${String(row.trace)}`} className="flex flex-wrap items-baseline gap-x-3 gap-y-0.5 px-3 py-1.5 hover:bg-surface-raised">
              <span className="w-16 shrink-0 text-muted">{formatAgo(Number(row.ts))}</span>
              <span className="min-w-0 flex-1 break-all font-mono text-foreground">{what}</span>
              {row.http_status ? <span className={cn("tabular font-mono", failed ? "text-negative" : "text-muted")}>{String(row.http_status)}</span> : null}
              <span className="tabular w-16 text-right font-mono text-foreground">{formatUnit(Number(row.duration), "ms")}</span>
              {row.error ? <span className="w-full break-words pl-[4.75rem] text-negative">{String(row.error)}</span> : null}
            </ScopedLink>
          </li>
        );
      })}
    </ul>
  );
}

function LogRows({ rows }: { rows: Record<string, unknown>[] }) {
  return (
    <ul className="divide-y divide-border/60 text-xs">
      {rows.map((row, index) => (
        <li key={index} className="flex flex-wrap items-baseline gap-x-3 gap-y-0.5 px-3 py-1.5">
          <span className="w-16 shrink-0 text-muted">{formatAgo(Number(row.ts))}</span>
          <span className={cn("w-10 shrink-0 font-mono uppercase", levelTone(row.level))}>{String(row.level ?? "")}</span>
          <span className="min-w-0 flex-1 break-words font-mono text-foreground">{String(row.message ?? "")}</span>
          {row.trace ? (
            <ScopedLink to={`/traces/${String(row.trace)}`} className="font-mono text-primary hover:underline">
              {String(row.trace).slice(0, 8)}
            </ScopedLink>
          ) : null}
        </li>
      ))}
    </ul>
  );
}

function FunctionRows({ rows }: { rows: Record<string, unknown>[] }) {
  return (
    <ul className="divide-y divide-border/60 text-xs">
      {rows.map((row, index) => {
        const share = Number(row.self_share ?? 0);
        const before = row.before_share === undefined ? null : Number(row.before_share);
        const line = Number(row.line ?? 0);
        return (
          <li key={index} className="px-3 py-1.5">
            <div className="flex items-baseline gap-3">
              <span className="min-w-0 flex-1 break-all font-mono text-foreground">{String(row.name)}</span>
              <span className="tabular font-mono text-foreground">{formatPercent(share)}</span>
              <span className="tabular w-20 text-right font-mono text-muted" title="Share of self time before">
                {before === null ? "new" : `was ${formatPercent(before)}`}
              </span>
            </div>
            <div className="mt-1 flex items-center gap-3">
              <span className="min-w-0 flex-1 truncate text-muted">{row.file ? `${String(row.file)}${line > 0 ? `:${line}` : ""}` : ""}</span>
              <Meter value={share} className="h-1 w-24" />
            </div>
          </li>
        );
      })}
    </ul>
  );
}

function MarkerRows({ rows }: { rows: Record<string, unknown>[] }) {
  return (
    <ul className="divide-y divide-border/60 text-xs">
      {rows.map((row, index) => (
        <li key={index} className="flex flex-wrap items-baseline gap-x-3 px-3 py-1.5">
          <span className="w-36 shrink-0 text-muted">{formatDateTime(Number(row.ts))}</span>
          <span className="w-14 shrink-0 text-muted">{String(row.kind)}</span>
          <span className="min-w-0 flex-1 break-words text-foreground">{String(row.title ?? "")}</span>
          {row.release ? <span className="font-mono text-muted">{shortSha(String(row.release))}</span> : null}
        </li>
      ))}
    </ul>
  );
}
