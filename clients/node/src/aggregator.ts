import { Sketch } from "./sketch.ts";

export type Tags = Record<string, string | number | boolean | null | undefined>;
export type MetricKind = "counter" | "gauge" | "dist" | "set";

export interface MetricRecord {
  t: "metric";
  ts: number;
  name: string;
  kind: MetricKind;
  unit?: string;
  tags?: Record<string, string>;
  n: number;
  sum?: number;
  min?: number;
  max?: number;
  last?: number;
  sk?: number[];
}

interface Series {
  name: string;
  kind: MetricKind;
  unit: string | null;
  tags: Record<string, string>;
  n: number;
  sum: number;
  min: number | null;
  max: number | null;
  last: number | null;
  sketch: Sketch | null;
  members: Set<string> | null;
}

const NAME_FORMAT = /^[a-zA-Z][a-zA-Z0-9_.:-]{0,119}$/;

/**
 * In-process metric aggregation, as the gem does it: every call lands in the
 * series for its (name, kind, sorted tags) inside the ten-second wall-clock
 * window it happened in, and each closed window's series becomes one `metric`
 * record at flush (docs/ingest-protocol.md).
 */
export class Aggregator {
  static readonly WINDOW = 10;
  static readonly MAX_TAGS = 20;
  static readonly MAX_TAG_VALUE = 200;
  static readonly MAX_SET_MEMBERS = 10_000;

  private readonly windows = new Map<number, Map<string, Series>>();
  private dropped = 0;
  private readonly maxSeries: number;
  private readonly now: () => number;

  /** `now` answers epoch milliseconds; replaced in tests. */
  constructor(maxSeries = 5000, now: () => number = Date.now) {
    this.maxSeries = maxSeries;
    this.now = now;
  }

  counter(name: string, by = 1, tags?: Tags, unit?: string, nowSeconds?: number): void {
    this.add("counter", name, by, tags, unit, nowSeconds);
  }
  gauge(name: string, value: number, tags?: Tags, unit?: string, nowSeconds?: number): void {
    this.add("gauge", name, value, tags, unit, nowSeconds);
  }
  dist(name: string, value: number, tags?: Tags, unit?: string, nowSeconds?: number): void {
    this.add("dist", name, value, tags, unit, nowSeconds);
  }
  set(name: string, member: string | number, tags?: Tags, nowSeconds?: number): void {
    this.add("set", name, String(member), tags, undefined, nowSeconds);
  }

  /** Records for every window that has closed by `nowSeconds` — every window when `force`, for the last flush. */
  drain(nowSeconds: number, force = false): MetricRecord[] {
    const out: MetricRecord[] = [];
    for (const start of [...this.windows.keys()].sort((a, b) => a - b)) {
      if (!force && start + Aggregator.WINDOW > nowSeconds) continue;
      for (const series of this.windows.get(start)?.values() ?? []) out.push(record(start, series));
      this.windows.delete(start);
    }
    return out;
  }

  /** What was shed since the last call. */
  takeDropped(): number {
    const count = this.dropped;
    this.dropped = 0;
    return count;
  }

  private add(kind: MetricKind, name: string, value: number | string, tags: Tags | undefined, unit: string | undefined, nowSeconds: number | undefined): void {
    if (kind !== "set" && !(typeof value === "number" && Number.isFinite(value))) return;
    const clean = normalizeTags(tags);
    let key = `${kind}\0${name}`;
    for (const [tag, text] of Object.entries(clean)) key += `\0${tag}=${text}`;
    const now = nowSeconds ?? Math.floor(this.now() / 1000);
    const start = now - (now % Aggregator.WINDOW);
    let window = this.windows.get(start);
    if (!window) this.windows.set(start, (window = new Map()));
    let series = window.get(key);
    if (!series) {
      if (window.size >= this.maxSeries || !NAME_FORMAT.test(name)) {
        this.dropped += 1;
        return;
      }
      series = { name, kind, unit: unit ?? null, tags: clean, n: 0, sum: 0, min: null, max: null, last: null, sketch: kind === "dist" ? new Sketch() : null, members: kind === "set" ? new Set() : null };
      window.set(key, series);
    }
    if (kind === "set") {
      const members = series.members!;
      if (members.size < Aggregator.MAX_SET_MEMBERS || members.has(String(value))) members.add(String(value));
      return;
    }
    const number = value as number;
    series.n += 1;
    series.sum += number;
    if (kind === "counter") return;
    series.min = series.min === null ? number : Math.min(series.min, number);
    series.max = series.max === null ? number : Math.max(series.max, number);
    series.last = number;
    series.sketch?.add(number);
  }
}

/** Tags as string → string, sorted by key, bounded in number and length. A null value drops the tag, not the call. */
function normalizeTags(tags: Tags | undefined): Record<string, string> {
  if (!tags) return {};
  const pairs: [string, string][] = [];
  for (const [key, value] of Object.entries(tags)) {
    if (value === null || value === undefined) continue;
    pairs.push([key, String(value).slice(0, Aggregator.MAX_TAG_VALUE)]);
  }
  pairs.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  return Object.fromEntries(pairs.slice(0, Aggregator.MAX_TAGS));
}

function record(start: number, series: Series): MetricRecord {
  const out: MetricRecord = { t: "metric", ts: start, name: series.name, kind: series.kind, n: series.n };
  if (series.unit) out.unit = series.unit;
  if (Object.keys(series.tags).length > 0) out.tags = series.tags;
  if (series.kind === "set") {
    out.n = series.members?.size ?? 0;
    return out;
  }
  out.sum = series.sum;
  if (series.kind === "counter") return out;
  if (series.min !== null) out.min = series.min;
  if (series.max !== null) out.max = series.max;
  if (series.last !== null) out.last = series.last;
  if (series.sketch) out.sk = series.sketch.toPairs();
  return out;
}
