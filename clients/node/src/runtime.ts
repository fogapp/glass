import { monitorEventLoopDelay, PerformanceObserver, type IntervalHistogram } from "node:perf_hooks";
import type { Aggregator } from "./aggregator.ts";

/**
 * The process's own vitals, sampled once per flush window. The one that
 * matters most for a Node process is event-loop delay: everything in it
 * shares one thread, so a synchronous database call or a long loop makes
 * every request and every stream wait, and nothing else measures that. It is
 * to Node what waiting for the GVL is to Ruby.
 */
export class Runtime {
  private delay: IntervalHistogram | null = null;
  private gc: PerformanceObserver | null = null;
  private gcCount = 0;
  private gcMs = 0;
  private cpu = process.cpuUsage();
  private readonly aggregator: Aggregator;
  private readonly tags: Record<string, string>;

  constructor(aggregator: Aggregator, processKind: string) {
    this.aggregator = aggregator;
    this.tags = { process: processKind };
  }

  start(): void {
    if (this.delay) return;
    this.delay = monitorEventLoopDelay({ resolution: 20 });
    this.delay.enable();
    try {
      this.gc = new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          this.gcCount += 1;
          this.gcMs += entry.duration;
        }
      });
      this.gc.observe({ entryTypes: ["gc"] });
    } catch {
      this.gc = null; // a runtime without GC entries still has everything else
    }
  }

  stop(): void {
    this.delay?.disable();
    this.delay = null;
    this.gc?.disconnect();
    this.gc = null;
  }

  /** One window's worth, into the aggregator. Called before each flush. */
  sample(): void {
    const { aggregator: agg, tags } = this;
    if (this.delay) {
      // Nanoseconds, measured against a 20 ms timer: what is over the resolution is delay.
      const over = (ns: number) => Math.max(ns / 1e6 - 20, 0);
      if (this.delay.count > 0) {
        agg.gauge("node.eventloop.delay_ms", over(this.delay.mean), tags, "ms");
        agg.gauge("node.eventloop.delay_p99_ms", over(this.delay.percentile(99)), tags, "ms");
        agg.gauge("node.eventloop.delay_max_ms", over(this.delay.max), tags, "ms");
      }
      this.delay.reset();
    }
    const memory = process.memoryUsage();
    agg.gauge("node.memory.rss_bytes", memory.rss, tags, "bytes");
    agg.gauge("node.heap.used_bytes", memory.heapUsed, tags, "bytes");
    agg.gauge("node.heap.total_bytes", memory.heapTotal, tags, "bytes");
    agg.gauge("node.memory.external_bytes", memory.external, tags, "bytes");

    const cpu = process.cpuUsage(this.cpu);
    this.cpu = process.cpuUsage();
    agg.counter("node.cpu.user_ms", cpu.user / 1000, tags, "ms");
    agg.counter("node.cpu.system_ms", cpu.system / 1000, tags, "ms");

    agg.counter("node.gc.count", this.gcCount, tags);
    agg.counter("node.gc.time_ms", this.gcMs, tags, "ms");
    this.gcCount = 0;
    this.gcMs = 0;

    agg.gauge("node.handles", process.getActiveResourcesInfo().length, tags);
    agg.gauge("node.uptime_s", process.uptime(), tags, "s");
  }
}
