# `glass-ingest/1` — the wire between an agent and Glass

*Frozen for v1; additive changes only. The server is
`app/services/ingest/`; the clients are `clients/ruby` and `clients/node`.
All of them are tested against the conformance kit in
`spec/fixtures/ingest/` — whole batches, what the server makes of each, and
the sketch vectors.*

An agent is anything that reports: the `glass` gem inside a Rails process,
the Node client inside an agent harness, `glass-agent` bridging StatsD, fogd
under `fog-telemetry/1`. They all speak this.

## Request

```
POST {GLASS_URL}/ingest/v1/batch
Authorization: Bearer {GLASS_API_KEY}        # glass_ing_…
Content-Type: application/x-ndjson
Content-Encoding: gzip                       # optional, expected
User-Agent: glass-ruby/0.1.0
```

The body is newline-delimited JSON: **one header line, then one record per
line.** At most 4 MiB on the wire, 32 MiB inflated, 20,000 records.

An ingest key identifies exactly one app. Nothing in the body names the app;
it cannot be spoofed.

### Header (line 1)

```json
{"v":1,
 "process":{"kind":"web","host":"3f9a1c2d","pid":41,"release":"3df7786",
            "started_at":1790000000.0,
            "runtime":{"ruby":"3.4.2","rails":"8.1.3","client":"glass-ruby","agent":"0.1.0","server":"puma"}},
 "sent_at":1790000123.456,
 "dropped":{"txn":0,"span":0,"metric":0,"log":12,"profile":0,"page":0,"llm":0}}
```

- `process.runtime` — whatever versions describe the process: `ruby` and
  `rails`, or `node`, or `go`. `client` is the agent library that sent the
  batch (`glass-ruby`, `glass-node`, `glass-go`) and `agent` is that
  library's bare version (`0.1.0`).
- `process.kind` — `web`, `worker`, or any short label. With `host` and
  `pid` it identifies the reporting process; every batch is its heartbeat.
- `process.release` — the deployed revision (git SHA). Stamped on every
  record the batch carries.
- `dropped` — cumulative counts, since process start, of records the agent
  shed (queue overflow, a `429` pause, a failed send). Glass shows them so a
  number that is low because the agent was shedding says so.

### Records

Every record has `t` (type) and `ts` (start time, Unix seconds, fractional).
Durations are **milliseconds**. Unknown types and unknown fields are skipped,
never rejected. Absent optional fields are absent, not `null`.

Ids: `trace` is 32 lowercase hex characters (128 bits); `span` and `parent`
are 16 (64 bits) — the W3C Trace Context sizes, so `traceparent` propagates
unchanged.

#### `txn` — one unit of work (the wide event)

A request, a job, an agent's run. Every `txn` has the same **spine**; what
else it carries depends on its `kind`, in groups called **facets**
(`Telemetry::Work`). Facets compose: a run waits in a queue like a job and
makes outbound calls like a request.

```json
{"t":"txn","ts":1790000120.101,"kind":"request","name":"Api::V1::WantsController#index",
 "trace":"4bf92f3577b34da6a3ce929d0e0e4736","span":"00f067aa0ba902b7","dur":48.2,
 "status":"ok","method":"GET","route":"/api/v1/wants","path":"/api/v1/wants","http":200,"format":"json",
 "db_ms":12.4,"db_n":5,"view_ms":3.1,"ext_ms":0,"ext_n":0,"cache_hit":2,"cache_miss":0,
 "gc_ms":0.4,"alloc":18234,"n1":false,
 "user":"u_9c1f…","visit":"v_51aa…","origin":"lan","kept":true,
 "attrs":{"want_id":"…"}}
```

**The spine** — every kind:

