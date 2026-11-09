import { describe, expect, it } from "vitest";
import { markersFor } from "@/lib/markers";
import type { Marker } from "@/types";

const marker = (app: string | null, ts = 150): Marker => ({ ts, app, kind: "deploy", title: `${app ?? "fleet"} deploy`, release: null, source: "test", attrs: {} });
const apps = (list: Marker[]) => list.map((each) => each.app);

describe("markersFor", () => {
  const markers = [marker("hook"), marker("feed"), marker(null), marker("hook", 900)];

  it("keeps the markers of the apps a chart's query read, and those of no app", () => {
    expect(apps(markersFor(markers, { from: 100, to: 200, apps: ["hook"] }))).toEqual(["hook", null]);
  });

  it("keeps every app's when the query read every app", () => {
    expect(apps(markersFor(markers, { from: 100, to: 200 }))).toEqual(["hook", "feed", null]);
  });

  it("keeps none of an app's when the query read no app", () => {
    expect(apps(markersFor(markers, { from: 100, to: 200, apps: [] }))).toEqual([null]);
  });
});
