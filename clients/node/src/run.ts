import type { Aggregator } from "./aggregator.ts";
import { newSpanId, newTraceId } from "./ids.ts";
import { FILTER_KEYS, FILTERED } from "./net.ts";
import type { Transport, WireRecord } from "./transport.ts";

/** What a span can be a step of (docs/ingest-protocol.md). Anything else is stored as `custom`. */
export type SpanKind =
  | "sql" | "view" | "cache" | "http" | "enqueue" | "custom"
  | "model" | "tool" | "wait" | "queue" | "memory" | "context" | "sandbox" | "channel";

export type Scalar = string | number | boolean | null | undefined;
export type Attrs = Record<string, unknown>;

export interface RunOptions {
  /** What aggregates group by: the agent for a turn, the purpose for background work. */
  name: string;
  agent?: string | null;
  session?: string | null;
  trigger?: string | null;
  channel?: string | null;
  user?: string | null;
  /** Continue a trace instead of starting one. */
  trace?: string;
  span?: string;
  /** The span that set this run going: another run's root, an enqueue, a remote caller. */
  parent?: string | null;
  /** Epoch milliseconds; now when omitted. */
  startedAt?: number;
  /** Wanted → begun, before `startedAt`: a message in transit, a task waiting to be claimed. */
  lagMs?: number | null;
  attrs?: Attrs;
}

export interface SpanInput {
  kind: SpanKind;
  name: string;
  /** The resource: the model a `model` span called, the channel a `channel` span delivered to. Never a tool's arguments. */
  res?: string | null;
  /** Epoch milliseconds. */
  startedAt: number;
  durMs: number;
  status?: "ok" | "error";
  attrs?: Attrs;
  id?: string;
  /** The parent span's id; the run's root when omitted. */
  parent?: string | null;
  /**
   * Captured by the client rather than recorded by the app (an outbound HTTP
   * call). It has no parent of its own, so when the run finishes it is hung
   * under the step that was happening at the time.
   */
  captured?: boolean;
}

/** One call to a model. No prompt, no completion — ever. */
export interface ModelCallInput {
  provider: string;
  model: string;
  served?: string | null;
  tier?: string | null;
  purpose?: string | null;
  origin?: "production" | "internal" | "eval" | (string & {});
  agent?: string | null;
  session?: string | null;
  round?: number | null;
  /** Epoch milliseconds. */
  startedAt: number;
  durMs: number;
  ttftMs?: number | null;
  firstTextMs?: number | null;
  itlP95Ms?: number | null;
  queueMs?: number | null;
  loadMs?: number | null;
  promptMs?: number | null;
  decodeMs?: number | null;
  concurrent?: number | null;
  stream?: boolean;
  /** Uncached input tokens. */
  inputTokens?: number;
  cacheReadTokens?: number;
  cacheWriteTokens?: number;
  outputTokens?: number;
  reasoningTokens?: number;
  estimated?: boolean;
  costUsd?: number;
  costSource?: "reported" | "estimated" | "shadow" | "free" | null;
  stop?: string | null;
  status?: "ok" | "error";
  /** The error class: `timeout`, `rate_limit`, `overloaded`, … */
  error?: string | null;
  /** The span of the call this one retries. */
  retryOf?: string | null;
  fallbackFrom?: string | null;
  route?: string | null;
  tools?: number;
  toolsValid?: number | null;
  /** The `model` span this call was. */
  span?: string | null;
  trace?: string | null;
  attrs?: Attrs;
}

export interface FinishOptions {
  status?: "ok" | "error";
  /** The error class when `status` is `error`. */
  error?: string | null;
  /** Why it ended: `ok`, `rounds`, `tokens`, `cancelled`, … */
  stop?: string | null;
  /** The model that gave the answer; the last successful `turn` call's when omitted. */
  model?: string | null;
  rounds?: number;
  /** Epoch milliseconds; now when omitted. */
  endedAt?: number;
  attrs?: Attrs;
}

/** What a run's phases added up to (docs/ingest-protocol.md): each exclusive of the others. */
export interface Phases {
  queue: number;
  prep: number;
  model: number;
  tool: number;
  wait: number;
  deliver: number;
}

const PHASE_OF: Partial<Record<SpanKind, keyof Phases>> = {
  queue: "queue", memory: "prep", context: "prep", model: "model", tool: "tool", sandbox: "tool", wait: "wait", channel: "deliver",
};
const MAX_SPANS = 2000;
/** A run that makes more model calls than this is a loop; what it spent past the bound is counted, not itemised. */
const MAX_CALLS = 2000;
const MAX_MARKS = 5000;
const MAX_ATTRS = 64;
const MAX_ATTR_VALUE = 1000;

