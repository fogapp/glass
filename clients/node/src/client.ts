import { AsyncLocalStorage } from "node:async_hooks";
import { Aggregator, type Tags } from "./aggregator.ts";
import type { IncomingMessage, ServerResponse } from "node:http";
import { BrowserRelay } from "./browser.ts";
import { captureOutbound } from "./http.ts";
import { captureInbound, type RequestContext } from "./inbound.ts";
import { captureConsole } from "./logs.ts";
import { Profiler } from "./profiler.ts";
import { Runtime } from "./runtime.ts";
import { cleanAttrs, emitModelCall, RunScope, type Attrs, type ModelCallInput, type RunOptions, type SpanKind } from "./run.ts";
import { Transport, type Directives, type Sender, type WireRecord } from "./transport.ts";

export interface GlassOptions {
  /** Where Glass is. Default: GLASS_URL. */
  url?: string;
  /** The app's ingest key (`glass_ing_…`). Default: GLASS_API_KEY. */
  key?: string;
  /** What kind of process this is: `gateway`, `worker`, any short label. */
  process?: string;
  /** The deployed revision. Default: GIT_SHA, then GIT_REV. */
  release?: string | null;
  host?: string;
  /** More to say about the runtime in the header, beside the Node and client versions. */
  runtime?: Record<string, string>;
  flushIntervalMs?: number;
  queueSize?: number;
  sender?: Sender;
  /** Told when instrumentation itself fails. It never throws into the app either way. */
  onError?: (where: string, error: unknown) => void;
  /** Sample gauges here: called once before each flush. */
  beforeFlush?: () => void;
  /**
   * Record every outbound `fetch` made under a run as an `http` span, and
   * continue the trace into hosts that are ours. Default on; `propagateTo`
   * names host suffixes that are ours beyond private addresses, bare
   * hostnames and `.lan`, `.local` and `.internal`.
   */
  outbound?: false | { propagateTo?: readonly string[] };
  /**
   * Record every request the process serves as a `request` transaction, and
   * make it the ambient context of what it sets going. Default on; `ignore`
   * replaces the default of health checks and static files.
   */
  inbound?: false | { ignore?: (path: string) => boolean };
  /** Sample the process's own vitals — event-loop delay, memory, GC, CPU — once per flush. Default on. */
  vitals?: boolean;
  /** Ship what the process writes with `console.*` as log records. Default off: an app turns it on when the console is its logger. */
  console?: boolean;
  /**
   * CPU profiles, from V8's own sampling profiler. `on-demand` (the default)
   * profiles only when Glass's console asks for one and costs nothing
   * otherwise; `continuous` profiles in back-to-back windows while the app's
   * `profiling` setting is on; `off` never does.
   */
  profiles?: "off" | "on-demand" | "continuous";
  /** The app's root, which app code in a profile is named relative to. Default: the working directory. */
  root?: string;
  /** How long one continuous profiling window is. Default: a minute. */
  profileWindowMs?: number;
  /**
   * For the browser relay: the trace a page's event belongs to, from what the
   * page said about it — an app whose pages know their own ids maps one here.
   */
  traceFor?: (props: Record<string, unknown>) => string | null;
  now?: () => number;
}

/** What answers `/_glass/` while nothing is reporting: an empty script, and beacons taken and dropped. */
const IDLE_RELAY = new BrowserRelay({ active: () => false, key: "", push: () => undefined, identity: () => "anonymous" });

export type LogLevel = "debug" | "info" | "warn" | "error" | "fatal";
const LEVELS: Record<string, number> = { debug: 0, info: 1, warn: 2, error: 3, fatal: 4, off: 99 };

/**
 * The agent. Inert until `start` is given a URL and a key — in development,
 * in tests, anywhere Glass is not: every method is then a cheap no-op and
 * nothing is buffered or sent.
 */
export class Glass {
  private transport: Transport | null = null;
  private aggregator = new Aggregator();
  private readonly ambient = new AsyncLocalStorage<RunScope>();
  private errors = 0;
  private stops: (() => void)[] = [];
  private readonly request = new AsyncLocalStorage<RequestContext>();
  private vitals: Runtime | null = null;
  private relay: BrowserRelay | null = null;
  private profiler: Profiler | null = null;
  private onError: ((where: string, error: unknown) => void) | undefined;

  /** Whether anything is being reported. False without a URL and a key, and after a 401. */
  get enabled(): boolean {
    return this.transport !== null && !this.transport.halted;
  }

  /** What Glass's console currently asks of this app's agents. */
  get directives(): Directives | null {
    return this.transport?.directives ?? null;
  }

  /** What has been shed since the process started, by record type. */
  get dropped(): Record<string, number> {
    return { ...this.transport?.dropped };
  }

