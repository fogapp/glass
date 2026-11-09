import { useMemo } from "react";
import { PageBody } from "@/components/layout/PageBody";
import { Panel, QueryBody } from "@/components/charts/Panel";
import { Timeseries } from "@/components/charts/Timeseries";
import { QueryBar } from "@/components/telemetry/QueryBar";
import { CursorPager } from "@/components/telemetry/CursorPager";
import { useCursor } from "@/hooks/useCursor";
import { useFilterParam } from "@/hooks/useFilterParam";
import { useSearchParamState } from "@/hooks/useSearchParamState";
import { listRows } from "@/lib/listRows";
import { LogLines } from "@/components/telemetry/LogLines";
import { useApps } from "@/hooks/useApps";
import { useGlassQuery } from "@/lib/glassQuery";
import { useScope, withScope } from "@/lib/scope";
import { absoluteRange } from "@/lib/timeRange";
import { levelClass } from "@/lib/logLevels";
import { cn } from "@/lib/cn";
import type { ListResult, LogRow, TimeseriesResult } from "@/types";

const LEVELS = ["debug", "info", "warn", "error", "fatal"] as const;
type Level = (typeof LEVELS)[number];
/** Debug is left out until asked for. */
const DEFAULT_LEVELS: readonly Level[] = ["info", "warn", "error", "fatal"];
const parseLevels = (raw: string): readonly Level[] => LEVELS.filter((level) => raw.split(",").includes(level));
const serializeLevels = (levels: readonly Level[]) => levels.join(",");

/**
 * Logs: a volume histogram by level, then the lines, newest first, each
 * carrying the trace it was written under. Live follows the clock.
 */
export function Logs() {
  const scope = useScope();
  const apps = useApps();
  const { filter: filterParam, draft, setDraft, apply } = useFilterParam("q");
  const [levelList, setLevelList] = useSearchParamState<readonly Level[]>("levels", { parse: parseLevels, fallback: DEFAULT_LEVELS, serialize: serializeLevels });
  const levels = useMemo(() => new Set<string>(levelList), [levelList]);
  const toggleLevel = (level: Level) => {
    const next = LEVELS.filter((each) => (each === level ? !levels.has(each) : levels.has(each)));
    // Back at the default, the param goes.
    setLevelList(serializeLevels(next) === serializeLevels(DEFAULT_LEVELS) ? DEFAULT_LEVELS : next);
  };

  const levelTerm = levels.size === LEVELS.length || levels.size === 0 ? "" : `level:${Array.from(levels).join(",")}`;
  const filter = withScope(scope, filterParam, levelTerm);
  const { before, setBefore } = useCursor(`${filter}|${scope.range.from}|${scope.range.to}`);

  const volume = useGlassQuery<TimeseriesResult>(
    { source: "logs", shape: "timeseries", from: scope.range.from, to: scope.range.to, filter, compute: ["count"], group_by: ["level"], limit: 5 },
    { live: scope.live },
  );
  const lines = useGlassQuery<ListResult>(
    { source: "logs", shape: "list", from: scope.range.from, to: scope.range.to, filter, limit: 200, before: before ?? undefined },
    { live: scope.live && before === null },
  );
  const rows = useMemo(() => listRows<LogRow>(lines.data), [lines.data]);

  return (
    <PageBody className="space-y-3 py-4">
      <div className="flex flex-wrap items-center gap-2">
        <QueryBar value={draft} onChange={setDraft} onSubmit={apply} source="logs" className="min-w-64 flex-1" placeholder='app:hook "timeout" source:event trace:…' />
        <div className="flex items-center gap-1" role="group" aria-label="Levels">
          {LEVELS.map((level) => (
            <button
              key={level}
              type="button"
              aria-pressed={levels.has(level)}
              onClick={() => toggleLevel(level)}
              className={cn(
                "h-7 rounded-[var(--radius-control)] border px-2 font-mono text-[11px] uppercase",
                levels.has(level) ? levelClass(level, true) : "border-border text-muted",
              )}
            >
              {level}
            </button>
          ))}
        </div>
      </div>
      <Panel title="Volume" subtitle="lines per bucket, by level">
        <QueryBody query={volume} height={100} isEmpty={(data) => data.series.length === 0}>
          {(data) => <Timeseries result={data} height={100} stacked onBrush={(from, to) => scope.setRange(absoluteRange(from, to))} />}
        </QueryBody>
      </Panel>
      <Panel title={before ? "Earlier" : scope.live ? "Live tail" : "Newest first"} bodyClassName="p-0">
        <QueryBody query={lines} height={300} isEmpty={(data) => data.rows.length === 0}>
          {(data) => (
            <>
              <LogLines rows={rows} apps={apps.data} />
              <CursorPager before={before} next={data.next_before} onChange={setBefore} className="px-2 py-2" />
            </>
          )}
        </QueryBody>
      </Panel>
    </PageBody>
  );
}
