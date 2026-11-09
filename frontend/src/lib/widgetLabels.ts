import { isQueryError } from "@/lib/glassQuery";
import type { LabelPart, QueryAnswer, QueryWidget } from "@/types";

/** What each part of a chart's label is called where it's picked. */
export const LABEL_PART_NAMES: Record<LabelPart, string> = {
  source: "Source",
  metric: "Metric",
  compute: "Measure",
  group_by: "Grouping",
  apps: "Apps",
  filter: "Filter",
};

/**
 * One part of a chart's label as its query says it now — nil when the
 * query has nothing to say there. Apps come from the answer (which apps the
 * filter, scope included, left it), so they wait for it.
 */
export function labelPart(widget: Pick<QueryWidget, "spec">, part: LabelPart, answer?: QueryAnswer): string | null {
  const { spec } = widget;
  switch (part) {
    case "source":
      return spec.source.replace(/_/g, " ");
    case "metric":
      return spec.metric || null;
    case "compute":
      return spec.compute?.length ? spec.compute.join(", ") : spec.source === "metrics" ? null : "count";
    case "group_by":
      return spec.group_by?.length ? `by ${spec.group_by.join(", ")}` : null;
    case "apps":
      if (!answer || isQueryError(answer)) return null;
      if (!answer.apps) return "All apps";
      return answer.apps.length ? answer.apps.join(", ") : "No apps";
    case "filter":
      return spec.filter?.trim() || null;
  }
}

function joined(widget: QueryWidget, parts: LabelPart[], answer?: QueryAnswer): string {
  return parts
    .map((part) => labelPart(widget, part, answer))
    .filter(Boolean)
    .join(" · ");
}

/**
 * A chart's header and subheader: its own text where it has some, else the
 * parts it names, read from its query. A header with nothing to say falls
 * back to the source, so no chart is unnamed.
 */
export function widgetLabels(widget: QueryWidget, answer?: QueryAnswer): { title: string; subtitle: string } {
  return {
    title: widget.title.trim() || joined(widget, widget.title_parts, answer) || labelPart(widget, "source")!,
    subtitle: widget.subtitle.trim() || joined(widget, widget.subtitle_parts, answer),
  };
}