  start(options: GlassOptions = {}): this {
    const url = options.url ?? process.env.GLASS_URL ?? "";
    const key = options.key ?? process.env.GLASS_API_KEY ?? "";
    if (!url || !key || this.transport) return this;
    this.onError = options.onError;
    this.aggregator = new Aggregator(5000, options.now);
    this.transport = new Transport(
      {
        url, key,
        process: options.process ?? "node",
        release: options.release ?? process.env.GIT_SHA ?? process.env.GIT_REV ?? null,
        host: options.host, runtime: options.runtime, flushIntervalMs: options.flushIntervalMs, queueSize: options.queueSize,
        sender: options.sender, now: options.now,
        onError: (where, error) => this.failed(where, error),
        onDirectives: (_directives, profileNow) => {
          if (profileNow) this.profiler?.request(profileNow);
        },
        beforeFlush: () => {
          const vitals = this.vitals;
          if (vitals) this.guard("vitals", () => vitals.sample());
          if (options.beforeFlush) this.guard("beforeFlush", options.beforeFlush);
          if (this.errors > 0) {
            this.aggregator.counter("glass.agent.errors", this.errors);
            this.errors = 0;
          }
        },
      },
      this.aggregator,
    );
    this.transport.start();
    const transport = this.transport;
    const onError = (where: string, error: unknown) => this.failed(where, error);
    const relay = new BrowserRelay({
      active: () => this.enabled && transport.directives.browser,
      key,
      push: (record) => transport.push(record),
      identity: () => transport.directives.identity,
      traceFor: options.traceFor,
      onError,
    });
    this.relay = relay;
    if (options.outbound !== false) {
      this.stops.push(captureOutbound({ currentRun: () => this.currentRun(), enabled: () => this.enabled, ignoreOrigin: new URL(url).origin, propagateTo: options.outbound?.propagateTo, onError }));
    }
    if (options.inbound !== false) {
      this.stops.push(captureInbound({ enabled: () => this.enabled, context: this.request, push: (record) => transport.push(record), aggregator: this.aggregator, ignore: options.inbound?.ignore, onVisit: (visit) => relay.seen(visit), onError }));
    }
    if (options.vitals !== false) {
      this.vitals = new Runtime(this.aggregator, options.process ?? "node");
      this.vitals.start();
    }
    const profiles = options.profiles ?? "on-demand";
    if (profiles !== "off") {
      this.profiler = new Profiler({
        push: (record) => transport.push(record),
        continuous: () => profiles === "continuous" && this.enabled && transport.directives.profiling,
        hz: () => transport.directives.profileHz,
        root: options.root ?? process.cwd(),
        windowMs: options.profileWindowMs,
        onError,
      });
      this.profiler.start();
    }
    if (options.console) {
      this.stops.push(captureConsole((level, message, source) => this.log(level, message, { source })));
    }
    return this;
  }

  /** Send what is buffered, now. Resolves when the attempt is over; never rejects. */
  async flush(final = false): Promise<void> {
    await this.transport?.flush(final);
  }

  /** Flush one last time and stop. For a process that is shutting down. */
  async stop(): Promise<void> {
    const transport = this.transport;
    if (!transport) return;
    transport.stop();
    for (const stop of this.stops) stop();
    this.stops = [];
    this.vitals?.stop();
    this.vitals = null;
    // The window in flight is sent with the last flush.
    await this.profiler?.stop();
    this.profiler = null;
    this.relay = null;
    await Promise.race([transport.flush(true), new Promise((resolve) => setTimeout(resolve, 2000).unref())]);
    this.transport = null;
  }

  // ---- runs --------------------------------------------------------------

  /**
   * Open the envelope around one thing asked of the harness. Finish it when
   * the reply has been handed over. A run begun while serving a request
   * continues that request's trace, as the work the request set going.
   */
  startRun(options: RunOptions): RunScope {
    const request = options.trace ? undefined : this.request.getStore();
    return new RunScope(request ? { ...options, trace: request.trace, parent: options.parent ?? request.span } : options, this.sinks());
  }

  /** The request this code is executing under, if the process is serving one. */
  currentRequest(): RequestContext | null {
    return this.request.getStore() ?? null;
  }

  /**
   * Say who the request being served is for, once the app knows. The request
   * is stamped with them as the app's identity mode allows — nothing, a keyed
   * hash, or a name — and so is everything their browser reports for the
   * visit: the page itself never learns who is signed in.
   */
  identify(user: { id: string | number; name?: string | null }): void {
    const relay = this.relay;
    const request = this.request.getStore();
    if (!relay || !request) return;
    this.guard("identify", () => {
      request.user = relay.userRef(user).ref;
      relay.seen(request.visit, user);
    });
  }

  /**
   * Answer a request under `/_glass/` — glass.js and the beacons it posts —
   * and say whether it was one. Mount it ahead of the app's own routes. Safe
   * before `start` and without configuration: the script is then empty and a
   * beacon is dropped, so the tag can sit in a page for good.
   */
  handleBrowser(request: IncomingMessage, response: ServerResponse): boolean {
    return (this.relay ?? IDLE_RELAY).handle(request, response);
  }

