import type { App, Series } from "@/types";
import type { ChartTheme } from "@/components/charts/theme";
import { slotColor } from "@/components/charts/theme";

/**
 * Which color a series wears. Color follows the entity, never its rank
 * (dataviz rule): a series grouped by app wears that app's lifelong slot,
 * so hook is the same blue on every chart in the console; anything else
 * takes slots in the order the query answered, which the server keeps
 * stable by ranking.
 */
export function seriesColor(theme: ChartTheme, series: Series, index: number, apps: App[] | undefined): string {
  const slug = series.group.app;
  if (typeof slug === "string") {
    const app = apps?.find((candidate) => candidate.slug === slug);
    if (app) return slotColor(theme, app.color_slot - 1);
  }
  return slotColor(theme, index);
}

/** What a series is called in a legend: its group values, else its compute. */
export function seriesLabel(series: Series): string {
  const parts = Object.values(series.group).map((value) => (value === null || value === "" ? "(none)" : String(value)));
  return parts.length > 0 ? parts.join(" · ") : series.key;
}
