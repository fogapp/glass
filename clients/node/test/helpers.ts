import { gunzipSync } from "node:zlib";
import { Glass, type SendResult } from "../src/index.ts";

export interface Sent {
  header: Record<string, any>;
  records: Record<string, any>[];
  headers: Record<string, string>;
}

/** A started agent whose sends land in an array instead of on the network. */
export function testAgent(reply: (sent: Sent) => Partial<SendResult> = () => ({}), options: Record<string, unknown> = {}) {
  const sent: Sent[] = [];
  let now = 1_790_000_120_000;
  const agent = new Glass().start({
    url: "http://glass.test", key: "glass_ing_test", process: "gateway", release: "5cec02a", host: "studio",
    flushIntervalMs: 3_600_000, now: () => now, vitals: false, inbound: false, profiles: "off",
    sender: async (body, headers) => {
      const lines = gunzipSync(body).toString("utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
      const batch = { header: lines[0], records: lines.slice(1), headers };
      sent.push(batch);
      return { status: 202, body: JSON.stringify({ accepted: batch.records.length, skipped: 0, directives: {} }), retryAfter: null, ...reply(batch) };
    },
    ...options,
  });
  return { agent, sent, advance: (ms: number) => (now += ms), at: () => now };
}