| Field | | |
|---|---|---|
| `kind` | required | `request`, `job`, `run`, or any short lowercase label (`[a-z][a-z0-9_.-]*`, at most 40 characters) |
| `name` | required | what aggregates group by: the endpoint, the job class, the agent |
| `trace`, `span` | required | |
| `parent` | | the span this continues: another app's (a remote parent), or the unit of work that set this one going |
| `dur` | required | milliseconds |
| `status` | | `ok` (default) or `error` |
| `error` | | exception class when `status` is `error` |
| `user` | | per the app's identity mode; opaque to Glass |
| `kept` | | the agent also sent this trace's spans |
| `weight` | | how many transactions this row stands for (default 1) |
| `attrs` | | string → scalar; at most 64 keys |

**The facets**, and which kinds carry them:

| Facet | Fields | Kinds |
|---|---|---|
| `http` | `method`, `route`, `path`, `http`, `format`, `visit`, `origin` — `route` is the template (`/wants/:id`), `path` the concrete path without query string, omitted by an agent told not to send it; `visit` is the browser visit (`X-Glass-Visit`); `origin` is `lan`, `vpn`, `tunnel` or `public` | request |
| `queue` | `queue`, `queue_ms`, `attempt` | job, run |
| `rails` | `db_ms`, `db_n`, `view_ms`, `cache_hit`, `cache_miss`, `gc_ms`, `alloc`, `n1` — the breakdown, summed in the agent over the whole transaction; `n1`: a repeated-query pattern was seen | request, job |
| `outbound` | `ext_ms`, `ext_n` | request, job, run |
| `ai` | `agent`, `session`, `trigger`, `channel`, `stop`, `model`, `rounds`, `calls`, `tools_n`, `tool_err`, `tok_in`, `tok_out`, `tok_cache_read`, `tok_cache_write`, `cost` | run |
| `experience` | `prep_ms`, `model_ms`, `tool_ms`, `wait_ms`, `deliver_ms`, `lag_ms`, `ttft_ms`, `stall_ms` | run |

A field of a facet the kind does not carry is dropped: a run has no HTTP
status. **A kind the server has no declaration for is kept, not skipped** —
with its spine, its `attrs`, and any facet field it sends. An agent can
report a new kind of work before the server knows what is particular to it.

A kind's **phases** are the fields that add up to its `dur`; what is left is
its unattributed time. For a request or a job they are `db_ms`, `view_ms`
and `ext_ms`. For a run they are `queue_ms`, `prep_ms`, `model_ms`,
`tool_ms`, `wait_ms` and `deliver_ms`, so each must be exclusive of the
others — time waiting on an approval inside a tool call is `wait_ms`, not
`tool_ms`.

`queue_ms` means "waited its turn". For a job that is enqueue → perform,
*before* `ts`. For a run it is the wait for the conversation to be free,
*inside* `dur`: a run's `ts` is when the harness took the message.

##### `kind: "run"` — one thing asked of an agent harness

```json
{"t":"txn","ts":1790000120.0,"kind":"run","name":"owner-chat",
 "trace":"7d3c0e1a9b8f4c62a1e5d4c3b2a19087","span":"1111111111111111","dur":41250.0,"status":"ok",
 "agent":"owner-chat","session":"ses_81c4","trigger":"message","channel":"telegram","stop":"ok",
 "model":"claude-sonnet-4-6","rounds":2,"calls":3,"tools_n":1,"tool_err":0,
 "tok_in":3680,"tok_out":1024,"tok_cache_read":42800,"tok_cache_write":0,"cost":0.0412,
 "queue_ms":820.0,"prep_ms":310.0,"model_ms":9150.0,"tool_ms":5400.0,"wait_ms":24800.0,"deliver_ms":410.0,
 "lag_ms":1200.0,"ttft_ms":40840.0,"stall_ms":24800.0,"kept":true,"attrs":{"run":"run_01j9"}}
```

The transaction is the whole interaction: from the harness taking the
message to the reply being handed to the channel. `name` is the agent for a
turn and the purpose for background work (`compaction`, `reflection`); work
a run leaves behind, and tasks it spawns, are `run` transactions of the same
trace with `parent` set.

