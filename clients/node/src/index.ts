import { Glass } from "./client.ts";

/**
 * The process's agent. `glass.start()` once at boot; everything else is safe
 * to call whether or not it was started.
 */
export const glass = new Glass();

export { Glass, type LogLevel, type GlassOptions } from "./client.ts";
export { BEACON_ROUTE, BrowserRelay, parseUserAgent, SCRIPT_ROUTE, SCRIPT_TAG } from "./browser.ts";
export { captureOutbound, ours } from "./http.ts";
export { captureInbound, ignoredByDefault, routeOf, type RequestContext } from "./inbound.ts";
export { addressKind, FILTER_KEYS, FILTERED, originOf, type Origin } from "./net.ts";
export { captureConsole } from "./logs.ts";
export { describeFrame, fold, Profiler, type CpuProfile } from "./profiler.ts";
export { Runtime } from "./runtime.ts";
export { accountFor, adoptCaptured, cleanAttrs, longestSilence, RunScope, type Attrs, type FinishOptions, type ModelCallInput, type Phases, type RunOptions, type SpanInput, type SpanKind } from "./run.ts";
export { idFrom, newSpanId, newTraceId, parseTraceparent, traceparent } from "./ids.ts";
export { Aggregator, type MetricRecord, type Tags } from "./aggregator.ts";
export { Sketch } from "./sketch.ts";
export { Transport, type Directives, type RecordType, type Sender, type SendResult, type WireRecord } from "./transport.ts";
export { VERSION } from "./version.ts";