interface Sinks {
  transport: Transport;
  aggregator: Aggregator;
  /** Told when building what a run sends fails: nothing under a run throws into the app. */
  onError?: (where: string, error: unknown) => void;
}

/**
 * One thing asked of an agent harness, while it is happening: the envelope
 * around a turn. Spans and model calls are collected
 * as they finish and nothing is sent until `finish`, because what a run *is* —
 * where its time went, what it spent, what the person saw — is only known at
 * the end. A model call in particular is held: the harness learns how many of
 * its tool calls parsed after the call has returned, and Glass's rows are
 * never updated.
 */
export class RunScope {
  /** The trace this run is part of. */
  trace: string;
  readonly span: string;
  readonly startedAt: number;

  private readonly spans: (SpanInput & { id: string })[] = [];
  private readonly calls: ModelCallInput[] = [];
  private readonly marks: { at: number; text: boolean }[] = [];
  private readonly fields: Record<string, Scalar> = {};
  private extraAttrs: Attrs = {};
  private droppedSpans = 0;
  private droppedCalls = 0;
  private finished = false;

  private readonly options: RunOptions;
  private readonly sinks: Sinks | null;

  constructor(options: RunOptions, sinks: Sinks | null) {
    this.options = { ...options };
    this.sinks = sinks;
    this.trace = options.trace ?? newTraceId();
    this.span = options.span ?? newSpanId();
    this.startedAt = options.startedAt ?? Date.now();
  }

  /** A span that has already finished. Returns its id, for children to name as their parent. */
  addSpan(input: SpanInput): string {
    const id = input.id ?? newSpanId();
    if (this.finished) return id;
    if (this.spans.length >= MAX_SPANS) this.droppedSpans += 1;
    else this.spans.push({ ...input, id });
    return id;
  }

  /** A span that starts now and ends when told to. */
  startSpan(kind: SpanKind, name: string, opts: { res?: string | null; parent?: string | null; attrs?: Attrs } = {}): { id: string; end: (result?: { status?: "ok" | "error"; attrs?: Attrs }) => void } {
    const id = newSpanId();
    const startedAt = Date.now();
    let ended = false;
    return {
      id,
      end: (result = {}) => {
        if (ended) return;
        ended = true;
        this.addSpan({ kind, name, res: opts.res, parent: opts.parent, startedAt, durMs: Date.now() - startedAt, status: result.status, attrs: { ...opts.attrs, ...result.attrs }, id });
      },
    };
  }

  /**
   * A model call made under this run. Held until the run finishes, and the
   * record handed back is the one that will be sent: set `toolsValid` on it
   * when the harness finds out.
   */
  modelCall(input: ModelCallInput): ModelCallInput {
    const call = { ...input };
    if (this.finished) return call;
    if (this.calls.length >= MAX_CALLS) this.droppedCalls += 1;
    else this.calls.push(call);
    return call;
  }

  /**
   * Something reached the person: answer text (`text: true`), or a sign of
   * progress — a tool notice, a typing indicator, an approval prompt. Feeds
   * `ttft_ms` and `stall_ms`.
   */
  visible(text = false, at: number = Date.now()): void {
    if (this.finished) return;
    const last = this.marks[this.marks.length - 1];
    // A stream is hundreds of deltas a second; a mark a quarter-second is all a stall can be measured to.
    if (last && last.text === text && at - last.at < 250) return;
    if (this.marks.length < MAX_MARKS) this.marks.push({ at, text });
  }

  /** Facts about the run learned along the way. */
  set(fields: { name?: string; parent?: string | null; agent?: string | null; session?: string | null; trigger?: string | null; channel?: string | null; user?: string | null; lagMs?: number | null; attrs?: Attrs }): void {
    const { attrs, ...rest } = fields;
    Object.assign(this.options, Object.fromEntries(Object.entries(rest).filter(([, value]) => value !== undefined)));
    if (attrs) this.extraAttrs = { ...this.extraAttrs, ...attrs };
  }

  /**
   * Join a trace that already exists, as the work `parent` set going: a task
   * spawned by another run, continued here. Only before anything under this run
   * has used its trace — nothing is sent until the run finishes, but a request
   * already made has already carried the old id.
   */
  adopt(trace: string, parent: string | null): void {
    if (this.finished) return;
    this.trace = trace;
    this.options.parent = parent;
  }

  /** Whether the envelope has been closed (or thrown away). */
  get closed(): boolean {
    return this.finished;
  }

  /** Throw the envelope away: nothing under it is sent. For an envelope opened around something that turned out not to be a run. */
  discard(): void {
    this.finished = true;
  }

