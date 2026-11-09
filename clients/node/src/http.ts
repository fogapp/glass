import { channel as diagnosticsChannel, type Channel } from "node:diagnostics_channel";
import { newSpanId, traceparent } from "./ids.ts";
import { addressKind } from "./net.ts";
import type { RunScope } from "./run.ts";

/** What `undici:request:*` hands a subscriber. Typed here because Node does not export it. */
interface UndiciRequest {
  origin?: string | URL;
  method?: string;
  path?: string;
  addHeader?: (name: string, value: string) => void;
}

export interface OutboundOptions {
  /** The run this code is executing under, if any. */
  currentRun: () => RunScope | null;
  enabled: () => boolean;
  /** Glass's own URL: a report about a report would feed on itself. */
  ignoreOrigin: string;
  /**
   * Host suffixes that are ours, beyond private addresses and bare hostnames:
   * `example.net` lets `app.example.net` continue the trace.
   */
  propagateTo?: readonly string[];
  onError?: (where: string, error: unknown) => void;
}

interface Pending {
  run: RunScope;
  id: string;
  startedAt: number;
  name: string;
  res: string;
  status: number | null;
}

const MAX_PATH = 200;

/** Names that only resolve inside a home network: a router's `.lan`, mDNS's `.local`, ICANN's private-use `.internal`. */
export const INTERNAL_SUFFIXES: readonly string[] = ["lan", "local", "internal"];

/**
 * Whether a host is one of ours — never the public internet, where
 * `traceparent` would hand trace ids to a third party for no benefit. An
 * address is ours when the origin rule does not call it public (private,
 * CGNAT); a name is ours when it is bare (a container network's names) or
 * is or ends in one of `INTERNAL_SUFFIXES` or the suffixes the app names.
 * Every client's rule: the conformance kit's `origin.json` holds them to it.
 */
export function ours(host: string, suffixes: readonly string[] = []): boolean {
  const name = host.replace(/^\[|\]$/g, "").toLowerCase();
  if (!name) return false;
  const kind = addressKind(name);
  if (kind) return kind !== "public";
  if (!name.includes(".")) return true;
  return [...INTERNAL_SUFFIXES, ...suffixes].some((suffix) => {
    const want = suffix.replace(/^\./, "").toLowerCase();
    return want !== "" && (name === want || name.endsWith(`.${want}`));
  });
}

/**
 * Every outbound `fetch` made under a run, as an `http` span — a model
 * provider, an embedding server, an MCP server, a speech endpoint — with no
 * patching: Node's own HTTP client says what it is doing on
 * `diagnostics_channel`. A request to one of ours carries `traceparent`, so
 * the app at the other end continues the trace and a tool call here is one
 * waterfall with the request it made there.
 *
 * Only the method, the host and the path are recorded: never a query string,
 * a header or a body.
 */
export function captureOutbound(options: OutboundOptions): () => void {
  const pending = new WeakMap<object, Pending>();
  const ignore = options.ignoreOrigin.replace(/\/+$/, "");
  const guard = (where: string, fn: () => void) => {
    try {
      fn();
    } catch (error) {
      options.onError?.(where, error);
    }
  };

  const onCreate = (message: unknown) =>
    guard("http", () => {
      const request = (message as { request?: UndiciRequest }).request;
      if (!request || !options.enabled()) return;
      const run = options.currentRun();
      if (!run) return;
      const origin = String(request.origin ?? "");
      if (!origin || origin.replace(/\/+$/, "") === ignore) return;
      const host = new URL(origin).host;
      const method = (request.method ?? "GET").toUpperCase();
      const path = (request.path ?? "/").split("?", 1)[0]!.slice(0, MAX_PATH);
      const id = newSpanId();
      pending.set(request, { run, id, startedAt: Date.now(), name: `${method} ${host}`, res: `${method} ${host}${path}`, status: null });
      if (ours(new URL(origin).hostname, options.propagateTo)) request.addHeader?.("traceparent", traceparent(run.trace, id));
    });

  const onHeaders = (message: unknown) =>
    guard("http", () => {
      const { request, response } = message as { request?: object; response?: { statusCode?: number } };
      const entry = request && pending.get(request);
      if (entry && typeof response?.statusCode === "number") entry.status = response.statusCode;
    });

  const finish = (failed: boolean) => (message: unknown) =>
    guard("http", () => {
      const request = (message as { request?: object }).request;
      const entry = request && pending.get(request);
      if (!request || !entry) return;
      pending.delete(request);
      entry.run.addSpan({
        kind: "http",
        name: entry.name,
        res: entry.res,
        startedAt: entry.startedAt,
        durMs: Date.now() - entry.startedAt,
        status: failed || (entry.status !== null && entry.status >= 500) ? "error" : "ok",
        attrs: entry.status === null ? undefined : { status: entry.status },
        id: entry.id,
        captured: true,
      });
    });

  const subscriptions: [Channel, (message: unknown) => void][] = [
    [diagnosticsChannel("undici:request:create"), onCreate],
    [diagnosticsChannel("undici:request:headers"), onHeaders],
    // The body has been read to its end: for a streamed answer, that is when the call is over.
    [diagnosticsChannel("undici:request:trailers"), finish(false)],
    [diagnosticsChannel("undici:request:error"), finish(true)],
  ];
  for (const [channel, handler] of subscriptions) channel.subscribe(handler);
  return () => {
    for (const [channel, handler] of subscriptions) channel.unsubscribe(handler);
  };
}