| Field | |
|---|---|
| `agent`, `session` | who ran, and the conversation it ran in |
| `trigger` | why it ran: `message`, `cron`, `task`, `console`, … |
| `channel` | where the person is: `telegram`, `console`, `voice`, … |
| `stop` | why it ended: `ok`, `rounds`, `tokens`, `usd-day`, `no-answer`, `cancelled`, `killed`, `error` |
| `model` | the model that gave the answer |
| `rounds`, `calls` | model rounds in the turn; model calls in all (retries and helpers included) |
| `tools_n`, `tool_err` | tool calls, and how many failed |
| `tok_in`, `tok_out`, `tok_cache_read`, `tok_cache_write` | tokens over every call; `tok_in` is uncached input |
| `cost` | US dollars |
| `prep_ms` | memory and context assembly |
| `model_ms`, `tool_ms` | in model calls; in tools, less any wait on a person |
| `wait_ms` | waiting on a person — an approval, a question |
| `deliver_ms` | handing the reply to the channel |
| `lag_ms` | wanted → begun, *before* `ts`: a message in transit, a task waiting to be claimed |
| `ttft_ms` | `ts` → the first answer text the person could see |
| `stall_ms` | the longest stretch in which the person saw nothing happen, with time spent waiting on the person taken out |

**No content, ever**: not the message, not the reply, not a tool's input
or output. Names, counts, sizes, durations, statuses and ids.

#### `span` — a child span of a kept trace

```json
{"t":"span","ts":1790000120.110,"trace":"4bf9…4736","span":"a1b2c3d4e5f60718","parent":"00f067aa0ba902b7",
 "kind":"sql","name":"Want Load","res":"SELECT \"wants\".* FROM \"wants\" WHERE \"wants\".\"household_id\" = ? LIMIT ?",
 "dur":1.9,"status":"ok","attrs":{"cached":false}}
```

`kind` is `sql`, `view`, `cache`, `http`, `enqueue` or `custom`; and, for the
steps of a run, `model` (a model call), `tool`, `wait` (on a person),
`queue`, `memory`, `context`, `sandbox` or `channel`. Anything else is stored
as `custom`. `res` is the normalized resource — a SQL statement with literals
replaced, a template path, an outbound `METHOD host/path`, the model a
`model` span called. **Bind values never appear**, and neither do a tool's
arguments.

#### `llm` — one call to a model

```json
{"t":"llm","ts":1790000121.2,"trace":"7d3c0e1a9b8f4c62a1e5d4c3b2a19087","span":"2222222222222204",
 "provider":"anthropic-api","model":"claude-sonnet-4-6","served":"claude-sonnet-4-6","tier":"frontier",
 "purpose":"turn","origin":"production","agent":"owner-chat","session":"ses_81c4","round":0,
 "dur":4180.0,"ttft":612.0,"first_text":1900.0,"itl_p95":41.0,
 "queue_ms":0,"load_ms":0,"prompt_ms":220.0,"decode_ms":3300.0,"concurrent":1,"stream":true,
 "in":1840,"cache_read":21400,"cache_write":0,"out":512,"reasoning":96,"estimated":false,
 "cost":0.0193,"cost_src":"estimated",
 "stop":"tool_use","status":"ok","route":"agent:owner-chat","tools":1,"tools_valid":1,
 "attrs":{"model_version":"mv_3a"}}
```

One per call — a retry and a helper call are calls. **Every one is kept**;
there is no sampling, because spend is only exact if nothing is left out.
An agent that learns something about a call after it ends (how many of its
tool calls parsed) holds the record until it knows, rather than sending
twice.

