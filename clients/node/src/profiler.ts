import { Session } from "node:inspector/promises";
import { fileURLToPath } from "node:url";
import { relative, sep } from "node:path";
import type { WireRecord } from "./transport.ts";

/** V8's sampling profile, as the inspector hands it back (the parts read here). */
export interface CpuProfile {
  nodes: { id: number; callFrame: { functionName: string; url: string; lineNumber: number }; children?: number[] }[];
  samples?: number[];
  /** Microseconds between samples. */
  timeDeltas?: number[];
  startTime: number;
  endTime: number;
}

export type FunctionEntry = [name: string, file: string, line: number, category: "app" | "gem" | "node" | "native"];
export type SampleEntry = [stack: number, transaction: null, state: "running" | "gc", weight: number];

export interface Folded {
  funcs: FunctionEntry[];
  stacks: number[][];
  samples: SampleEntry[];
}

const MAX_STACKS = 5000;
/** One-shot ids remembered so a request repeated in every reply runs once: the gem's bound. */
const MAX_HANDLED = 50;
const MAX_DEPTH = 256;

/**
 * A function as the wire names it: never an absolute path. App code is
 * relative to the app's root; a dependency is its package and the path
 * inside it, wherever the package manager put it; Node's own code keeps its
 * `node:` name.
 */
export function describeFrame(frame: { functionName: string; url: string; lineNumber: number }, root: string): FunctionEntry {
  const name = frame.functionName || "(anonymous)";
  const line = Math.max(frame.lineNumber + 1, 0);
  const url = frame.url;
  if (!url) return [name, "", 0, "native"];
  if (url.startsWith("node:")) return [name, url, line, "node"];
  if (!url.startsWith("file:")) return [name, url.split("?", 1)[0]!.slice(0, 200), line, "native"];
  let path: string;
  try {
    path = fileURLToPath(url);
  } catch {
    return [name, "", line, "native"];
  }
  const marker = `${sep}node_modules${sep}`;
  const at = path.lastIndexOf(marker);
  if (at >= 0) return [name, path.slice(at + marker.length).split(sep).join("/"), line, "gem"];
  const inside = relative(root, path);
  // Outside the app's root and not a dependency: its last few segments say what it is without saying where the machine keeps it.
  const file = inside.startsWith("..") ? path.split(sep).slice(-3).join("/") : inside.split(sep).join("/");
  return [name, file, line, "app"];
}

/**
 * A window of samples folded to stacks and weights (docs/ingest-protocol.md,
 * `profile`): a minute of a busy process is a few hundred distinct stacks,
 * not six thousand samples. Idle samples are left out — a process waiting
 * for work is not a finding — and the garbage collector's are marked as such.
 */
export function fold(profile: CpuProfile, root: string): Folded {
  const byId = new Map(profile.nodes.map((node) => [node.id, node]));
  const parent = new Map<number, number>();
  for (const node of profile.nodes) for (const child of node.children ?? []) parent.set(child, node.id);

  const weights = new Map<number, number>();
  for (const id of profile.samples ?? []) weights.set(id, (weights.get(id) ?? 0) + 1);

  const funcs: FunctionEntry[] = [];
  const funcIndex = new Map<string, number>();
  const intern = (entry: FunctionEntry): number => {
    const key = `${entry[0]}\0${entry[1]}\0${entry[3]}`;
    let index = funcIndex.get(key);
    if (index === undefined) {
      index = funcs.push(entry) - 1;
      funcIndex.set(key, index);
    }
    return index;
  };

  const stacks: number[][] = [];
  const stackIndex = new Map<string, number>();
  const folded = new Map<string, SampleEntry>();
  // The heaviest stacks first, so that what is cut when a window has too many is the long tail.
  for (const [id, weight] of [...weights].sort((a, b) => b[1] - a[1])) {
    const leaf = byId.get(id);
    if (!leaf) continue;
    const leafName = leaf.callFrame.functionName;
    if (leafName === "(idle)") continue;
    const path: CpuProfile["nodes"] = [];
    for (let at: number | undefined = id; at !== undefined && path.length < MAX_DEPTH; at = parent.get(at)) {
      const node = byId.get(at);
      if (!node || node.callFrame.functionName === "(root)") break;
      path.push(node);
    }
    if (path.length === 0) continue;
    const frames = path.reverse().map((node) => intern(describeFrame(node.callFrame, root))); // root first
    const key = frames.join(",");
    let index = stackIndex.get(key);
    if (index === undefined) {
      if (stacks.length >= MAX_STACKS) continue;
      index = stacks.push(frames) - 1;
      stackIndex.set(key, index);
    }
    const state = leafName === "(garbage collector)" ? "gc" : "running";
    const sampleKey = `${index}:${state}`;
    const existing = folded.get(sampleKey);
    if (existing) existing[3] += weight;
    else folded.set(sampleKey, [index, null, state, weight]);
  }
  return { funcs, stacks, samples: [...folded.values()] };
}

