import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { test } from "node:test";
import { adoptCaptured, ours, parseTraceparent } from "../src/index.ts";
import { testAgent } from "./helpers.ts";

test("knows which hosts are ours", () => {
  // Every case the gem and the Go client are held to, from the conformance kit.
  const kit = JSON.parse(readFileSync(new URL("../../../spec/fixtures/ingest/origin.json", import.meta.url), "utf8")) as {
    propagate_to: string[];
    propagate: { host: string; propagate: boolean }[];
  };
  for (const kase of kit.propagate) assert.equal(ours(kase.host, kit.propagate_to), kase.propagate, kase.host);
  for (const host of ["localhost", "127.0.0.1", "10.0.4.2", "192.168.1.50", "172.20.0.3", "100.88.12.34", "hook", "glass", "::1", "[fd7a:115c::1]"]) assert.equal(ours(host), true, host);
  for (const host of ["api.anthropic.com", "8.8.8.8", "172.32.0.1", "app.example.net", "2606:4700::1111", ""]) assert.equal(ours(host), false, host);
  assert.equal(ours("app.example.net", ["example.net"]), true);
  assert.equal(ours("example.net", [".example.net"]), true);
  assert.equal(ours("notexample.net", ["example.net"]), false);
});

test("records an outbound fetch under a run as an http span, and continues the trace into one of ours", async () => {
  const seen: { url: string; traceparent: string | undefined }[] = [];
  const server = createServer((request, response) => {
    seen.push({ url: request.url ?? "", traceparent: request.headers.traceparent as string | undefined });
    response.statusCode = request.url?.startsWith("/broken") ? 503 : 200;
    response.end("ok");
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  const base = `http://127.0.0.1:${port}`;

  const { agent, sent } = testAgent();
  let trace = "";
  await agent.run({ name: "owner-chat" }, async (run) => {
    trace = run.trace;
    await agent.span("tool", "mcp_hook_search", async () => {
      await (await fetch(`${base}/mcp?token=secret-in-a-query`, { method: "POST", body: "{}" })).text();
    });
    await (await fetch(`${base}/broken`)).text();
  });
  // Outside any run: nothing to be a step of, nothing recorded, nothing injected.
  await (await fetch(`${base}/outside`)).text();
  await agent.flush(true);
  await agent.stop();
  await new Promise<void>((resolve) => server.close(() => resolve()));

  const spans = sent.flatMap((batch) => batch.records).filter((record) => record.t === "span");
  const tool = spans.find((span) => span.kind === "tool")!;
  const [post, broken] = spans.filter((span) => span.kind === "http");
  assert.deepEqual([post!.name, post!.res, post!.status, post!.attrs], [`POST 127.0.0.1:${port}`, `POST 127.0.0.1:${port}/mcp`, "ok", { status: 200 }]);
  assert.equal(post!.parent, tool.span, "hung under the step that was happening");
  assert.deepEqual([broken!.res, broken!.status, broken!.attrs.status], [`GET 127.0.0.1:${port}/broken`, "error", 503]);
  assert.notEqual(broken!.parent, tool.span);

  assert.equal(JSON.stringify(spans).includes("secret-in-a-query"), false, "a query string never leaves");
  assert.deepEqual(parseTraceparent(seen[0]!.traceparent), { trace, span: post!.span });
  assert.equal(seen[2]!.traceparent, undefined);

  const txn = sent.flatMap((batch) => batch.records).find((record) => record.t === "txn")!;
  assert.equal(txn.ext_n, 2);
});

test("a captured span is hung under the narrowest step that contains it", () => {
  const spans = [
    { id: "tool", kind: "tool" as const, name: "shell", startedAt: 1000, durMs: 5000 },
    { id: "gate", kind: "custom" as const, name: "gate", startedAt: 1000, durMs: 900, parent: "tool" },
    { id: "h1", kind: "http" as const, name: "POST local", startedAt: 1010, durMs: 800, captured: true },
    { id: "h2", kind: "http" as const, name: "GET far", startedAt: 9000, durMs: 100, captured: true },
    { id: "h3", kind: "http" as const, name: "kept", startedAt: 1010, durMs: 800, captured: true, parent: "explicit" },
  ];
  adoptCaptured(spans, "root");
  assert.deepEqual(spans.map((span) => (span as { parent?: string }).parent), [undefined, "tool", "gate", "root", "explicit"]);
});
