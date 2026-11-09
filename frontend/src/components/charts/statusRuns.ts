export type Status = "up" | "down" | "unknown";

/** A run of consecutive buckets in the same state. */
export interface StatusRun {
  status: Status;
  from: number;
  to: number;
  /** Seconds of the run that were down — less than its width when a bucket was only partly down. */
  downSeconds: number;
}

/**
 * Buckets of a 0/1 gauge as runs: a bucket is up only if its lowest reading
 * was 1, down if any reading was not, and unknown if nothing was read. A
 * bucket's mean says how much of it was down, so a forty-minute outage on a
 * chart of hour-wide buckets is still forty minutes.
 */
export function statusRuns(times: number[], step: number, lows: (number | null)[], means: (number | null)[] = []): StatusRun[] {
  const runs: StatusRun[] = [];
  times.forEach((time, index) => {
    const low = lows[index];
    const status: Status = low === null || low === undefined ? "unknown" : low >= 1 ? "up" : "down";
    const downSeconds = status === "down" ? (1 - Math.min(Math.max(means[index] ?? 0, 0), 1)) * step : 0;
    const last = runs[runs.length - 1];
    if (last && last.status === status) {
      last.to = time + step;
      last.downSeconds += downSeconds;
    } else {
      runs.push({ status, from: time, to: time + step, downSeconds });
    }
  });
  return runs;
}
