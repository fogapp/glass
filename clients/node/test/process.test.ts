import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { test } from "node:test";
import { format } from "node:util";
import { originOf, routeOf, traceparent } from "../src/index.ts";
import { testAgent } from "./helpers.ts";

test("samples the process's own vitals once per flush", async () => {
  const { agent, sent, advance } = testAgent(undefined, { vitals: true });
  await new Promise((resolve) => setTimeout(resolve, 200)); // long enough for the event-loop monitor to tick, even on a busy machine
  advance(20_000);
  await agent.flush(true);
  await agent.stop();
  const metrics = Object.fromEntries(sent.flatMap((batch) => batch.records).filter((record) => record.t === "metric").map((record) => [record.name, record]));
  for (const name of ["node.memory.rss_bytes", "node.heap.used_bytes", "node.eventloop.delay_ms", "node.eventloop.delay_p99_ms", "node.handles", "node.cpu.user_ms", "node.gc.count"]) assert.ok(metrics[name], name);
  assert.deepEqual([metrics["node.memory.rss_bytes"]!.kind, metrics["node.memory.rss_bytes"]!.unit, metrics["node.memory.rss_bytes"]!.tags], ["gauge", "bytes", { process: "gateway" }]);
  assert.ok(metrics["node.memory.rss_bytes"]!.last > 1e6);
  assert.equal(metrics["node.cpu.user_ms"]!.kind, "counter");
  assert.ok(metrics["node.eventloop.delay_ms"]!.last >= 0);
});

test("ships what the process writes to the console, and leaves the console as it was", async () => {
  const printed: string[] = [];
  const realLog = console.log;
  const realError = console.error;
  console.log = (...args: unknown[]) => void printed.push(format(...args));
  console.error = (...args: unknown[]) => void printed.push(format(...args));
  try {
    const { agent, sent } = testAgent(undefined, { console: true });
    console.log("[Fleet] released %s after %d s", "tsk_1", 30);
    console.error("plain failure", { code: 7 });
    let trace = "";
    await agent.run({ name: "owner-chat" }, async (run) => {
      trace = run.trace;
      console.log("[runtime] inside a run");
    });
    await agent.flush(true);
    await agent.stop();
    console.log("after stop");

    assert.deepEqual(printed, ["[Fleet] released tsk_1 after 30 s", "plain failure { code: 7 }", "[runtime] inside a run", "after stop"], "the console still prints what it printed");
    const logs = sent.flatMap((batch) => batch.records).filter((record) => record.t === "log");
    assert.deepEqual(logs.map((record) => [record.lvl, record.src, record.msg]), [
      ["info", "fleet", "released tsk_1 after 30 s"], ["error", "console", "plain failure { code: 7 }"], ["info", "runtime", "inside a run"],
    ]);
    assert.equal(logs[2]!.trace, trace);
    assert.equal(logs[0]!.trace, undefined);
  } finally {
    console.log = realLog;
    console.error = realError;
  }
});

test("derives a route from a path and a network class from an address", () => {
  assert.equal(routeOf("/wants/8c1f2a90/attempts/42"), "/wants/:id/attempts/:id");
  assert.equal(routeOf("/trpc/chat.send"), "/trpc/chat.send");
  assert.equal(routeOf("/sessions/0f8fad5b-d9cb-469f-a165-70867728950e"), "/sessions/:id");
  // Every case the gem is held to, from the conformance kit: the class, and the address a visitor is hashed from.
  const kit = JSON.parse(readFileSync(new URL("../../../spec/fixtures/ingest/origin.json", import.meta.url), "utf8")) as { cases: Record<string, string | null>[] };
  for (const kase of kit.cases) {
    const got = originOf(kase.remote ?? undefined, kase.forwarded ?? undefined, kase.cf_connecting_ip ?? undefined, kase.cf_ray ?? undefined);
    assert.deepEqual(got, { origin: kase.origin, address: kase.address }, JSON.stringify(kase));
  }
});

test("records every request served, continues an incoming trace, and is the context of what a request sets going", async () => {
  const { agent, sent } = testAgent(undefined, { inbound: {} });
  let seenInside: string | null = null;
  const server = createServer(async (request, response) => {
    if (request.url?.startsWith("/turn")) {
      seenInside = agent.currentRequest()?.span ?? null;
      // A run begun while serving a request is the work that request set going.
      await agent.run({ name: "owner-chat", trigger: "console" }, async () => {
        await new Promise((resolve) => setTimeout(resolve, 5));
      });
    }
    response.statusCode = request.url?.startsWith("/broken") ? 500 : 200;
    response.end("ok");
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  const base = `http://127.0.0.1:${port}`;
  const remote = { trace: "4bf92f3577b34da6a3ce929d0e0e4736", span: "00f067aa0ba902b7" };

  await (await fetch(`${base}/wants/123456789?secret=in-a-query`, { headers: { traceparent: traceparent(remote.trace, remote.span), "x-glass-visit": "v_51aa" } })).text();
  await (await fetch(`${base}/turn`, { method: "POST" })).text();
  await (await fetch(`${base}/broken`)).text();
  await (await fetch(`${base}/healthz`)).text();
  await (await fetch(`${base}/assets/index.js`)).text();
  assert.equal(agent.currentRequest(), null, "no request is ambient outside one");
  await agent.flush(true);
  await agent.stop();
  await new Promise<void>((resolve) => server.close(() => resolve()));

  const records = sent.flatMap((batch) => batch.records);
  const requests = records.filter((record) => record.t === "txn" && record.kind === "request");
  assert.deepEqual(requests.map((record) => [record.name, record.path, record.http, record.status, record.origin]), [
    ["GET /wants/:id", "/wants/123456789", 200, "ok", "lan"], ["POST /turn", "/turn", 200, "ok", "lan"], ["GET /broken", "/broken", 500, "error", "lan"],
  ]);
  assert.deepEqual([requests[0]!.trace, requests[0]!.parent, requests[0]!.visit], [remote.trace, remote.span, "v_51aa"]);
  assert.equal(JSON.stringify(records).includes("secret-in-a-query"), false);

  const run = records.find((record) => record.t === "txn" && record.kind === "run")!;
  assert.deepEqual([run.trace, run.parent], [requests[1]!.trace, requests[1]!.span]);
  assert.equal(seenInside, requests[1]!.span);

  const counted = records.filter((record) => record.t === "metric" && record.name === "http.server.requests").map((record) => [record.tags.route, record.tags.status, record.sum]);
  assert.deepEqual(counted.sort(), [["/broken", "5xx", 1], ["/turn", "2xx", 1], ["/wants/:id", "2xx", 1]]);
});
