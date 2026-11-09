/**
 * A DDSketch: counts in logarithmic buckets, with about 1% relative error on
 * any quantile. The mapping is fixed for the whole system and must match the
 * server's Telemetry::Sketch and the gem's Glass::Sketch exactly — sketches
 * merge by adding counts, so an index that is off by one skews every
 * percentile silently. The conformance kit (spec/fixtures/ingest/sketch.json)
 * pins it.
 *
 * Wire form: a flat integer array of alternating bucket index and count,
 * ascending by index. Values at or below MIN_VALUE have no bucket; they are
 * the series' `n` minus the sketch's total and read as zero.
 */
export class Sketch {
  static readonly GAMMA = 1.02;
  static readonly LOG_GAMMA = Math.log(1.02);
  static readonly MIN_VALUE = 1e-9;
  /** The server refuses a sketch past this many buckets; the lowest are folded up to stay under it. */
  static readonly MAX_BUCKETS = 2048;

  private readonly buckets = new Map<number, number>();
  /** Every value added, the unbucketed ones included. */
  count = 0;

  static indexFor(value: number): number | null {
    if (!(value > Sketch.MIN_VALUE)) return null;
    return Math.ceil(Math.log(value) / Sketch.LOG_GAMMA);
  }

  add(value: number): this {
    this.count += 1;
    const index = Sketch.indexFor(value);
    if (index !== null) this.buckets.set(index, (this.buckets.get(index) ?? 0) + 1);
    return this;
  }

  toPairs(): number[] {
    let keys = [...this.buckets.keys()].sort((a, b) => a - b);
    let folded = 0;
    if (keys.length > Sketch.MAX_BUCKETS) {
      // Fold the lowest buckets into the lowest kept one: the tail that matters for latency is the top.
      const keepFrom = keys.length - Sketch.MAX_BUCKETS;
      for (const key of keys.slice(0, keepFrom)) folded += this.buckets.get(key) ?? 0;
      keys = keys.slice(keepFrom);
    }
    const out: number[] = [];
    keys.forEach((key, position) => out.push(key, (this.buckets.get(key) ?? 0) + (position === 0 ? folded : 0)));
    return out;
  }
}