| Field | | |
|---|---|---|
| `provider`, `model` | required | what was asked for |
| `dur` | required | milliseconds |
| `trace`, `span` | | the `model` span this call was, when it was made inside a trace |
| `served` | | the model that answered, when the provider says |
| `tier` | | the app's own class of model (`local`, `frontier`) |
| `purpose` | | why the call was made: `turn` (default), `reviewer`, `title`, `compaction`, `judge`, … |
| `origin` | | `production` (default), `internal` or `eval` |
| `agent`, `session`, `round` | | |
| `in`, `cache_read`, `cache_write`, `out`, `reasoning` | | tokens; `in` is uncached input |
| `estimated` | | the provider gave no usage; the counts are from text length |
| `cost`, `cost_src` | | US dollars; `reported`, `estimated`, `shadow` (a subscription call priced as if metered) or `free` |
| `ttft`, `first_text`, `itl_p95` | | ms to the first chunk, to the first visible text, and the inter-token p95 |
| `queue_ms`, `load_ms`, `prompt_ms`, `decode_ms` | | the model server's own account of its time, when it gives one |
| `concurrent` | | calls already in flight on the same backend when this one began |
| `stream` | | the answer was streamed |
| `stop` | | `end_turn`, `tool_use`, `max_tokens`, … |
| `status`, `error` | | `ok` (default) or `error`; `error` holds the class — `timeout`, `rate_limit`, `overloaded`, `context_exceeded`, … |
| `retry_of` | | the span of the call this one retries |
| `fallback_from` | | the provider that failed before this one was tried |
| `route` | | why this model was chosen |
| `tools`, `tools_valid` | | tool calls the model asked for, and how many parsed against their schema |
| `attrs` | | string → scalar; at most 64 keys |

No prompt, no completion, no system prompt.

#### `metric` — one series, one flush window

```json
{"t":"metric","ts":1790000120,"name":"rails.request.duration","kind":"dist","unit":"ms",
 "tags":{"controller":"wants","action":"index"},
 "n":14,"sum":612.0,"min":9.1,"max":148.0,"last":31.0,"sk":[112,3,131,6,160,4,252,1]}
```

Agents aggregate in-process and send one record per `(name, tags)` per
window (10 s). `ts` is the window's start.

| `kind` | meaning of the summary |
|---|---|
| `counter` | `sum` is the increment over the window; `n` the number of calls |
| `gauge` | `last` is the value; `min`/`max`/`sum`/`n` summarize the samples taken |
| `dist` | a distribution: the summary plus `sk` |
| `set` | `n` is the number of distinct members seen in the window |

`sk` is a DDSketch as a flat array of alternating *bucket index, count*,
ascending by index. The mapping is fixed: `index = ceil(ln(v) / ln(1.02))`
for `v > 1e-9`; a bucket stands for `2·1.02^i / 2.02`. Values at or below
`1e-9` have no bucket and are `n − Σcounts`. Sketches merge by adding counts,
which is why percentiles stay correct across series and rollups.

At most 20 tags per series. Past 2,000 series for one metric name in one
app, new tag sets are folded into a single series tagged
`glass_overflow:true`.

#### `marker` — something that happened

```json
{"t":"marker","ts":1790000100.0,"kind":"event","title":"Library reconciled","attrs":{"library":"bookorbit"}}
```

`kind` is `event` (default), `deploy`, `restart` or `annotation`.

#### `log` — one log line or structured event

```json
{"t":"log","ts":1790000120.150,"lvl":"warn","msg":"Indexer answered 429","src":"rails",
 "trace":"4bf9…4736","span":"00f067aa0ba902b7","attrs":{"indexer":"nzbgeek"}}
```

`lvl` is `debug`, `info`, `warn`, `error` or `fatal`. `src` says where it
came from: `rails` (the logger), `event` (`Rails.event`), or a name the app
chose. `trace` and `span` are present when the line was written inside a
transaction — that is what lets a trace show its own logs. `msg` is at most
8,000 characters; ANSI colour codes are stripped by the agent.

#### `profile` — one profiling window of one process

