import { hostname } from "node:os";
import { promisify } from "node:util";
import { gzip } from "node:zlib";
import type { Aggregator } from "./aggregator.ts";
import { VERSION } from "./version.ts";

const gzipAsync = promisify(gzip);

/** The record types of glass-ingest/1, in the order a batch takes them: the cheap uniform rows first, the bulky optional ones last. */
export const TYPES = ["txn", "llm", "metric", "marker", "span", "log", "profile", "page"] as const;
export type RecordType = (typeof TYPES)[number];
export type WireRecord = { t: RecordType; ts: number } & Record<string, unknown>;

export interface SendResult {
  status: number;
  body: string;
  retryAfter: string | null;
}
/** Posts one gzipped NDJSON body. Replaced in tests. */
export type Sender = (body: Buffer, headers: Record<string, string>) => Promise<SendResult>;

/**
 * What the server says the app's agents should do, from every ingest reply.
 * Unknown keys are ignored — `trace_sample_rate` among them: it decides
 * which requests keep their spans, and this client sends spans only under a
 * run, which is never sampled.
 */
export interface Directives {
  profiling: boolean;
  profileHz: number;
  logLevel: "debug" | "info" | "warn" | "error" | "off";
  browser: boolean;
  identity: "anonymous" | "pseudonymous" | "named";
}

export interface TransportOptions {
  url: string;
  key: string;
  process: string;
  release: string | null;
  host?: string;
  runtime?: Record<string, string>;
  flushIntervalMs?: number;
  queueSize?: number;
  sender?: Sender;
  onError?: (where: string, error: unknown) => void;
  onDirectives?: (directives: Directives, profileNow: Record<string, unknown> | null) => void;
  /** Called before each flush: the place to sample gauges. */
  beforeFlush?: () => void;
  /** Milliseconds since the epoch; replaced in tests. */
  now?: () => number;
}

const DEFAULT_MAX_RECORDS = 10_000;
const MIN_MAX_RECORDS = 250;
const DEFAULT_MAX_BYTES = 16 * 1024 * 1024; // inflated; the server allows 32 MiB
const MIN_MAX_BYTES = 256 * 1024;
/** Accepted batches before a halved limit grows back one step. */
const RECOVER_AFTER = 6;
const LOG_LEVELS = ["debug", "info", "warn", "error", "off"] as const;
const IDENTITIES = ["anonymous", "pseudonymous", "named"] as const;

/**
 * One timer, bounded buffers, one POST per flush. The contract that makes this
 * safe inside any app (docs/ingest-protocol.md, "Rules for an agent"): a push
 * is an array append and never waits; overflow drops and counts; a failed send
 * drops the batch and is never retried; 429 pauses for Retry-After; 401 stops
 * for good; 413 halves the next batch. Nothing here throws into the app.
 */
export class Transport {
  readonly dropped: Record<RecordType, number> = { txn: 0, llm: 0, metric: 0, marker: 0, span: 0, log: 0, profile: 0, page: 0 };
  readonly directives: Directives = { profiling: true, profileHz: 100, logLevel: "info", browser: false, identity: "pseudonymous" };
  halted = false;
  maxRecords = DEFAULT_MAX_RECORDS;
  maxBytes = DEFAULT_MAX_BYTES;

  private readonly buffers: Record<RecordType, WireRecord[]> = { txn: [], llm: [], metric: [], marker: [], span: [], log: [], profile: [], page: [] };
  private readonly limits: Record<RecordType, number>;
  private readonly startedAt: number;
  private readonly now: () => number;
  private readonly sender: Sender;
  private timer: NodeJS.Timeout | null = null;
  private flushing: Promise<void> | null = null;
  private pauseUntil = 0;
  private acceptedStreak = 0;
  private readonly options: TransportOptions;
  private readonly aggregator: Aggregator;

  constructor(options: TransportOptions, aggregator: Aggregator) {
    this.options = options;
    this.aggregator = aggregator;
    const queue = options.queueSize ?? 5000;
    this.limits = { txn: queue, llm: queue * 2, metric: queue * 2, marker: 500, span: queue * 4, log: queue, profile: 8, page: queue };
    this.now = options.now ?? Date.now;
    this.startedAt = this.now() / 1000;
    this.sender = options.sender ?? httpSender(options.url);
  }

