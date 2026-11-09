import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { test } from "node:test";
import { parseUserAgent } from "../src/index.ts";
import { testAgent } from "./helpers.ts";

const SAFARI = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
const VISIT = "v_3f9a1c2d8b7e";

/** An app with the relay mounted ahead of its own routes, as an app would mount it. */
async function app(browser: boolean, traceFor?: (props: Record<string, unknown>) => string | null) {
  const { agent, sent } = testAgent(() => ({ body: JSON.stringify({ directives: { browser, identity: "pseudonymous" } }) }), { inbound: {}, traceFor });
  await agent.flush(); // the directives arrive in a reply
  const server = createServer((request, response) => {
    if (agent.handleBrowser(request, response)) return;
    if (request.url === "/api/me") agent.identify({ id: 42, name: "Matthew" });
    response.end("ok");
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const beacon = (events: unknown[], init: { visit?: string; headers?: Record<string, string>; body?: string } = {}) =>
    fetch(`${base}/_glass/b`, { method: "POST", headers: { "content-type": "text/plain", "user-agent": SAFARI, ...init.headers }, body: init.body ?? JSON.stringify({ visit: init.visit ?? VISIT, lang: "en-US", screen: "390x844", events }) });
  const pages = async () => {
    await agent.flush(true);
    return sent.flatMap((batch) => batch.records).filter((record) => record.t === "page");
  };
  const close = async () => {
    await agent.stop();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  };
  return { agent, base, beacon, pages, close, sent };
}

test("ships the same glass.js the gem does", () => {
  assert.deepEqual(readFileSync(new URL("../src/assets/glass.js", import.meta.url)), readFileSync(new URL("../../browser/glass.js", import.meta.url)), "clients/node/src/assets/glass.js has drifted from clients/browser/glass.js — copy it across");
});

test("while the browser directive is off, the tag costs nothing and says nothing", async () => {
  const { base, beacon, pages, close } = await app(false);
  const script = await fetch(`${base}/_glass/glass.js`);
  assert.deepEqual([script.status, await script.text(), script.headers.get("cache-control")], [200, "", "no-store"]);
  assert.equal((await beacon([{ kind: "pageview", path: "/" }])).status, 204);
  assert.equal((await fetch(`${base}/_glass/anything`)).status, 404);
  assert.deepEqual(await pages(), []);
  await close();
});

test("serves glass.js from the app's own origin, cacheably", async () => {
  const { base, close } = await app(true);
  const first = await fetch(`${base}/_glass/glass.js`);
  assert.equal(first.status, 200);
  assert.match(first.headers.get("content-type") ?? "", /javascript/);
  assert.ok((await first.text()).includes("X-Glass-Visit"));
  const etag = first.headers.get("etag")!;
  assert.equal((await fetch(`${base}/_glass/glass.js`, { headers: { "if-none-match": etag } })).status, 304);
  await close();
});

test("turns a beacon into page records, stamped with what only the server knows", async () => {
  const run = "run_01j9";
  const trace = "7d3c0e1a9b8f4c62a1e5d4c3b2a19087";
  const { base, beacon, pages, close } = await app(true, (props) => (props.run === run ? trace : null));
  // A request carries the visit, and the app says who it is for: the page never learns that.
  await (await fetch(`${base}/api/me`, { headers: { "x-glass-visit": VISIT } })).text();

  const now = Date.now() / 1000;
  const response = await beacon([
    { kind: "pageview", ts: now, path: "/chat/ses_81c4?draft=secret", route: "/chat/:id", title: "aio · Chat", ref: "https://portal.example.net/today?x=1" },
    { kind: "click", ts: now, path: "/chat/ses_81c4", name: "Send", el: { tag: "button", role: "button", sel: "form > button.primary", href: "javascript:alert(1)" }, props: { password: "hunter2" } },
    { kind: "custom", ts: now, name: "answer.painted", props: { run, ms: 41_300, nested: { no: 1 } } },
    { kind: "custom", ts: now, name: "named", props: { trace: "0af7651916cd43dd8448eb211c80319c" } },
    { kind: "vital", ts: now, vitals: { lcp: 1840, inp: 120, cls: 0.02, bogus: "x" } },
    { kind: "keylogger", value: "typed" },
    { kind: "custom" },
    "not an event",
  ]);
  assert.equal(response.status, 204);
  assert.equal(await response.text(), "", "a page learns nothing from the relay");

  const records = await pages();
  assert.deepEqual(records.map((record) => [record.kind, record.name ?? null]), [["pageview", null], ["click", "Send"], ["custom", "answer.painted"], ["custom", "named"], ["vital", null]]);
  const [view, click, painted, named, vital] = records;
  assert.deepEqual([view!.path, view!.route, view!.title, view!.ref], ["/chat/ses_81c4", "/chat/:id", "aio · Chat", "https://portal.example.net/today"]);
  assert.deepEqual(view!.ua, { browser: "Safari", os: "iOS", device: "phone", screen: "390x844" });
  assert.deepEqual([view!.visit, view!.lang, view!.origin], [VISIT, "en-US", "lan"]);
  assert.match(view!.user, /^u_[0-9a-f]{16}$/);
  assert.equal(view!.visitor, view!.user, "an identified visit is the same person across visits");
  assert.deepEqual(click!.el, { tag: "button", role: "button", sel: "form > button.primary" });
  assert.deepEqual(click!.props, { password: "[FILTERED]" });
  assert.deepEqual([painted!.trace, painted!.props], [trace, { run, ms: 41_300 }]);
  assert.deepEqual([named!.trace, named!.props], ["0af7651916cd43dd8448eb211c80319c", undefined]);
  assert.deepEqual(vital!.vitals, { lcp: 1840, inp: 120, cls: 0.02 });
  assert.equal(JSON.stringify(records).includes("secret"), false);
  assert.equal(JSON.stringify(records).includes("hunter2"), false);
  await close();
});

test("refuses a beacon from another origin, one too large, and one that is not a beacon", async () => {
  const { beacon, pages, close } = await app(true);
  assert.equal((await beacon([{ kind: "pageview" }], { headers: { origin: "https://evil.example" } })).status, 400);
  assert.equal((await beacon([], { body: "x".repeat(70_000) })).status, 413);
  assert.equal((await beacon([], { body: "not json" })).status, 400);
  assert.equal((await beacon([], { visit: "not-a-visit" })).status, 400);
  assert.equal((await beacon([], { headers: { "content-type": "application/x-www-form-urlencoded" } })).status, 400);
  assert.deepEqual(await pages(), []);
  await close();
});

test("gives a visit no request has vouched for a small quota, and an anonymous visitor a hash that is not their address", async () => {
  const { beacon, pages, close } = await app(true);
  const event = { kind: "click", name: "x" };
  for (let round = 0; round < 3; round += 1) await beacon(Array(30).fill(event), { visit: "v_aaaaaaaaaaaa" });
  const records = await pages();
  assert.equal(records.length, 30, "past fifty events the visit is dropped, silently");
  assert.match(records[0]!.visitor, /^a_[0-9a-f]{16}$/);
  assert.equal(records[0]!.user, undefined);
  assert.equal(JSON.stringify(records).includes("127.0.0.1"), false);
  await close();
});

test("reads a browser, an OS and a device class from a user agent, and nothing finer", () => {
  assert.deepEqual(parseUserAgent(SAFARI), { browser: "Safari", os: "iOS", device: "phone" });
  assert.deepEqual(parseUserAgent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"), { browser: "Chrome", os: "macOS", device: "desktop" });
  assert.deepEqual(parseUserAgent("Mozilla/5.0 (Linux; Android 14; SM-X710) AppleWebKit/537.36 Chrome/131.0 Safari/537.36"), { browser: "Chrome", os: "Android", device: "tablet" });
  assert.deepEqual(parseUserAgent(""), { browser: "other", os: "other", device: "desktop" });
});

test("stamps a request with who the app says it is for", async () => {
  const { base, pages, close, sent, agent } = await app(true);
  await (await fetch(`${base}/api/me`)).text();
  await pages();
  const request = sent.flatMap((batch) => batch.records).find((record) => record.t === "txn" && record.path === "/api/me")!;
  assert.match(request.user, /^u_[0-9a-f]{16}$/);
  agent.identify({ id: 1 }); // outside any request: nothing to stamp, nothing thrown
  await close();
});

test("hashes a visitor from the hop that decided their origin, never one they wrote themselves", async () => {
  const { beacon, pages, close } = await app(true);
  const event = { kind: "pageview", path: "/" };
  // The same person behind the same proxy, claiming a different address each time: one visitor.
  await beacon([event], { visit: "v_aaaaaaaaaaa1", headers: { "x-forwarded-for": "1.2.3.4, 203.0.113.9" } });
  await beacon([event], { visit: "v_aaaaaaaaaaa2", headers: { "x-forwarded-for": "5.6.7.8, 203.0.113.9" } });
  // Someone else: another visitor.
  await beacon([event], { visit: "v_aaaaaaaaaaa3", headers: { "x-forwarded-for": "1.2.3.4, 198.51.100.4" } });
  // Behind Cloudflare, a bare CF-Ray is a tunnel too.
  await beacon([event], { visit: "v_aaaaaaaaaaa4", headers: { "cf-ray": "8c1f2a90b1d2e3f4-LHR" } });
  const [first, second, third, tunnelled] = await pages();
  assert.equal(first!.visitor, second!.visitor);
  assert.notEqual(first!.visitor, third!.visitor);
  assert.equal(first!.origin, "public");
  assert.equal(tunnelled!.origin, "tunnel");
  await close();
});
