import { createHash, createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import type { IncomingMessage, ServerResponse } from "node:http";
import { gzipSync } from "node:zlib";
import { FILTER_KEYS, FILTERED, headerOf, requestOrigin } from "./net.ts";
import type { WireRecord } from "./transport.ts";
import { VERSION } from "./version.ts";

/**
 * The browser side of the agent, as the gem has it: serves
 * glass.js on the app's own origin and turns the beacons it posts to
 * /_glass/b into `page` records — stamping what only the server knows
 * (origin, user agent, visitor, user) and validating the rest, so a page can
 * report what a person did but never who they are, where they are, or
 * anything they typed. The browser never talks to Glass, and no key reaches
 * it.
 */

export const SCRIPT_ROUTE = "/_glass/glass.js";
export const BEACON_ROUTE = "/_glass/b";
export const SCRIPT_TAG = `<script defer src="${SCRIPT_ROUTE}"></script>`;

const MAX_BODY = 64 * 1024;
const MAX_EVENTS = 100;
const UNSEEN_QUOTA = 50;
const MAX_VISITS = 5000;
const MAX_PROPS = 32;
const MAX_PROP_VALUE = 200;
const KINDS = new Set(["pageview", "click", "submit", "vital", "custom", "error"]);
const VITALS = ["lcp", "inp", "cls", "ttfb", "fcp"] as const;
const VISIT = /^v_[0-9a-f]{12}$/;
const TRACE = /^[0-9a-f]{32}$/;

interface VisitEntry {
  /** A real request has carried this visit id: it is not something a page made up. */
  seen: boolean;
  events: number;
  user: string | null;
  keyed: string | null;
}

export interface BrowserOptions {
  /** The agent is reporting and the app's `browser` directive is on. */
  active: () => boolean;
  /** The ingest key: what visitor and user hashes are keyed with. Never sent anywhere. */
  key: string;
  push: (record: WireRecord) => void;
  identity: () => "anonymous" | "pseudonymous" | "named";
  /**
   * The trace an event belongs to, from what the page said about it — an app
   * whose pages know their own ids (a run) maps one to the trace it reported.
   */
  traceFor?: (props: Record<string, unknown>) => string | null;
  onError?: (where: string, error: unknown) => void;
}

export class BrowserRelay {
  private readonly visits = new Map<string, VisitEntry>();
  private script: { raw: Buffer; gzip: Buffer; etag: string } | null = null;
  private readonly options: BrowserOptions;

  constructor(options: BrowserOptions) {
    this.options = options;
  }

  /**
   * Answer a request under `/_glass/`. Returns false for any other path, so
   * an app mounts it ahead of its own routes: `if (relay.handle(req, res)) return`.
   * While the browser directive is off the script is empty and beacons are
   * dropped: the tag can sit in a page for good and cost nothing.
   */
  handle(request: IncomingMessage, response: ServerResponse): boolean {
    const path = (request.url ?? "").split("?", 1)[0] ?? "";
    if (!path.startsWith("/_glass/")) return false;
    try {
      if (path === SCRIPT_ROUTE && (request.method === "GET" || request.method === "HEAD")) this.serveScript(request, response);
      else if (path === BEACON_ROUTE && request.method === "POST") this.beacon(request, response);
      else end(response, 404);
    } catch (error) {
      this.options.onError?.("relay", error);
      end(response, 404);
    }
    return true;
  }

  /**
   * A request carried `X-Glass-Visit`: the visit is real. With a user, the
   * join browser → server is remembered — the page never learns who is
   * signed in, and its events are stamped with it here.
   */
  seen(visit: string | null | undefined, user?: { id: string | number; name?: string | null } | null): void {
    if (!visit || !VISIT.test(visit)) return;
    const entry = this.take(visit);
    entry.seen = true;
    if (user) {
      const { ref, keyed } = this.userRef(user);
      entry.user = ref;
      entry.keyed = ref ? keyed : null;
    }
    this.put(visit, entry);
  }

  /**
   * Who, as the app's identity mode says: nothing, a keyed hash of the app's
   * own user id (the gem's scheme, so the same person is the same reference
   * from either client), or a display name.
   */
  userRef(user: { id: string | number; name?: string | null }): { ref: string | null; keyed: string } {
    const mode = this.options.identity();
    const keyed = `u_${hmac(this.options.key, String(user.id)).slice(0, 16)}`;
    return { ref: mode === "anonymous" ? null : mode === "named" && user.name ? user.name.slice(0, 120) : keyed, keyed };
  }

  // ---- glass.js ----------------------------------------------------------

  private serveScript(request: IncomingMessage, response: ServerResponse): void {
    if (!this.options.active()) {
      // Not a 404: a tag that is always in the page must not be an error in every console.
      response.writeHead(200, { "content-type": "application/javascript; charset=utf-8", "cache-control": "no-store", "content-length": "0" });
      response.end();
      return;
    }
    const script = (this.script ??= loadScript());
    const headers: Record<string, string> = { "content-type": "application/javascript; charset=utf-8", etag: script.etag, "cache-control": "public, max-age=86400", vary: "Accept-Encoding" };
    const sent = String(request.headers["if-none-match"] ?? "");
    if (sent.split(",").some((tag) => tag.trim().replace(/^W\//, "") === script.etag)) {
      response.writeHead(304, headers);
      response.end();
      return;
    }
    const gzip = /\bgzip\b/.test(String(request.headers["accept-encoding"] ?? ""));
    const body = gzip ? script.gzip : script.raw;
    if (gzip) headers["content-encoding"] = "gzip";
    headers["content-length"] = String(body.length);
    response.writeHead(200, headers);
    response.end(request.method === "HEAD" ? undefined : body);
  }

  // ---- beacons -----------------------------------------------------------

  /** Always a bare status: a page learns nothing from the relay. */
  private beacon(request: IncomingMessage, response: ServerResponse): void {
    if (!this.options.active()) return end(response, 204);
    if (!sameOrigin(request)) return end(response, 400);
    const type = String(request.headers["content-type"] ?? "");
    if (type !== "" && !type.startsWith("application/json") && !type.startsWith("text/plain")) return end(response, 400);

    const chunks: Buffer[] = [];
    let size = 0;
    let refused = false;
    request.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > MAX_BODY) refused = true;
      else chunks.push(chunk);
    });
    request.on("error", () => end(response, 400));
    request.on("end", () => {
      if (refused) return end(response, 413);
      try {
        const doc = JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown;
        if (!isRecord(doc) || typeof doc.visit !== "string" || !VISIT.test(doc.visit) || !Array.isArray(doc.events) || doc.events.length > MAX_EVENTS) return end(response, 400);
        this.relay(request, doc.visit, doc, doc.events);
        end(response, 204);
      } catch (error) {
        if (!(error instanceof SyntaxError)) this.options.onError?.("beacon", error);
        end(response, error instanceof SyntaxError ? 400 : 204);
      }
    });
  }

  private relay(request: IncomingMessage, visit: string, doc: Record<string, unknown>, events: unknown[]): void {
    const entry = this.take(visit);
    entry.events += events.length;
    this.put(visit, entry);
    // A visit no request has ever carried is allowed a small quota, so a page cannot flood the app's telemetry.
    if (!entry.seen && entry.events > UNSEEN_QUOTA) return;

    const { origin, address } = requestOrigin(request);
    const agent = String(request.headers["user-agent"] ?? "");
    const ua: Record<string, string> = { ...parseUserAgent(agent) };
    if (typeof doc.screen === "string" && /^\d{1,5}x\d{1,5}$/.test(doc.screen)) ua.screen = doc.screen;
    const lang = typeof doc.lang === "string" ? doc.lang.slice(0, 35) : null;
    // Plausible's scheme: countable across visits today, unlinkable tomorrow. The address is the hop that decided the
    // origin — never one a client wrote into its own X-Forwarded-For — and it is hashed, never stored.
    const visitor = entry.keyed ?? `a_${hmac(this.options.key, `${address ?? ""}|${agent}|${new Date().toISOString().slice(0, 10)}`).slice(0, 16)}`;

    const now = Date.now() / 1000;
    let referred = false;
    for (const event of events) {
      const record = this.record(event, now);
      if (!record) continue;
      record.visit = visit;
      record.visitor = visitor;
      if (entry.user) record.user = entry.user;
      record.ua = ua;
      if (lang) record.lang = lang;
      if (origin) record.origin = origin;
      if (record.ref !== undefined) {
        if (referred) delete record.ref;
        referred = true;
      }
      this.options.push(record as WireRecord);
    }
  }

  /** One browser event → one `page` record, or null. Only known shapes survive; anything with a query string loses it. */
  private record(event: unknown, now: number): Record<string, unknown> | null {
    if (!isRecord(event) || typeof event.kind !== "string" || !KINDS.has(event.kind)) return null;
    const kind = event.kind;
    const record: Record<string, unknown> = { t: "page", ts: timestamp(event.ts, now), kind };
    const path = str(event.path, 2000);
    if (path) record.path = bare(path);
    const route = str(event.route, 500);
    if (route) record.route = route;
    if (kind === "pageview") {
      const title = str(event.title, 200);
      if (title) record.title = title;
      const ref = str(event.ref, 2000);
      if (ref) record.ref = ref.split("?", 1)[0];
    } else if (kind === "vital") {
      const vitals = vitalsOf(event.vitals);
      if (!vitals) return null;
      record.vitals = vitals;
    } else {
      const name = str(event.name, 200);
      if (!name && (kind === "custom" || kind === "error")) return null;
      if (name) record.name = name;
      if (kind === "click" || kind === "submit") {
        const element = elementOf(event.el);
        if (element) record.el = element;
      }
      const raw = isRecord(event.props) ? event.props : null;
      const props = propsOf(raw);
      if (props) record.props = props;
      // What a person saw of a run belongs to the run's trace: the page names it, or names an id the app can map to it.
      const named = raw && typeof raw.trace === "string" && TRACE.test(raw.trace) ? raw.trace : null;
      const trace = named ?? (raw ? safely(() => this.options.traceFor?.(raw) ?? null) : null);
      if (trace && TRACE.test(trace)) record.trace = trace;
    }
    return record;
  }

  private take(visit: string): VisitEntry {
    const entry = this.visits.get(visit) ?? { seen: false, events: 0, user: null, keyed: null };
    this.visits.delete(visit);
    return entry;
  }

  private put(visit: string, entry: VisitEntry): void {
    this.visits.set(visit, entry);
    while (this.visits.size > MAX_VISITS) this.visits.delete(this.visits.keys().next().value!);
  }
}