```json
{"t":"profile","ts":1790000100.0,"dur":60.0,"hz":100,"mode":"wall",
 "funcs":[["Api::V1::WantsController#index","app/controllers/api/v1/wants_controller.rb",12,"app"],
          ["ActiveRecord::Relation#load","activerecord/lib/active_record/relation.rb",0,"gem"],
          ["Array#each","<internal:array>",0,"ruby"]],
 "stacks":[[0,1,2],[0,2]],
 "samples":[[0,"Api::V1::WantsController#index","running",41],
            [1,"Api::V1::WantsController#index","stalled",3],
            [1,null,"running",7]]}
```

A window is folded in the agent: a minute of a busy process is a few hundred
distinct stacks, not six thousand samples.

- `funcs` — the functions this record mentions, each `[name, file, first
  line, category]`. `file` is relative to the app root for app code and to
  the gem root (prefixed with the gem's name) for gems; never an absolute
  path. `category` is `app`, `gem` (a dependency, whatever the language
  calls one — for Node, the package name and the path inside it), `ruby` or
  `node` (the runtime's own core and stdlib) or `native`. An unknown
  category is stored as `app`.
- `stacks` — each an array of indexes into `funcs`, **root first**.
- `samples` — each `[stack index, transaction name or null, state, weight]`.
  `state` is `running`, `stalled` (runnable, waiting for the GVL), `idle`
  (blocked — I/O, sleep, a lock) or `gc`. `weight` is the number of samples
  folded into the row. A sample is attributed to the transaction whose
  interval on that thread contained it; samples taken on a thread that was
  idle *outside* any transaction are not sent — an empty thread pool waiting
  for work is not a finding.

A runtime where many units of work interleave on one thread (Node) cannot
say whose turn a sample was: its samples carry `null` for the transaction,
its states are `running` and `gc`, and its flamegraph is the process's, not
an endpoint's.

Indexes are local to the record. The server re-keys functions and stacks by
content, so the same stack from two processes or two windows is one row.

#### `page` — one thing a visitor did

Browser events never reach Glass directly: `glass.js` posts them to
`/_glass/b` on the app's own origin, and the app's agent relays them as
`page` records — stamping what only the server knows.

```json
{"t":"page","ts":1790000120.5,"kind":"pageview","visit":"v_3f9a1c2d8b7e","visitor":"a_5c1d…",
 "user":"u_9c1f…","path":"/wants/8c1f2a","route":"/wants/:id","title":"Hook · Wants","ref":"https://portal.example.net/today",
 "ua":{"browser":"Safari","os":"iOS","device":"phone","screen":"390x844"},"lang":"en-US","origin":"lan",
 "name":null,"props":{},"el":null,"vitals":null}
```

| Field | | |
|---|---|---|
| `kind` | required | `pageview`, `click`, `submit`, `vital`, `custom` or `error` |
| `visit` | required | the visit (browser session) id `glass.js` keeps in `sessionStorage`; the same value the browser sends as `X-Glass-Visit` on its API calls, which is how a request joins its visit |
| `visitor` | | who, across visits: the agent's daily-rotating hash of client address + user agent + app (`anonymous`), or the same keyed hash as `user` when the app has identified the visit (`pseudonymous`/`named`). Set by the agent, never by the browser |
| `user` | | as on a `txn`: the agent stamps it once a request carrying this visit's `X-Glass-Visit` has been served with a signed-in user; the browser never knows it |
| `path`, `route` | | the concrete path and its template (`/wants/:id` — ids, uuids and hex collapsed by `glass.js`); `path` is omitted by an agent told not to send it |
| `title`, `ref` | | document title; referrer of the *visit's first* pageview only (a same-origin referrer is dropped) |
| `ua` | | `browser`, `os`, `device` (`phone`, `tablet`, `desktop`), `screen` (`WxH`) — parsed by the agent from the user agent; the user agent string itself is not sent |
| `lang` | | `navigator.language` |
| `origin` | | as on a `txn`, from the beacon's client address, which is then forgotten |
| `name` | interactions, custom | for `click`/`submit`: the element's accessible name (`Add want`); for `custom`: what the app called `glass.track` with; for `error`: the error class or message head |
| `el` | interactions | `{"tag":"button","role":"button","sel":"form > button.primary","href":"/wants"}` — a stable descriptor, never input values |
| `vitals` | `vital` | `{"lcp":1840,"inp":120,"cls":0.02,"ttfb":95,"fcp":610}` in ms (CLS unitless); sent once per pageview when the page is hidden, with whatever was measured |
| `props` | `custom` | string → scalar, at most 32 keys, values at most 200 characters |
| `trace` | | the trace an event belongs to, when the page knows: what a person *saw* of a run — the first answer text painted — sits in the trace of the run that produced it |

The agent accepts a beacon only from its own origin, caps its size, and
drops beacons for visits it has never seen a request for after a quota, so
a browser cannot flood an app's telemetry.

## Response

| Status | Meaning | Agent behaviour |
|---|---|---|
| `202` | accepted | apply `directives` |
| `400` | unreadable body or header | drop the batch |
| `401` | unknown or revoked key | stop sending until restart |
| `413` | too large | drop the batch, halve the next one |
| `429` | over the rate limit; `Retry-After: <seconds>` | pause that long, dropping |
| `5xx` / network error | | drop the batch; never retry into a dead server |

```json
{"accepted":118,"skipped":2,
 "directives":{"trace_sample_rate":0.1,"profiling":true,"profile_hz":100,"log_level":"info","browser":true,
               "identity":"pseudonymous","profile_now":null}}
```

`skipped` counts records that were malformed or of an unknown type — the
rest of the batch is still accepted. `directives` are the app's agent
settings as they stand in Glass's console; an agent applies them on receipt.
That is the whole control channel: no second connection, no polling.

| Directive | | |
|---|---|---|
| `trace_sample_rate` | 0..1 | the share of ordinary traces whose spans are kept (errors, slow outliers and first-sight endpoints always are) |
| `profiling` | bool | profile at all |
| `profile_hz` | 10..1000 | sampling rate |
| `log_level` | `debug`…`error`, `off` | the least severe level shipped |
| `browser` | bool | inject `glass.js` into HTML responses |
| `identity` | `anonymous`, `pseudonymous`, `named` | what `user` on a transaction holds: nothing; `u_` + a keyed hash of the app's user id; or a display name |
| `profile_now` | `null` or `{"id":"…","seconds":30,"hz":1000}` | a one-shot request. An agent that has not already run this `id` profiles for that long at that rate and sends the window with `"request":"<id>"` on the profile record |

An agent must ignore directives it does not know.

## Rules for an agent

1. **Never block the host.** One background thread, one bounded queue,
   non-blocking push; overflow drops and counts.
2. **Never retry into a dead server.** A failed send drops the batch.
3. **Honour `429`.**
4. **Stop on `401`.**
5. **Be inert without configuration.** No `GLASS_URL` or no `GLASS_API_KEY`
   means do nothing at all.
6. **Count what you shed**, and say so in the next header.
7. **Scrub before sending.** Normalize SQL; filter params through the app's
   own rules; never send bind values, cookies or authorization headers —
   nor a prompt, a completion, or what a tool was given or gave back.
8. **Send `traceparent` only to hosts that are ours.** An outbound request
   carries the W3C `traceparent` header, so a sibling app continues the
   trace, when its host is:
   - an address (bracketed or not) the origin rule does not call public —
     loopback, RFC 1918, link-local, a ULA, `100.64.0.0/10`, or a VPN
     range the app configured; or
   - not an address, and bare (no dot: a container network's names, such
     as `glass` or `hook`); or
   - not an address, and equal to or ending in `.` plus one of the
     internal suffixes `lan`, `local`, `internal`, or a suffix the app
     configured — compared without case.

   Anything else — a public address, a dotted public name — is never sent
   one: it would hand trace ids to a third party for no benefit. The
   `propagate` cases in `spec/fixtures/ingest/origin.json` hold every
   client to this rule.
