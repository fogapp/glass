import { createHash, randomBytes } from "node:crypto";

/** A new trace id: 128 bits as 32 lowercase hex characters (W3C Trace Context). */
export const newTraceId = (): string => randomBytes(16).toString("hex");

/** A new span id: 64 bits as 16 lowercase hex characters. */
export const newSpanId = (): string => randomBytes(8).toString("hex");

/**
 * An id derived from one the app already has. An app with ids of its own
 * (a run id, a span id) maps them here, so the same run is the same trace
 * however many times it is reported or looked up.
 */
export const idFrom = (source: string, hexLength: 16 | 32): string => createHash("sha256").update(source).digest("hex").slice(0, hexLength);

const TRACEPARENT = /^00-([0-9a-f]{32})-([0-9a-f]{16})-[0-9a-f]{2}$/;

export const traceparent = (trace: string, span: string): string => `00-${trace}-${span}-01`;

export function parseTraceparent(value: unknown): { trace: string; span: string } | null {
  if (typeof value !== "string") return null;
  const match = TRACEPARENT.exec(value.trim().toLowerCase());
  return match ? { trace: match[1]!, span: match[2]! } : null;
}