  /** Begin flushing on an interval. The timer never keeps the process alive. */
  start(): void {
    if (this.timer || this.halted) return;
    const interval = this.options.flushIntervalMs ?? 10_000;
    // The first flush is jittered so a fleet restarted together does not report in lockstep for ever.
    const first = setTimeout(() => {
      void this.flush();
      this.timer = setInterval(() => void this.flush(), interval);
      this.timer.unref();
    }, interval * (0.3 + Math.random() * 0.7));
    first.unref();
    this.timer = first;
  }

  stop(): void {
    if (this.timer) {
      clearTimeout(this.timer);
      clearInterval(this.timer);
    }
    this.timer = null;
  }

  push(record: WireRecord): void {
    if (this.halted) return;
    const buffer = this.buffers[record.t];
    if (buffer.length >= this.limits[record.t]) this.dropped[record.t] += 1;
    else buffer.push(record);
  }

  buffered(type: RecordType): number {
    return this.buffers[type].length;
  }

  /**
   * Send what is buffered. One flush at a time: a second call while one is in
   * flight waits for it rather than starting another, unless it is `final`,
   * which runs once that one is over. `final` also sends the metric window
   * still open. Never rejects.
   */
  flush(final = false): Promise<void> {
    // A final flush still runs after the one in flight: that one took neither the open metric window nor what was pushed since.
    if (this.flushing) return final ? this.flushing.then(() => this.flush(true)) : this.flushing;
    this.flushing = this.flushNow(final)
      .catch((error) => this.options.onError?.("flush", error))
      .finally(() => {
        this.flushing = null;
      });
    return this.flushing;
  }

  private async flushNow(final: boolean): Promise<void> {
    if (this.halted) return;
    try {
      this.options.beforeFlush?.();
    } catch (error) {
      this.options.onError?.("beforeFlush", error);
    }
    this.dropped.metric += this.aggregator.takeDropped();
    for (const metric of this.aggregator.drain(Math.floor(this.now() / 1000), final)) this.push(metric as unknown as WireRecord);

    if (this.now() < this.pauseUntil) {
      // A 429 pause: what arrived meanwhile is shed, and counted.
      for (const type of TYPES) {
        this.dropped[type] += this.buffers[type].length;
        this.buffers[type].length = 0;
      }
      return;
    }

    const { lines, counts } = this.takeBatch();
    // An idle process still says it is alive: a header alone is a heartbeat.
    const body = await gzipAsync(Buffer.from(`${JSON.stringify(this.header())}\n${lines.join("\n")}${lines.length ? "\n" : ""}`));
    await this.deliver(body, counts);
  }

  /** Up to maxRecords / maxBytes of what is buffered; what does not fit stays for the next flush. */
  private takeBatch(): { lines: string[]; counts: Partial<Record<RecordType, number>> } {
    const lines: string[] = [];
    const counts: Partial<Record<RecordType, number>> = {};
    let bytes = 0;
    for (const type of TYPES) {
      const buffer = this.buffers[type];
      let taken = 0;
      for (const record of buffer) {
        if (lines.length >= this.maxRecords) break;
        let line: string;
        try {
          line = JSON.stringify(record);
        } catch {
          this.dropped[type] += 1;
          taken += 1;
          continue;
        }
        const size = Buffer.byteLength(line);
        if (bytes + size > this.maxBytes) break;
        lines.push(line);
        bytes += size;
        counts[type] = (counts[type] ?? 0) + 1;
        taken += 1;
      }
      buffer.splice(0, taken);
    }
    return { lines, counts };
  }

  private header(): Record<string, unknown> {
    const process_: Record<string, unknown> = {
      kind: this.options.process,
      host: this.options.host ?? hostname(),
      pid: process.pid,
      started_at: this.startedAt,
      runtime: { node: process.versions.node, agent: VERSION, client: "glass-node", ...this.options.runtime },
    };
    if (this.options.release) process_.release = this.options.release;
    return { v: 1, process: process_, sent_at: this.now() / 1000, dropped: { ...this.dropped } };
  }