  /** Close the envelope and send everything under it. Safe to call twice; the second does nothing. */
  finish(result: FinishOptions = {}): void {
    if (this.finished) return;
    this.finished = true;
    const sinks = this.sinks;
    if (!sinks) return;

    try {
      this.send(sinks, result);
    } catch (error) {
      sinks.onError?.("run", error);
    }
  }

  private send(sinks: Sinks, result: FinishOptions): void {
    const endedAt = Math.max(result.endedAt ?? Date.now(), this.startedAt);
    const duration = endedAt - this.startedAt;
    adoptCaptured(this.spans, this.span);
    const phases = accountFor(this.spans, this.span, this.startedAt, endedAt);
    const tools = this.spans.filter((span) => span.kind === "tool");
    const turnCalls = this.calls.filter((call) => (call.purpose ?? "turn") === "turn");
    const answered = [...turnCalls].reverse().find((call) => (call.status ?? "ok") === "ok");
    // A subscription call's shadow cost is what it would have cost metered, not money spent.
    const sum = (pick: (call: ModelCallInput) => number | undefined) => this.calls.reduce((total, call) => total + (pick(call) ?? 0), 0);
    const firstText = this.marks.find((mark) => mark.text);
    const outbound = this.spans.filter((span) => span.kind === "http");
    const waits = this.spans.filter((span) => span.kind === "wait").map((span) => [span.startedAt, span.startedAt + span.durMs] as [number, number]);

    const txn: WireRecord = compact({
      t: "txn", ts: this.startedAt / 1000, kind: "run", name: this.options.name,
      trace: this.trace, span: this.span, parent: this.options.parent ?? undefined,
      dur: round(duration), status: result.status ?? "ok", error: result.error ?? undefined,
      agent: this.options.agent, session: this.options.session, trigger: this.options.trigger, channel: this.options.channel,
      stop: result.stop ?? (result.status === "error" ? "error" : "ok"), user: this.options.user,
      model: result.model ?? answered?.served ?? answered?.model,
      rounds: result.rounds ?? turnCalls.filter((call) => !call.retryOf).length,
      calls: this.calls.length + this.droppedCalls, tools_n: tools.length, tool_err: tools.filter((span) => span.status === "error").length,
      tok_in: sum((call) => call.inputTokens), tok_out: sum((call) => call.outputTokens),
      tok_cache_read: sum((call) => call.cacheReadTokens), tok_cache_write: sum((call) => call.cacheWriteTokens),
      cost: round(sum((call) => (call.costSource === "shadow" ? 0 : call.costUsd)), 6),
      queue_ms: round(phases.queue), prep_ms: round(phases.prep), model_ms: round(phases.model), tool_ms: round(phases.tool),
      wait_ms: round(phases.wait), deliver_ms: round(phases.deliver),
      // Outbound time: the HTTP spans when the process captures them (a model call is one of them), the model calls when it does not.
      ext_ms: round(outbound.length ? outbound.reduce((total, span) => total + span.durMs, 0) : sum((call) => call.durMs)),
      ext_n: outbound.length || this.calls.length,
      lag_ms: this.options.lagMs === null || this.options.lagMs === undefined ? undefined : round(Math.max(this.options.lagMs, 0)),
      ttft_ms: firstText ? round(Math.max(firstText.at - this.startedAt, 0)) : undefined,
      stall_ms: round(longestSilence(this.startedAt, endedAt, this.marks.map((mark) => mark.at), waits)),
      kept: true,
      attrs: cleanAttrs({ ...this.options.attrs, ...this.extraAttrs, ...result.attrs, ...(this.droppedSpans ? { dropped_spans: this.droppedSpans } : {}), ...(this.droppedCalls ? { dropped_calls: this.droppedCalls } : {}) }),
    }) as WireRecord;

    sinks.transport.push(txn);
    for (const span of this.spans) sinks.transport.push(spanRecord(span, this.trace, this.span));
    for (const call of this.calls) emitModelCall(sinks, { agent: this.options.agent, session: this.options.session, ...call, trace: call.trace ?? this.trace });

    const tags = { agent: this.options.agent ?? this.options.name, trigger: this.options.trigger ?? undefined, status: result.status ?? "ok" };
    const at = Math.floor(endedAt / 1000);
    sinks.aggregator.counter("ai.runs", 1, tags, undefined, at);
    sinks.aggregator.dist("ai.run.active", Math.max(duration - phases.wait, 0), tags, "ms", at);
    for (const tool of tools) {
      const toolTags = { tool: tool.name, status: tool.status ?? "ok" };
      sinks.aggregator.counter("ai.tool.calls", 1, toolTags, undefined, at);
      sinks.aggregator.dist("ai.tool.duration", tool.durMs, toolTags, "ms", at);
    }
  }
}

