# glass

The Glass agent for Rails apps. One gem line, two environment variables,
and the app reports requests, SQL, views, cache, jobs, outbound HTTP,
runtime vitals, logs and continuous profiles to Glass over
`glass-ingest/1` (`docs/ingest-protocol.md`) — and offers a StatsD-shaped
API for metrics of its own. One runtime dependency, `vernier`, for the
profiler; everything else is stdlib.

## How apps get it

Vendored, not fetched — Docker builds need zero credentials and zero
network:

```ruby
# Gemfile
gem "glass", path: "vendor/gems/glass"
```

List it **after** `gem "rails"`: the railtie only loads if Rails is already
defined when glass is required. With the order reversed, glass repairs
itself on the first `Glass.configure` after Rails has loaded — but the Rack
middleware can only be added while the stack is open, so request
transactions then cover the controller action only. Get the order right.

Copies are synced from the canonical source in the glass repo
(`clients/ruby`). Edit there, sync, commit in each app.

## Configuration

```
GLASS_URL=http://glass            # where to report
GLASS_API_KEY=glass_ing_…         # minted in Glass › Settings › Apps
```

Without **both**, the gem is inert: every public method is a cheap no-op,
no thread starts, nothing is subscribed. Development, test and apps run
outside fog are unaffected.

Everything else has a default and can be set in an initializer:

```ruby
Glass.configure do |c|
  c.ignore_paths = ["/up", "/ingest"]   # prefix match; no transaction, no metrics, no logs
  c.vpn_ranges   = ["10.8.0.0/24"]      # on top of 100.64.0.0/10 (Tailscale)
  c.propagate_to = ["example.net"]     # traceparent to these too, beyond private/VPN addresses, bare names, .lan/.local/.internal
  c.user         = -> { Current.user&.id }     # identity source
  c.user_name    = -> { Current.user&.name }   # for the `named` identity mode
  c.record_paths = false                # route templates only, never a concrete path
  c.process_kind = "worker"             # or GLASS_PROCESS; detected otherwise
  c.enabled[:profiling] = false         # per-feature kill switches, see below
end
```

`process_kind` is `worker` under `bin/jobs`, Solid Queue's forked
processes, Sidekiq, or a rake task named like jobs; `web` otherwise.
`release` is `GIT_SHA`, then `GIT_REV`, then the `REVISION` file.

Runtime settings come from Glass, in every ingest reply: `trace_sample_rate`,
`profiling`, `profile_hz`, `log_level`, `identity` (`anonymous`,
`pseudonymous`, `named`), `browser`, and one-shot `profile_now` requests.
Change them in the console and every process picks them up on its next
flush. A local `c.enabled[:feature] = false` wins over any directive;
features are `requests`, `jobs`, `sql`, `views`, `cache`, `http`, `errors`,
`runtime`, `profiling`, `logs`, `events`.

## What is instrumented

| Signal | Hook | Produces |
|---|---|---|
| Requests | Rack middleware at the top of the stack + `process_action` | one `txn` per request: name, route, status, breakdown, origin, user; `rails.request.count/duration/errors` |
| SQL | `sql.active_record` | `sql` spans with the statement normalized (literals → `?`), `db_ms`/`db_n`, N+1 flag at 5 repeats of one shape; cached queries count as cache hits |
| Views | `render_*.action_view` | `view` spans, `view_ms` (top-level renders only) |
| Cache | `cache_read(_multi)` | `cache_hit`/`cache_miss` |
| Jobs | `perform.active_job`, `enqueue(_at).active_job` | one `txn` per perform with queue, attempt and queue latency; `enqueue` spans; the job carries the enqueuing trace (`glass_traceparent` in the job data) so web → worker is one trace; `rails.job.*` |
| Outbound HTTP | `Net::HTTP#request` | `http` spans, `ext_ms`/`ext_n`; `traceparent` injected only for private addresses and bare hostnames (fog siblings), never the public internet |
| Errors | `Rails.error.subscribe` | `rails.errors` by class and `handled`; an unhandled error marks its transaction; `glass_trace_id` in the error context links Flare events back |
| Logs | a sink on the broadcast logger + `Rails.event` | `log` records at or above the `log_level` directive, ANSI stripped, 8,000 chars, with the current trace and span |
| Runtime | every 10 s from the agent thread | GC, heap, RSS, threads, YJIT; Puma backlog/running/capacity/busy; Active Record pools; Solid Queue ready/scheduled/failed and oldest-ready age by queue (every 30 s, one query) |
| Profiles | Vernier, 60 s windows at `profile_hz` | stack samples folded per (stack, transaction, state), attributed by thread and transaction interval; `gc` from Vernier's GC markers |

