import { describe, expect, it } from "vitest";
import { activeMs, linkFor, phaseParts, RUN_PHASES } from "@/lib/runs";
import type { App } from "@/types";

describe("a run's phases", () => {
  it("add up to the duration, with what nothing accounts for named", () => {
    const parts = phaseParts({ duration: 41_250, queue_ms: 800, prep: 300, model_ms: 9000, tool_ms: 6000, wait: 24_000, deliver: 400 });
    expect(parts.map((part) => [part.phase.key, part.value])).toEqual([
      ["queue", 800], ["prep", 300], ["model", 9000], ["tool", 6000], ["wait", 24_000], ["deliver", 400], ["untracked", 750],
    ]);
    expect(parts.reduce((sum, part) => sum + part.value, 0)).toBe(41_250);
    expect(activeMs({ duration: 41_250, wait: 24_000 })).toBe(17_250);
  });

  it("never count below nothing when phases overlap the duration", () => {
    expect(phaseParts({ duration: 100, queue_ms: null, prep: 0, model_ms: 90, tool_ms: 30, wait: 0, deliver: 0 }).at(-1)!.value).toBe(0);
  });

  it("each wear a slot of their own", () => {
    expect(new Set(RUN_PHASES.map((phase) => phase.slot)).size).toBe(RUN_PHASES.length);
  });
});

describe("the link into an app's own console", () => {
  const app = (link_template: string | null) => ({ link_template }) as App;

  it("fills the template from the row", () => {
    expect(linkFor(app("https://assistant.example.net/traces/{run}"), { attrs: { run: "run_01j9" } })).toBe("https://assistant.example.net/traces/run_01j9");
    expect(linkFor(app("https://assistant.example.net/s/{session}?t={trace}"), { session: "ses 1", trace: "abc" })).toBe("https://assistant.example.net/s/ses%201?t=abc");
  });

  it("is nothing without a template, or when the row lacks what the template names", () => {
    expect(linkFor(app(null), { attrs: { run: "x" } })).toBeNull();
    expect(linkFor(undefined, { attrs: { run: "x" } })).toBeNull();
    expect(linkFor(app("https://assistant.example.net/traces/{run}"), { attrs: {} })).toBeNull();
  });
});