  /** The protocol's response table, exactly. */
  private async deliver(body: Buffer, counts: Partial<Record<RecordType, number>>): Promise<void> {
    const shed = () => {
      for (const [type, count] of Object.entries(counts)) this.dropped[type as RecordType] += count;
    };
    let result: SendResult;
    try {
      result = await this.sender(body, {
        "content-type": "application/x-ndjson",
        "content-encoding": "gzip",
        "user-agent": `glass-node/${VERSION}`,
        authorization: `Bearer ${this.options.key}`,
      });
    } catch (error) {
      // A dead server is not retried into: the batch is gone, and said so.
      shed();
      this.options.onError?.("send", error);
      return;
    }
    switch (result.status) {
      case 202:
        this.acceptedStreak += 1;
        if (this.acceptedStreak >= RECOVER_AFTER && (this.maxRecords < DEFAULT_MAX_RECORDS || this.maxBytes < DEFAULT_MAX_BYTES)) {
          this.acceptedStreak = 0;
          this.maxRecords = Math.min(this.maxRecords * 2, DEFAULT_MAX_RECORDS);
          this.maxBytes = Math.min(this.maxBytes * 2, DEFAULT_MAX_BYTES);
        }
        this.applyReply(result.body);
        return;
      case 401:
      case 403:
        // The key is unknown or revoked: nothing this process can do is useful until it restarts with another.
        this.halted = true;
        this.stop();
        shed();
        this.options.onError?.("send", new Error(`Glass refused the ingest key (${result.status}); reporting has stopped until this process restarts`));
        return;
      case 413:
        this.maxRecords = Math.max(Math.floor(this.maxRecords / 2), MIN_MAX_RECORDS);
        this.maxBytes = Math.max(Math.floor(this.maxBytes / 2), MIN_MAX_BYTES);
        this.acceptedStreak = 0;
        shed();
        return;
      case 429: {
        const seconds = Math.min(Math.max(Number.parseInt(result.retryAfter ?? "60", 10) || 60, 1), 300);
        this.pauseUntil = this.now() + seconds * 1000;
        shed();
        return;
      }
      default:
        // 400, 5xx, anything else: the batch is gone. Said, because a batch that vanishes quietly looks like nothing happened.
        shed();
        this.options.onError?.("send", new Error(`Glass answered ${result.status}; the batch was dropped`));
    }
  }

  private applyReply(body: string): void {
    let reply: unknown;
    try {
      reply = JSON.parse(body);
    } catch {
      return;
    }
    const raw = (reply as { directives?: unknown } | null)?.directives;
    if (!raw || typeof raw !== "object") return;
    const sent = raw as Record<string, unknown>;
    const d = this.directives;
    if (typeof sent.profiling === "boolean") d.profiling = sent.profiling;
    if (typeof sent.profile_hz === "number") d.profileHz = Math.min(Math.max(Math.round(sent.profile_hz), 10), 1000);
    if ((LOG_LEVELS as readonly unknown[]).includes(sent.log_level)) d.logLevel = sent.log_level as Directives["logLevel"];
    if (typeof sent.browser === "boolean") d.browser = sent.browser;
    if ((IDENTITIES as readonly unknown[]).includes(sent.identity)) d.identity = sent.identity as Directives["identity"];
    const now = sent.profile_now;
    try {
      this.options.onDirectives?.(d, now && typeof now === "object" && "id" in now ? (now as Record<string, unknown>) : null);
    } catch (error) {
      this.options.onError?.("directives", error);
    }
  }
}

/** A LAN hop to Glass: a short timeout, no retries, no pooling worth the code. */
function httpSender(url: string): Sender {
  const endpoint = `${url.replace(/\/+$/, "")}/ingest/v1/batch`;
  return async (body, headers) => {
    const response = await fetch(endpoint, { method: "POST", headers, body: new Uint8Array(body), signal: AbortSignal.timeout(8000) });
    return { status: response.status, body: await response.text(), retryAfter: response.headers.get("retry-after") };
  };
}