/** A small, honest user-agent parser: browser, OS and device class, and nothing finer. The string itself never leaves the process. */
export function parseUserAgent(ua: string): { browser: string; os: string; device: string } {
  const os = /iPhone|iPad|iPod/.test(ua) ? "iOS" : ua.includes("Android") ? "Android" : /Mac OS X|Macintosh/.test(ua) ? "macOS" : ua.includes("Windows") ? "Windows" : /Linux|CrOS/.test(ua) ? "Linux" : "other";
  const browser = /Edg(e|A|iOS)?\//.test(ua) ? "Edge" : /Firefox|FxiOS/.test(ua) ? "Firefox" : /Chrome|CriOS|Chromium/.test(ua) ? "Chrome" : ua.includes("Safari") ? "Safari" : "other";
  const device = /iPad|Tablet/.test(ua) || (ua.includes("Android") && !ua.includes("Mobile")) ? "tablet" : /Mobi|iPhone|iPod/.test(ua) ? "phone" : "desktop";
  return { browser, os, device };
}

function loadScript(): { raw: Buffer; gzip: Buffer; etag: string } {
  const raw = readFileSync(new URL("./assets/glass.js", import.meta.url));
  return { raw, gzip: gzipSync(raw), etag: `"glass-${VERSION}-${createHash("sha256").update(raw).digest("hex").slice(0, 16)}"` };
}

