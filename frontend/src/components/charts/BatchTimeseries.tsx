import { useCallback, useMemo } from "react";
import { QueryBody } from "@/components/charts/Panel";
import { Timeseries, type TimeseriesProps } from "@/components/charts/Timeseries";
import type { GlassBatch } from "@/lib/glassQuery";
import { useMarkers } from "@/lib/markers";
import { useScope } from "@/lib/scope";
import { absoluteRange } from "@/lib/timeRange";
import type { TimeseriesResult } from "@/types";

const noSeries = (result: TimeseriesResult) => result.series.length === 0;

/**
 * One answer of a page's batch as a chart, in a Panel's body: the batch's
 * three states (a failed query is never an empty chart), "no data" when the
 * answer has no series (or failed on its own — `<Failures>` says why), the
 * scope's marker lines, and brushing that asks the scope for the range.
 */
export function BatchTimeseries<K extends string>({
  batch,
  answer: key,
  height = 160,
  isEmpty = noSeries,
  select,
  markersFor,
  ...chart
}: {
  batch: GlassBatch<K>;
  /** Which answer of the batch: the spec's name. */
  answer: K;
  height?: number;
  /** When the answer counts as nothing to draw; by default, no series. */
  isEmpty?: (result: TimeseriesResult) => boolean;
  /** A reshaping of the answer (relabelled series); give a stable function, it is memoised on the answer. */
  select?: (result: TimeseriesResult) => TimeseriesResult;
  /** Whose deploys and incidents are drawn: an app's slug; by default the scope's app. */
  markersFor?: string | null;
} & Omit<TimeseriesProps, "result" | "height" | "markers" | "onBrush">) {
  const scope = useScope();
  const { setRange } = scope;
  const markers = useMarkers(scope.range, markersFor === undefined ? scope.app : markersFor, scope.live);
  const answer = batch.answer<TimeseriesResult>(key);
  const result = useMemo(() => (answer && select ? select(answer) : answer), [answer, select]);
  const brush = useCallback((from: number, to: number) => setRange(absoluteRange(from, to)), [setRange]);
  return (
    <QueryBody query={batch.batch} height={height} isEmpty={() => !result || isEmpty(result)}>
      {() => (result ? <Timeseries result={result} markers={markers.data} height={height} onBrush={brush} {...chart} /> : null)}
    </QueryBody>
  );
}
