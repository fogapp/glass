# glass-client — the Glass agent for Node

Reports a long-lived Node process to [Glass](../../README.md) over
[`glass-ingest/1`](../../docs/ingest-protocol.md), with the pieces an agent
harness needs: runs,
their spans, and every model call.

No runtime dependencies: `node:` modules only. TypeScript source, erasable
syntax only, so Node 24 runs it as it is and `tsx` does too. Canonical here;
apps vendor it with `bin/sync-client <app>` (into `packages/glass`).

```ts
import { glass } from "glass-client";

glass.start({ url, key, process: "gateway", release: gitSha });   // inert without a url and a key

// One thing asked of the harness: an envelope from taking the message to
// handing over the reply. Nothing is sent until it finishes.
const run = glass.startRun({ name: "owner-chat", agent: "owner-chat", session, trigger: "message", channel: "telegram" });
const span = run.addSpan({ kind: "model", name: "anthropic-api", res: model, startedAt, durMs });
const call = run.modelCall({ provider: "anthropic-api", model, startedAt, durMs, ttftMs, inputTokens, outputTokens, costUsd, span });
call.toolsValid = 1;            // learned later: the record is held until the run ends
run.visible(true);              // answer text reached the person
run.finish({ stop: "ok" });

// Or ambient, for code that is not handed the run:
await glass.run({ name: "home-ops", trigger: "cron" }, async () => {
  await glass.span("memory", "contribute", () => memory.contribute(ctx));
});

glass.modelCall({ provider, model, purpose: "title", origin: "internal", startedAt, durMs });   // outside any run
glass.marker("Model version changed: qwen3:8b");
glass.gauge("fleet.running", 3);
glass.log("warn", "approval expired");
```

## What a run becomes

One `txn` of kind `run`, its `span`s, and one `llm` per model call. The
client works out what only the end of a run can say:

- **the phases** — queue, prepare, model, tool, waiting on a person,
  deliver — each millisecond counted once: overlapping steps cannot add up
  to more than the run, and a `wait` span anywhere under a tool is taken out
  of the tool's time. What no span covers is the server's `untracked`.
- **what it spent** — tokens and cost over every call (a `shadow` cost is
  not money spent, and is left out of the run's total).
- **what the person saw** — `ttft_ms` from the first `visible(true)`,
  `stall_ms` as the longest silence between `visible()` marks with the time
  spent waiting on the person taken out.

And from every model call and tool span, the counters and distributions that
outlive the rows: `ai.calls`, `ai.cost`, `ai.tokens`, `ai.duration`,
`ai.ttft`, `ai.runs`, `ai.run.active`, `ai.tool.calls`, `ai.tool.duration`.

## Outbound HTTP, with no patching

Every `fetch` made under a run is recorded as an `http` span — a model
provider, an embedding server, an MCP server — from Node's own
`diagnostics_channel` events, and hung under the step that was happening
when it ran. Method, host and path only: never a query string, a header or
a body. A request to one of yours (a private or VPN address, a bare
hostname, a `.lan`, `.local` or `.internal` name, or a suffix named in
`outbound.propagateTo`) carries `traceparent`, so the app at
the other end continues the trace; nothing on the public internet is sent
one.

```ts
glass.start({ url, key, outbound: { propagateTo: ["example.net"] } });   // or outbound: false
```

## The process itself

Three more things are captured from Node's own events, with nothing added
to the app:

- **Requests served** (`http.server.*` on `diagnostics_channel`): a
  `request` transaction per request, under whatever framework is on top.
  Method, path and status; the route is the path with its ids collapsed
  (`/wants/:id`); an incoming `traceparent` is continued. The request is
  also the ambient context of what it sets going: a run begun while serving
  it continues its trace. Health checks and static files are left out
  (`inbound.ignore` replaces that; `inbound: false` turns it off).
- **Vitals**, once per flush: event-loop delay (mean, p99, worst), memory,
  heap, GC count and time, CPU, open handles — `node.*`. Event-loop delay
  is the one to watch: everything in the process shares one thread.
- **The console**, when asked (`console: true`): every `console.*` line as
  a log record, a leading `[word]` as its source, the run's trace when it
  was written inside one. Off by default — a log line is free text, and
  the app knows what its own lines say.

## The browser

`glass.handleBrowser(request, response)` answers `/_glass/*` — glass.js,
and the beacons it posts — exactly as the gem's middleware does: the page
never talks to Glass, no key reaches it, and what it reports is validated
and stamped here (origin, a user agent reduced to browser · OS · device, a
visitor hash, the user the app identified). Mount it ahead of the app's own
routes and put `<script defer src="/_glass/glass.js">` in the page for
good: while the app's `browser` setting is off in Glass, or before `start`,
the script is empty and a beacon is dropped.

```ts
if (glass.handleBrowser(req, res)) return;        // ahead of the app's routes
glass.identify({ id: user.id, name: user.name }); // once the request knows who it is for
```

A page's event can join a trace: `glass.track("answer.painted", { run })`
in the page, and `traceFor: (props) => traceOfRun(props.run)` at `start`.
That is how the moment the first answer text was *painted* sits in the
trace of the run that produced it — the one thing the server cannot see.

`src/assets/glass.js` is a copy of `clients/browser/glass.js`; the suite
fails when it drifts (`rake browser:sync` in `clients/ruby` refreshes it).

## CPU profiles

V8's own sampling profiler, through the inspector the process already has —
no dependency, nothing native to build.

```ts
glass.start({ …, profiles: "continuous" }); // "on-demand" (default) | "continuous" | "off"
```

`on-demand` costs nothing until Glass's console asks this app for a profile
(`profile_now`); `continuous` samples in back-to-back minutes at the app's
`profile_hz` while its `profiling` setting is on, and that setting turns it
off again without a restart. Windows are folded before they are sent: a
function is its name, a path relative to `root` (default: the working
directory) or to its package, and whose code it is — `app`, `gem` (a
dependency), `node`, `native`. No absolute path is sent.

Idle samples are dropped and the collector's are marked `gc`. A sample
cannot be given to a run: runs interleave on one thread and a sample knows
the stack, not whose turn it was. The flamegraph answers "what is this
process's thread doing", which is the question when `node.eventloop.delay`
rises.

## What never leaves the process

A prompt, a completion, a tool's input or output. `attrs` are flattened,
bounded (64 keys, 1,000 characters) and stripped of anything that looks
like a credential — but the client cannot know what an app's own attributes
mean, so **an app that bridges its own spans sends an allowlist of
attribute keys, not the bag**.

## The discipline

The gem's, unchanged (protocol "Rules for an agent"): inert without
configuration; a push is an array append and never waits; overflow drops
and counts, and the next header says so; a failed send drops the batch and
is never retried; 429 pauses for `Retry-After`; 401 stops for good; 413
halves the next batch; the timer never keeps the process alive; nothing
throws into the app, and what fails inside is counted as
`glass.agent.errors`.

## Tests

```sh
node --test "clients/node/test/*.test.ts"
frontend/node_modules/.bin/tsc -p clients/node
```

`test/sketch.test.ts` runs the conformance kit's vectors;
`spec/services/ingest/node_client_spec.rb` feeds a batch built by this
client (`test/emit.ts`) to the real server.