  /** Run `fn` with `run` as the ambient run: code beneath it reaches the run through `currentRun` without being handed it. */
  withRun<T>(run: RunScope, fn: () => T): T {
    return this.ambient.run(run, fn);
  }

  /** The run this code is executing under, if any. */
  currentRun(): RunScope | null {
    return this.ambient.getStore() ?? null;
  }

  /**
   * The envelope in one call: open a run, make it ambient for `fn`, and close
   * it when `fn` settles — as an error if it threw. A run already ambient is
   * joined, not nested: the outermost caller owns the envelope.
   */
  async run<T>(options: RunOptions, fn: (run: RunScope) => Promise<T> | T): Promise<T> {
    const open = this.currentRun();
    if (open) return fn(open);
    const run = this.startRun(options);
    try {
      const value = await this.withRun(run, () => fn(run));
      run.finish();
      return value;
    } catch (error) {
      run.finish({ status: "error", error: error instanceof Error ? error.name : "Error" });
      throw error;
    }
  }

  /**
   * Time `fn` as a span of the ambient run. Outside any run it just calls
   * `fn`: a step with nothing to be a step of is not recorded.
   */
  async span<T>(kind: SpanKind, name: string, fn: () => Promise<T> | T, opts: { res?: string | null; attrs?: Attrs } = {}): Promise<T> {
    const run = this.currentRun();
    if (!run || !this.enabled) return fn();
    const handle = run.startSpan(kind, name, opts);
    try {
      const value = await fn();
      handle.end();
      return value;
    } catch (error) {
      handle.end({ status: "error" });
      throw error;
    }
  }

  /** A model call made outside any run: a title, a judge, an eval. Sent at once. */
  modelCall(call: ModelCallInput): void {
    const sinks = this.sinks();
    if (sinks) this.guard("modelCall", () => emitModelCall(sinks, call));
  }

  // ---- everything else ---------------------------------------------------

  /** Something that happened and belongs on every chart: a restart, a model that changed, a kill switch. */
  marker(title: string, opts: { kind?: "event" | "deploy" | "restart" | "annotation"; attrs?: Attrs; at?: number } = {}): void {
    const transport = this.transport;
    if (!transport) return;
    this.guard("marker", () => {
      const record: WireRecord = { t: "marker", ts: (opts.at ?? Date.now()) / 1000, kind: opts.kind ?? "event", title: String(title).slice(0, 200) };
      const attrs = cleanAttrs(opts.attrs);
      if (attrs) record.attrs = attrs;
      transport.push(record);
    });
  }

  /** One log line. Inside a run it carries the run's trace. */
  log(level: LogLevel, message: string, opts: { source?: string; attrs?: Attrs; at?: number } = {}): void {
    const transport = this.transport;
    if (!transport || (LEVELS[level] ?? 1) < (LEVELS[transport.directives.logLevel] ?? 1)) return;
    this.guard("log", () => {
      const run = this.currentRun();
      // ANSI colour is for a terminal.
      const text = String(message).replace(/\u001b\[[0-9;]*m/g, "").slice(0, 8000);
      const record: WireRecord = { t: "log", ts: (opts.at ?? Date.now()) / 1000, lvl: level, msg: text, src: opts.source ?? "node" };
      if (run) Object.assign(record, { trace: run.trace, span: run.span });
      const attrs = cleanAttrs(opts.attrs);
      if (attrs) record.attrs = attrs;
      transport.push(record);
    });
  }

  increment(name: string, by = 1, tags?: Tags): void {
    if (this.enabled) this.aggregator.counter(name, by, tags);
  }
  gauge(name: string, value: number, tags?: Tags, unit?: string): void {
    if (this.enabled) this.aggregator.gauge(name, value, tags, unit);
  }
  histogram(name: string, value: number, tags?: Tags, unit?: string): void {
    if (this.enabled) this.aggregator.dist(name, value, tags, unit);
  }
  timing(name: string, ms: number, tags?: Tags): void {
    if (this.enabled) this.aggregator.dist(name, ms, tags, "ms");
  }
  /** Count distinct members: `glass.unique("sessions.active", sessionId)`. */
  unique(name: string, member: string | number, tags?: Tags): void {
    if (this.enabled) this.aggregator.set(name, member, tags);
  }

  /** A record the caller built itself. For bridges that already hold wire-shaped data. */
  push(record: WireRecord): void {
    const transport = this.transport;
    if (transport) this.guard("push", () => transport.push(record));
  }

  private sinks(): { transport: Transport; aggregator: Aggregator; onError: (where: string, error: unknown) => void } | null {
    return this.transport && !this.transport.halted ? { transport: this.transport, aggregator: this.aggregator, onError: (where, error) => this.failed(where, error) } : null;
  }

  private guard(where: string, fn: () => void): void {
    try {
      fn();
    } catch (error) {
      this.failed(where, error);
    }
  }

  private failed(where: string, error: unknown): void {
    this.errors += 1;
    try {
      this.onError?.(where, error);
    } catch {
      /* an error handler that throws is not the app's problem either */
    }
  }
}