| Browser | `glass.js` + the `/_glass/*` relay | `page` records: pageviews (incl. SPA navigations), autocaptured clicks and submits, web vitals, JS errors, `glass.track` events, with `visitor`, `user`, `origin` and `ua` stamped by the agent |

Requests that never reach a controller are named `(static)` or `(404)`.
Inbound `traceparent` continues the caller's trace; `X-Glass-Visit` becomes
`visit`; the client address becomes `origin` (`lan`, `vpn`, `tunnel`,
`public`) and is then forgotten.

Tail sampling: the transaction row is always sent; its spans go too when
the request errored, ran slower than the endpoint's running p95 (after 20
observations), is the first of its name this boot, or wins the
`trace_sample_rate` draw. RED metrics are computed from every transaction
before that decision, so they are exact.

The current transaction lives in fiber-local storage
(`Thread.current[:glass_txn]`), the same scope Rails uses for a request;
work handed to other threads (`load_async`, a thread pool) is not part of
it.

## Browser analytics

With the `browser` directive on (Glass › app settings) and
`c.enabled[:browser]` not false, the middleware injects
`<script defer src="/_glass/glass.js"></script>` into complete `text/html`
responses (status 200, not chunked), serves the script (ETag, a day of
cache, gzip) and accepts its beacons at `POST /_glass/b`. Nothing under
`/_glass/` reaches the app or becomes a transaction or a log line.

`glass.js` (canonical source `clients/browser/glass.js`, ≤ 4 KB gzipped,
no dependencies, never throws into the page) keeps a visit id per tab in
`sessionStorage` (renewed after 30 minutes idle), records pageviews with a
route template (`/wants/:id`), clicks and submits by accessible name and a
short stable selector — never input values, never query strings — web
vitals once per pageview, errors (10 per visit), and adds `X-Glass-Visit`
to same-origin `fetch`/XHR calls only. Configure it through the tag's data
attributes (`data-endpoint`, `data-autocapture="off"`, `data-vitals="off"`,
`data-flush="5000"`); the app can call `glass.track(name, props)`,
`glass.flush()` and read `glass.visit`.

The relay accepts only same-origin beacons (≤ 64 KB, ≤ 100 events), gives a
visit no request has vouched for a quota of 50 events, validates every
event against the protocol, scrubs `props` like attrs, and stamps what only
the server knows: `origin` from the client address, `ua` (browser, OS,
device class — never the user agent string), `visitor` (the keyed user hash
once a request carrying the visit's header resolved a user, else a
daily-rotating hash of address + user agent) and `user`. Client addresses
are classified and forgotten.

The gem ships a copy of the script at `lib/glass/assets/glass.js`; `rake`
fails when it drifts from the canonical source (`rake browser:sync`
refreshes it) and runs the script's node tests when node is installed.

## Public API

```ruby
Glass.increment("wants.created", tags: { kind: "book" })   # counter (also .decrement)
Glass.gauge("indexers.healthy", 7)
Glass.histogram("nzb.size_bytes", bytes, unit: "bytes")    # distribution (DDSketch)
Glass.timing("import.verify", ms)                          # distribution in ms
Glass.time("import.verify") { verify! }                    # times the block + a span in the current trace
Glass.set("readers.active", user.id)                       # unique count per window
Glass.event("Library reconciled", tags: { library: "x" })  # a marker on every chart
Glass.tag(want_id: want.id)                                # attributes on the current transaction
Glass.span("reconcile", resource: "bookorbit") { … }       # a custom span
Glass.model_call(provider: "ollama", model: "qwen3:8b", duration_ms: 950, …)  # one call to a model (below)
Glass.trace_id            # the current trace id, or nil
Glass.traceparent         # W3C header for hand-rolled propagation
Glass.current_transaction
```