export interface ProfilerOptions {
  push: (record: WireRecord) => void;
  /** Profile continuously: the client's switch and the app's `profiling` directive both say yes. */
  continuous: () => boolean;
  hz: () => number;
  /** The app's root, which app code is named relative to. */
  root: string;
  windowMs?: number;
  onError?: (where: string, error: unknown) => void;
}

/**
 * V8's own sampling profiler, in back-to-back windows, through the inspector
 * the process already has: no dependency, nothing native to build. Samples
 * are of the one thread JavaScript runs on, so the flamegraph is where that
 * thread's time goes — which, when event-loop delay rises, is the question.
 *
 * A sample cannot be attributed to a run: many runs interleave on the one
 * thread, and a sample knows the stack, not whose turn it was. So this is a
 * process's flamegraph, not an endpoint's.
 */
export class Profiler {
  private session: Session | null = null;
  private timer: NodeJS.Timeout | null = null;
  private running: { startedAt: number; hz: number; request: string | null } | null = null;
  private readonly done = new Set<string>();
  private busy: Promise<void> = Promise.resolve();
  private wake: (() => void) | null = null;
  private readonly options: ProfilerOptions;

  constructor(options: ProfilerOptions) {
    this.options = options;
  }

  /** Begin the windows. Whether anything is sampled in a window is asked at its start. */
  start(): void {
    if (this.timer) return;
    const windowMs = this.options.windowMs ?? 60_000;
    this.timer = setInterval(() => this.queue(() => this.roll()), windowMs);
    this.timer.unref();
    this.queue(() => this.roll());
  }

  /** Stop, sending the window in flight. */
  async stop(): Promise<void> {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    this.wake?.(); // a one-shot in flight ends here, and is sent short
    this.queue(() => this.finish());
    await this.busy;
    this.session?.disconnect();
    this.session = null;
  }

  /** A one-shot request from the console: profile for this long at this rate, once per id. */
  request(now: { id?: unknown; seconds?: unknown; hz?: unknown }): void {
    const id = typeof now.id === "string" ? now.id.slice(0, 64) : null;
    if (!id || this.done.has(id)) return;
    this.done.add(id);
    if (this.done.size > MAX_HANDLED) this.done.delete(this.done.values().next().value!);
    const seconds = Math.min(Math.max(Number(now.seconds) || 30, 1), 300);
    const hz = Math.min(Math.max(Math.round(Number(now.hz) || 1000), 10), 1000);
    this.queue(async () => {
      await this.finish();
      await this.begin(hz, id);
      await new Promise<void>((resolve) => {
        this.wake = resolve;
        setTimeout(resolve, seconds * 1000).unref();
      });
      this.wake = null;
      await this.finish();
      if (this.timer) await this.roll();
    });
  }

  /** One thing at a time on the session, in order, and nothing thrown out of it. */
  private queue(step: () => Promise<void>): void {
    this.busy = this.busy.then(step).catch((error) => this.options.onError?.("profiler", error));
  }

  private async roll(): Promise<void> {
    await this.finish();
    if (this.options.continuous()) await this.begin(this.options.hz(), null);
  }

  private async begin(hz: number, request: string | null): Promise<void> {
    if (!this.session) {
      this.session = new Session();
      this.session.connect();
      await this.session.post("Profiler.enable");
    }
    await this.session.post("Profiler.setSamplingInterval", { interval: Math.round(1e6 / hz) });
    await this.session.post("Profiler.start");
    this.running = { startedAt: Date.now(), hz, request };
  }

  private async finish(): Promise<void> {
    const running = this.running;
    if (!running || !this.session) return;
    this.running = null;
    const { profile } = (await this.session.post("Profiler.stop")) as { profile: CpuProfile };
    const folded = fold(profile, this.options.root);
    if (folded.samples.length === 0) return;
    const record: Record<string, unknown> = {
      t: "profile", ts: running.startedAt / 1000, dur: (Date.now() - running.startedAt) / 1000, hz: running.hz, mode: "wall",
      funcs: folded.funcs, stacks: folded.stacks, samples: folded.samples,
    };
    if (running.request) record.request = running.request;
    this.options.push(record as WireRecord);
  }
}
