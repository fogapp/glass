import type { AsyncLocalStorage } from "node:async_hooks";
import { channel as diagnosticsChannel, type Channel } from "node:diagnostics_channel";
import type { IncomingMessage, ServerResponse } from "node:http";
import type { Aggregator } from "./aggregator.ts";
import { newSpanId, newTraceId, parseTraceparent } from "./ids.ts";
import { requestOrigin } from "./net.ts";
import type { WireRecord } from "./transport.ts";

/** The request this code is executing under: what a run begun inside it continues. */
export interface RequestContext {
  trace: string;
  span: string;
  /** The browser visit the request belonged to (`X-Glass-Visit`), when it said. */
  visit: string | null;
  /** Who the app says is asking, once it has said (`glass.identify`): per the app's identity mode. */
  user: string | null;
}

export interface InboundOptions {
  enabled: () => boolean;
  context: AsyncLocalStorage<RequestContext>;
  push: (record: WireRecord) => void;
  aggregator: Aggregator;
  /** Paths that are not worth a row: health checks, static files. */
  ignore?: (path: string) => boolean;
  /** A request carried a visit id: the browser relay is told the visit is real. */
  onVisit?: (visit: string) => void;
  onError?: (where: string, error: unknown) => void;
}

interface Pending {
  context: RequestContext;
  parent: string | null;
  startedAt: number;
  method: string;
  path: string;
}

const ID = /^(\d+|[0-9a-f]{8,}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i;
const STATIC = /\.(?:js|mjs|css|map|png|jpe?g|gif|svg|ico|webp|woff2?|ttf|txt|webmanifest)$/i;

/** `/wants/8c1f2a90` → `/wants/:id`: the template a path is an instance of, as glass.js derives it. */
export function routeOf(path: string): string {
  return path.replace(/\/[^/]+/g, (segment) => (ID.test(segment.slice(1)) ? "/:id" : segment));
}

/** Health checks and static files: requests nobody will ever ask about. */
export function ignoredByDefault(path: string): boolean {
  return path === "/up" || path === "/healthz" || path.startsWith("/_glass/") || STATIC.test(path);
}

/**
 * Every request the process serves, as a `request` transaction — from
 * Node's own `diagnostics_channel` events, so whatever framework sits on top
 * (Fastify, a bare http server) needs nothing added to it. The request also
 * becomes the ambient context for whatever it sets going: a run begun while
 * serving it continues its trace.
 *
 * Method, path and status only: never a query string, a header or a body.
 */
export function captureInbound(options: InboundOptions): () => void {
  const pending = new WeakMap<object, Pending>();
  const ignore = options.ignore ?? ignoredByDefault;
  const guard = (fn: () => void) => {
    try {
      fn();
    } catch (error) {
      options.onError?.("inbound", error);
    }
  };

  const onStart = (message: unknown) =>
    guard(() => {
      const { request } = message as { request: IncomingMessage };
      if (!options.enabled()) return;
      const path = (request.url ?? "/").split("?", 1)[0] || "/";
      if (ignore(path)) return;
      const remote = parseTraceparent(request.headers.traceparent);
      const visit = request.headers["x-glass-visit"];
      const context: RequestContext = { trace: remote?.trace ?? newTraceId(), span: newSpanId(), visit: typeof visit === "string" ? visit.slice(0, 64) : null, user: null };
      if (context.visit) options.onVisit?.(context.visit);
      pending.set(request, { context, parent: remote?.span ?? null, startedAt: Date.now(), method: (request.method ?? "GET").toUpperCase(), path });
      // For the rest of this request: on this path and on everything it starts.
      options.context.enterWith(context);
    });

  const onFinish = (message: unknown) =>
    guard(() => {
      const { request, response } = message as { request: IncomingMessage; response: ServerResponse };
      const entry = pending.get(request);
      if (!entry) return;
      pending.delete(request);
      const duration = Date.now() - entry.startedAt;
      const route = routeOf(entry.path);
      const status = response.statusCode;
      const { origin } = requestOrigin(request);
      const record: Record<string, unknown> = {
        t: "txn", ts: entry.startedAt / 1000, kind: "request", name: `${entry.method} ${route}`,
        trace: entry.context.trace, span: entry.context.span, dur: duration,
        status: status >= 500 ? "error" : "ok", method: entry.method, route, path: entry.path.slice(0, 2000), http: status,
      };
      if (entry.parent) record.parent = entry.parent;
      if (entry.context.visit) record.visit = entry.context.visit;
      if (entry.context.user) record.user = entry.context.user;
      if (origin) record.origin = origin;
      options.push(record as WireRecord);

      const at = Math.floor(entry.startedAt / 1000);
      const tags = { method: entry.method, route, status: `${Math.floor(status / 100)}xx` };
      options.aggregator.counter("http.server.requests", 1, tags, undefined, at);
      options.aggregator.dist("http.server.duration", duration, { method: entry.method, route }, "ms", at);
    });

  const subscriptions: [Channel, (message: unknown) => void][] = [
    [diagnosticsChannel("http.server.request.start"), onStart],
    [diagnosticsChannel("http.server.response.finish"), onFinish],
  ];
  for (const [channel, handler] of subscriptions) channel.subscribe(handler);
  return () => {
    for (const [channel, handler] of subscriptions) channel.unsubscribe(handler);
  };
}
