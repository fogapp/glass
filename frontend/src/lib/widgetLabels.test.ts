import { describe, expect, it } from "vitest";
import { labelPart, widgetLabels } from "@/lib/widgetLabels";
import type { QueryAnswer, QueryWidget } from "@/types";

const widget = (overrides: Partial<QueryWidget> = {}): QueryWidget => ({
  id: "w",
  kind: "query",
  title: "",
  subtitle: "",
  title_parts: ["metric", "compute", "group_by"],
  subtitle_parts: ["filter"],
  spec: { source: "transactions", compute: ["p95(duration)"], group_by: ["route"], filter: "status:error" },
  x: 0,
  y: 0,
  w: 4,
  h: 6,
  ...overrides,
});
const answer = (apps?: string[]) => ({ shape: "table", from: 0, to: 1, columns: [], rows: [], ...(apps ? { apps } : {}) }) as QueryAnswer;

describe("widgetLabels", () => {
  it("reads the parts it names from the query, skipping those with nothing to say", () => {
    expect(widgetLabels(widget())).toEqual({ title: "p95(duration) · by route", subtitle: "status:error" });
  });

  it("shows its own text instead, wherever it has some", () => {
    expect(widgetLabels(widget({ title: "Slow checkouts", subtitle: "  " }))).toEqual({ title: "Slow checkouts", subtitle: "status:error" });
  });

  it("names the apps the answer read, once it has arrived", () => {
    const apps = widget({ subtitle_parts: ["apps", "filter"] });
    expect(widgetLabels(apps).subtitle).toBe("status:error");
    expect(widgetLabels(apps, answer(["hook", "hub"])).subtitle).toBe("hook, hub · status:error");
    expect(widgetLabels(apps, answer()).subtitle).toBe("All apps · status:error");
  });

  it("falls back to the source when its header has nothing to say", () => {
    expect(widgetLabels(widget({ title_parts: [] })).title).toBe("transactions");
    expect(widgetLabels(widget({ title_parts: ["metric"], spec: { source: "page_events" } })).title).toBe("page events");
  });

  it("counts by default, except for a metric, which has no count of its own", () => {
    expect(labelPart(widget({ spec: { source: "logs" } }), "compute")).toBe("count");
    expect(labelPart(widget({ spec: { source: "metrics", metric: "rss" } }), "compute")).toBeNull();
  });
});