/** A model call as it travels, and the metrics every call leaves behind however long its row is kept. */
export function emitModelCall(sinks: Sinks, call: ModelCallInput): void {
  sinks.transport.push(compact({
    t: "llm", ts: call.startedAt / 1000, trace: call.trace ?? undefined, span: call.span ?? undefined,
    provider: call.provider, model: call.model, served: call.served, tier: call.tier,
    purpose: call.purpose ?? "turn", origin: call.origin ?? "production", agent: call.agent, session: call.session, round: call.round,
    dur: round(call.durMs), ttft: optional(call.ttftMs), first_text: optional(call.firstTextMs), itl_p95: optional(call.itlP95Ms),
    queue_ms: optional(call.queueMs), load_ms: optional(call.loadMs), prompt_ms: optional(call.promptMs), decode_ms: optional(call.decodeMs),
    concurrent: call.concurrent, stream: call.stream,
    in: call.inputTokens ?? 0, cache_read: call.cacheReadTokens ?? 0, cache_write: call.cacheWriteTokens ?? 0,
    out: call.outputTokens ?? 0, reasoning: call.reasoningTokens ?? 0, estimated: call.estimated,
    cost: round(call.costUsd ?? 0, 6), cost_src: call.costSource,
    stop: call.stop, status: call.status ?? "ok", error: call.error, retry_of: call.retryOf, fallback_from: call.fallbackFrom,
    route: call.route, tools: call.tools ?? 0, tools_valid: call.toolsValid,
    attrs: cleanAttrs(call.attrs),
  }) as WireRecord);

  const at = Math.floor(call.startedAt / 1000);
  const tags = { provider: call.provider, model: call.model, purpose: call.purpose ?? "turn" };
  const { aggregator } = sinks;
  aggregator.counter("ai.calls", 1, { ...tags, status: call.status ?? "ok" }, undefined, at);
  if (call.costSource !== "shadow") aggregator.counter("ai.cost", call.costUsd ?? 0, tags, "usd", at);
  const tokens: [string, number | undefined][] = [["input", call.inputTokens], ["output", call.outputTokens], ["cache_read", call.cacheReadTokens], ["cache_write", call.cacheWriteTokens]];
  for (const [kind, count] of tokens) if (count) aggregator.counter("ai.tokens", count, { ...tags, kind }, "tokens", at);
  aggregator.dist("ai.duration", call.durMs, tags, "ms", at);
  if (typeof call.ttftMs === "number") aggregator.dist("ai.ttft", call.ttftMs, tags, "ms", at);
}

function spanRecord(span: SpanInput & { id: string }, trace: string, root: string): WireRecord {
  return compact({
    t: "span", ts: span.startedAt / 1000, trace, span: span.id, parent: span.parent ?? root,
    kind: span.kind, name: span.name.slice(0, 200), res: span.res ?? undefined, dur: round(Math.max(span.durMs, 0)),
    status: span.status ?? "ok", attrs: cleanAttrs(span.attrs),
  }) as WireRecord;
}

/**
 * Where a run's time went, each millisecond counted once. The spans directly
 * under the root are walked in start order and each is given the time it
 * covers that no earlier span already covered, so overlapping steps cannot
 * add up to more than the run. Time a step spent waiting on a person — a
 * `wait` span anywhere beneath it — is moved to `wait`: a tool that took
 * thirty seconds of which twenty-five were someone deciding took five.
 */
export function accountFor(spans: (SpanInput & { id: string })[], root: string, startedAt: number, endedAt: number): Phases {
  const phases: Phases = { queue: 0, prep: 0, model: 0, tool: 0, wait: 0, deliver: 0 };
  const known = new Set(spans.map((span) => span.id));
  const children = new Map<string, (SpanInput & { id: string })[]>();
  for (const span of spans) {
    const parent = span.parent && known.has(span.parent) ? span.parent : root;
    const list = children.get(parent);
    if (list) list.push(span);
    else children.set(parent, [span]);
  }
  const waitWithin = (span: SpanInput & { id: string }, from: number, to: number): number => {
    let total = 0;
    for (const child of children.get(span.id) ?? []) {
      if (child.kind === "wait") total += Math.max(0, Math.min(child.startedAt + child.durMs, to) - Math.max(child.startedAt, from));
      else total += waitWithin(child, from, to);
    }
    return total;
  };

  let cursor = startedAt;
  // Only a step that is a phase claims time: a span that is detail (an HTTP call, a routing decision) never takes it from one.
  const top = [...(children.get(root) ?? [])].filter((span) => PHASE_OF[span.kind]).sort((a, b) => a.startedAt - b.startedAt);
  for (const span of top) {
    const from = Math.max(span.startedAt, cursor);
    const to = Math.min(span.startedAt + span.durMs, endedAt);
    if (to <= from) continue;
    cursor = to;
    const phase = PHASE_OF[span.kind]!;
    if (phase === "wait") {
      phases.wait += to - from;
      continue;
    }
    const waited = Math.min(waitWithin(span, from, to), to - from);
    phases[phase] += to - from - waited;
    phases.wait += waited;
  }
  return phases;
}