### Model calls

```ruby
Glass.model_call(
  provider: "anthropic-api", model: "claude-sonnet-4-6", duration_ms: 4180.0,
  started_at: started,                       # Time or epoch seconds; now minus the duration when omitted
  purpose: "turn", agent: "owner-chat", session: "ses_81c4",
  input_tokens: 1840, cache_read_tokens: 21_400, output_tokens: 512,
  cost_usd: 0.0193, cost_source: "estimated", ttft_ms: 612.0,
  stop: "tool_use", tools: 1, tools_valid: 1
)
```

One call to a model, sent as the protocol's `llm` record
(`docs/ingest-protocol.md`) — every call, never sampled — plus the `ai.*`
metrics the Node client leaves behind (`ai.calls`, `ai.cost` in usd except
for a `shadow` price, `ai.tokens` by kind, `ai.duration`, `ai.ttft`).
`provider`, `model` and `duration_ms` are required; the rest are optional:
`served`, `tier`, `purpose` (`turn`), `origin` (`production`), `agent`,
`session`, `round`, `input_tokens` (uncached), `cache_read_tokens`,
`cache_write_tokens`, `output_tokens`, `reasoning_tokens`, `estimated`,
`cost_usd`, `cost_source` (`reported`, `estimated`, `shadow`, `free`),
`ttft_ms`, `first_text_ms`, `itl_p95_ms`, `queue_ms`, `load_ms`,
`prompt_ms`, `decode_ms`, `concurrent`, `stream`, `stop`, `status`
(`ok`), `error` (the class: `timeout`, `rate_limit`, …), `retry_of`,
`fallback_from`, `route`, `tools`, `tools_valid`, `trace`, `span` and
`attrs`. Inside a transaction the call joins its trace unless `trace:` says
otherwise. There is no field for a prompt or a completion, and a keyword
the gem does not know is ignored rather than raised.

Metrics aggregate in-process per (name, sorted tags) over 10-second
windows and flush as one record per series; tags are strings, at most 20
per series, and a user id does not belong in one (put it on the
transaction with `Glass.tag`). Distinct series are capped at 5,000 per
window.

## The safety contract

- One background thread, bounded buffers, non-blocking push: overflow
  drops and counts, and the counts ride in the next batch header so a low
  number says why.
- A failed send drops the batch — never a retry into a dead server. `429`
  pauses for `Retry-After` (1–300 s), dropping meanwhile. `413` halves the
  next batch. `401` stops for good (until restart) and switches the
  instrumentation off.
- Timeouts 3 s open / 5 s read; a 2 s flush at exit.
- Fork-safe: Puma workers and Solid Queue processes are detected by pid
  and start clean; the profiler never runs across a fork.
- Every subscriber body and public entry point rescues `StandardError`,
  counts it (`glass.agent.errors`, tagged by where) and carries on.
  Nothing on a request path blocks on Glass or raises into the app.
- A transaction stops recording children past 500 spans and says so
  (`spans_dropped`).
- Scrubbing: SQL leaves the process normalized, never with values; attrs
  and event payloads go through the app's `filter_parameters` plus a
  built-in key scrub (password, token, secret, cookie, session, …); bind
  values, params, headers and cookies are never sent. Ignored paths
  produce no logs either, so Glass's own ingest never feeds on itself.
- Profiling costs about 2% on a CPU-bound workload at 100 Hz
  (`bench/overhead.rb`); if Vernier cannot load, the agent runs without
  profiles.

## Tests

```
cd clients/ruby && BUNDLE_GEMFILE=../../Gemfile bundle exec rake
```

No network: a fake sender captures the bodies that would go on the wire.
`node --test clients/browser/test` exercises `glass.js` against a
hand-rolled window (no jsdom).
