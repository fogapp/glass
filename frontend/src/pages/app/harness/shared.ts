import { num } from "@/lib/format";
import { phaseColor, RUN_PHASES } from "@/lib/runs";
import type { TimeseriesResult } from "@/types";

/** What a harness's tabs share: a run's phases as a bar or a stacked chart. (The figure style is `lib/ranked`.) */

/** A run's phases as the parts of a bar, from a row of `avg(<phase>)` figures. */
export function phasesOf(row: Record<string, unknown> | undefined) {
  return RUN_PHASES.map((phase) => ({ key: phase.key, label: phase.label, value: num(row?.[`avg(${phase.field})`]), color: phaseColor(phase), hatched: phase.hatched }));
}


/** A ratio with nothing metered under it in range: every bucket empty. */
export const noReadings = (result: TimeseriesResult) => result.series[0]?.values.every((value) => value === null) ?? true;

/** The slot each phase wears, in the order the phase computes are asked for. */
export const PHASE_SLOTS = RUN_PHASES.map((phase) => phase.slot);

/** A stacked phase chart's legend reads in words, not in `avg(model_ms)`. */
export function relabel(result: TimeseriesResult): TimeseriesResult {
  return { ...result, series: result.series.map((series, index) => ({ ...series, key: RUN_PHASES[index]?.label ?? series.key })) };
}