/**
 * Hang each captured span under the step that was happening when it ran: the
 * narrowest recorded span that contains it in time. A provider's HTTP call
 * lands under its model span, an MCP server's under its tool span; one that
 * no step contains stays under the root.
 */
export function adoptCaptured(spans: (SpanInput & { id: string })[], root: string): void {
  const SLACK = 25; // the app's clock for a span and the client's for a request are read a few lines apart
  const recorded = spans.filter((span) => !span.captured);
  for (const span of spans) {
    if (!span.captured || (span.parent && span.parent !== root)) continue;
    const end = span.startedAt + span.durMs;
    let best: (SpanInput & { id: string }) | null = null;
    for (const candidate of recorded) {
      const candidateEnd = candidate.startedAt + candidate.durMs;
      if (candidate.startedAt - SLACK > span.startedAt || candidateEnd + SLACK < end) continue;
      // Contained give or take the slack — but its middle has to be inside: a call made just after a step ended is not that step's.
      const middle = span.startedAt + span.durMs / 2;
      if (middle < candidate.startedAt || middle > candidateEnd) continue;
      if (!best || candidate.durMs < best.durMs) best = candidate;
    }
    span.parent = best ? best.id : root;
  }
}

/**
 * The longest stretch in which the person saw nothing happen. Time spent
 * waiting on the person is taken out first: a turn that sat ten minutes on an
 * approval nobody answered did not stall — the person did.
 */
export function longestSilence(startedAt: number, endedAt: number, marks: number[], waits: [number, number][]): number {
  const points = [startedAt, ...marks.filter((at) => at >= startedAt && at <= endedAt), endedAt].sort((a, b) => a - b);
  let longest = 0;
  for (let index = 1; index < points.length; index += 1) {
    const from = points[index - 1]!;
    const to = points[index]!;
    let gap = to - from;
    for (const [waitFrom, waitTo] of waits) gap -= Math.max(0, Math.min(waitTo, to) - Math.max(waitFrom, from));
    longest = Math.max(longest, gap);
  }
  return Math.max(longest, 0);
}

/**
 * Attributes as the wire takes them: flat, bounded, and never a credential —
 * a key that names one keeps its place and loses its value, as the gem does.
 * Never throws: a value that cannot be said as a string (a function, a
 * symbol, a BigInt, a cycle) is left out.
 */
export function cleanAttrs(attrs: Attrs | undefined): Record<string, string | number | boolean> | undefined {
  if (!attrs || typeof attrs !== "object") return undefined;
  const out: Record<string, string | number | boolean> = {};
  let count = 0;
  let entries: [string, unknown][];
  try {
    entries = Object.entries(attrs);
  } catch {
    return undefined;
  }
  for (const [key, value] of entries) {
    if (value === null || value === undefined || count >= MAX_ATTRS) continue;
    if (FILTER_KEYS.test(key)) out[key] = FILTERED;
    else if (typeof value === "number") {
      if (!Number.isFinite(value)) continue;
      out[key] = value;
    } else if (typeof value === "boolean") out[key] = value;
    else {
      const text = typeof value === "string" ? value : stringify(value);
      if (text === null) continue;
      out[key] = text.slice(0, MAX_ATTR_VALUE);
    }
    count += 1;
  }
  return count > 0 ? out : undefined;
}

function stringify(value: unknown): string | null {
  try {
    const text: unknown = JSON.stringify(value);
    return typeof text === "string" ? text : null;
  } catch {
    return null;
  }
}

const round = (value: number, digits = 3): number => {
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
};
const optional = (value: number | null | undefined): number | undefined => (typeof value === "number" && Number.isFinite(value) ? round(Math.max(value, 0)) : undefined);

/** Absent optional fields are absent, not null (docs/ingest-protocol.md). */
function compact(record: Record<string, unknown>): Record<string, unknown> {
  for (const key of Object.keys(record)) if (record[key] === null || record[key] === undefined) delete record[key];
  return record;
}
