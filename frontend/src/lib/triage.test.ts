import { describe, expect, it } from "vitest";
import { TRIAGE_KINDS, type TriageFinding } from "@/types";
import { baselineText, countBy, dismissalText, kindsPresent, rowsHref, TRIAGE_KIND_LABELS } from "./triage";

const finding = (kind: TriageFinding["kind"], severity: TriageFinding["severity"]): TriageFinding => ({
  id: `${kind}-${severity}`,
  kind,
  severity,
  score: 50,
  app: "hook",
  work: "request",
  name: "Wants#index",
  title: "t",
  summary: "s",
  figures: {},
  dismissal: null,
});

describe("triage", () => {
  it("names every kind the backend has", () => {
    expect(Object.keys(TRIAGE_KIND_LABELS)).toEqual([...TRIAGE_KINDS]);
  });

  it("counts and orders kinds the way the legend does", () => {
    const findings = [finding("vitals", "notice"), finding("failing", "critical"), finding("failing", "warning")];
    expect(kindsPresent(findings)).toEqual(["failing", "vitals"]);
    expect(countBy(findings, (row) => row.severity).get("critical")).toBe(1);
    expect(countBy(findings, (row) => row.kind).get("failing")).toBe(2);
  });

  it("links to the rows over the range they were found in", () => {
    const href = rowsHref({ source: "transactions", filter: 'app:hook name:"Wants#index"', from: 100.4, to: 200.2 });
    const params = new URLSearchParams(href.split("?")[1]);
    expect(href.startsWith("/explore?")).toBe(true);
    expect(params.get("shape")).toBe("list");
    expect(params.get("filter")).toBe('app:hook name:"Wants#index"');
    expect(params.get("range")).toBe("100-201");
  });

  it("says how long the comparison window is", () => {
    expect(baselineText({ from: 86_400 * 5, baseline_from: 86_400 })).toBe("4 days");
    expect(baselineText({ from: 7_200, baseline_from: 0 })).toBe("2 hours");
    expect(baselineText({ from: 86_400, baseline_from: 0 })).toBe("day");
  });

  it("says where a dismissal leaves a finding", () => {
    const now = 1_000_000;
    const dismissed = { mode: "dismissed" as const, score: 52.4, severity: "warning" as const, at: now - 3 * 3600, by: "Ada", regressed: false, returns_above: 62.4 };
    expect(dismissalText(dismissed, now)).toMatch(/^Dismissed by Ada .+ at 52 \(Warning\) — it comes back at 62 or more, or once it is critical\.$/);
    expect(dismissalText({ ...dismissed, severity: "critical" }, now)).toMatch(/comes back at 62 or more\.$/);
    expect(dismissalText({ ...dismissed, regressed: true }, now)).toMatch(/it is worse now, so it is back\.$/);
    expect(dismissalText({ ...dismissed, mode: "ignored", by: null, returns_above: null }, now)).toMatch(/^Ignored .+ — it stays out of the list, whatever it does\.$/);
  });
});
