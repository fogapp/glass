import { describe, expect, it } from "vitest";
import { statusRuns } from "@/components/charts/statusRuns";

describe("statusRuns", () => {
  it("joins neighbouring buckets in the same state", () => {
    expect(statusRuns([0, 120, 240, 360, 480], 120, [1, 1, 0, 0.5, 1])).toEqual([
      { status: "up", from: 0, to: 240, downSeconds: 0 },
      { status: "down", from: 240, to: 480, downSeconds: 240 },
      { status: "up", from: 480, to: 600, downSeconds: 0 },
    ]);
  });

  it("measures an outage by the readings, not by the buckets it touched", () => {
    // Forty minutes down across three hour-wide buckets: 10 + 30 + 0.
    const [, down] = statusRuns([0, 3600, 7200, 10_800], 3600, [1, 0, 0, 1], [1, 5 / 6, 0.5, 1]);
    expect(down).toMatchObject({ status: "down", from: 3600, to: 10_800 });
    expect(down.downSeconds).toBeCloseTo(2400);
  });

  it("keeps a bucket nothing was read in apart from a down one", () => {
    expect(statusRuns([0, 120, 240], 120, [1, null, 0]).map((run) => run.status)).toEqual(["up", "unknown", "down"]);
  });

  it("treats a short answer as unread, and no buckets as no runs", () => {
    expect(statusRuns([0, 120], 120, [1]).map((run) => run.status)).toEqual(["up", "unknown"]);
    expect(statusRuns([], 120, [])).toEqual([]);
  });
});