/** A beacon is taken only from the app's own pages. */
function sameOrigin(request: IncomingMessage): boolean {
  const host = String(request.headers.host ?? "").toLowerCase();
  const origin = headerOf(request, "origin") ?? headerOf(request, "referer");
  if (!origin) return true;
  try {
    const url = new URL(origin);
    return url.host.toLowerCase() === host || url.hostname.toLowerCase() === host.split(":")[0];
  } catch {
    return false;
  }
}

/** A browser clock a day behind or minutes ahead is a broken clock; the record is stamped on arrival instead. */
function timestamp(value: unknown, now: number): number {
  return typeof value === "number" && Number.isFinite(value) && value >= now - 86_400 && value <= now + 300 ? value : now;
}

function str(value: unknown, max: number): string | null {
  if (typeof value !== "string") return null;
  const text = value.replaceAll("\u0000", "");
  return text === "" ? null : text.slice(0, max);
}

const bare = (path: string): string => path.split("?", 1)[0]!.split("#", 1)[0]!;

function elementOf(value: unknown): Record<string, string> | null {
  if (!isRecord(value)) return null;
  const out: Record<string, string> = {};
  for (const key of ["tag", "role", "sel"]) {
    const text = str(value[key], 200);
    if (text) out[key] = text;
  }
  const href = str(value.href, 2000);
  if (href?.startsWith("/")) out.href = bare(href);
  return Object.keys(out).length > 0 ? out : null;
}

function vitalsOf(value: unknown): Record<string, number> | null {
  if (!isRecord(value)) return null;
  const out: Record<string, number> = {};
  for (const key of VITALS) {
    const figure = value[key];
    if (typeof figure === "number" && Number.isFinite(figure) && figure >= 0) out[key] = figure;
  }
  return Object.keys(out).length > 0 ? out : null;
}

function propsOf(value: Record<string, unknown> | null): Record<string, string | number | boolean> | null {
  if (!value) return null;
  const out: Record<string, string | number | boolean> = {};
  for (const [key, raw] of Object.entries(value)) {
    if (Object.keys(out).length >= MAX_PROPS) break;
    const name = str(key, 80);
    if (!name || name === "trace") continue;
    if (FILTER_KEYS.test(name)) out[name] = FILTERED;
    else if (typeof raw === "string") out[name] = raw.slice(0, MAX_PROP_VALUE);
    else if ((typeof raw === "number" && Number.isFinite(raw)) || typeof raw === "boolean") out[name] = raw;
  }
  return Object.keys(out).length > 0 ? out : null;
}

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);
const hmac = (key: string, message: string): string => createHmac("sha256", key).update(message).digest("hex");

function end(response: ServerResponse, status: number): void {
  if (response.headersSent) return;
  response.writeHead(status, { "content-length": "0" });
  response.end();
}

function safely<T>(fn: () => T): T | null {
  try {
    return fn();
  } catch {
    return null;
  }
}
