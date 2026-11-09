# Glass — house conventions

**Observability for the home fleet**: metrics, traces, profiles, logs and
visitor analytics for every app fog runs, in one console. The wire agents
speak is [`docs/ingest-protocol.md`](docs/ingest-protocol.md) and is frozen:
additive changes only, and every change lands in the server, the clients
and the doc in one commit. `spec/fixtures/ingest/` is the conformance kit every client
is tested against.

Rails 8.1 JSON API (`app/`) + React console (`frontend/`) + the agents
(`clients/ruby/`, `clients/node/`, `clients/go/`, `clients/browser/`).
Everything below is enforced by CI (`bin/ci`: rubocop incl.
`rubocop/glass_cops.rb`, `srb tc`, rspec, the gem's minitest suite, the Go
and Node clients' tests, frontend lint/build/test, `bin/design-guard`,
`bin/check-types`) or by review.

## Two databases, two lifecycles

`primary` is configuration: small, precious, backed up. `telemetry` is the
signals: large, append-only, disposable, **excluded from backups**. Models
in `app/models/telemetry/` inherit `TelemetryRecord`; nothing joins across
the two — a telemetry row names its app by `App#telemetry_id` (an integer),
and `Query::Context` is the only translation between slugs and ids, which
also makes it the access boundary.

Telemetry tables are `PARTITION BY RANGE (ts)`, one partition per UTC day.
`Telemetry::Partitions` creates days ahead; retention is dropping a day,
never a `DELETE`. Every table is registered in `Telemetry::Tables` (its
retention and its place in the shed order). The telemetry database has no
schema file (`schema_dump: false`): its migrations are raw SQL in
`db/telemetry_migrate/`, and `db:prepare` migrates it. Column names that
collide with Active Record (`hash`, `transaction`) are spelled around
(`digest`, `txn`).

## A unit of work is a spine with facets

A row of `transactions` is a request, a job, an agent's run — and whatever
comes next. `Telemetry::Work` declares each kind: the facets it carries
(groups of columns: `http`, `queue`, `rails`, `outbound`, `ai`,
`experience`), what its `name` means, and the phases that add up to its
duration. A new kind is an entry there, a builder under
`Ingest::Records::Txn` for any facet that is new, and its fields in
`Query::Sources` — not a new table and not a pile of unrelated columns. A
kind nobody declared is kept with its spine. What is one-to-many under a
unit of work is a table of its own that names the trace and span: `spans`,
`logs`, `model_calls` (one row per model call, never sampled, never any
prompt or completion).

## Ingest never depends on the worker

`POST /ingest/v1/batch` (`IngestController`, outside the bearer stack) is
synchronous: parse, insert, answer. It authenticates with an `IngestKey`
(write-only, one app), never a console credential. `Ingest::Batch` turns
records into rows through one builder per type
(`Ingest::Records::*`); a malformed record is counted and skipped, never a
reason to reject the batch. Dictionaries (`SeriesResolver`, `ProfileStore`)
are remembered per process. The reply carries the app's `directives`
(`App#directives`): that is the whole control channel to agents.

## One read path

Every chart, table and list in the console is a `Query::Request` posted to
`/api/v1/query`. The engine compiles it against `Query::Sources` — the only
place a column identifier enters SQL; everything a person typed is a bound
parameter (`Query::Statement`). New signals are a new `Source` entry, not a
new endpoint. A query that cannot be compiled raises `Query::Invalid` with
a sentence written for the person who typed it; `BaseController` renders it
as 422.

Metrics are the exception in shape, not in path: `Query::Metrics` reads the
series dictionary and stitches rollup tiers (`Telemetry::Rollup`) with raw
points. Percentiles come from merged DDSketches (`Telemetry::Sketch`) and
are never averaged; the gem's sketch uses the identical mapping and the two
are pinned together by spec.

Triage (`app/services/triage/`, `/api/v1/triage`, the `triage` MCP tool)
is the read path composed, not a second one: each detector in
`Triage::DETECTORS` asks through `Triage::Scan` → `Query::Runner`, compares
the range with the window before it, and answers findings whose id *is*
their subject — the detail is recomputed, never stored. Evidence is a
closed set of shapes the console draws without knowing the detector (a
chart is a `QuerySpec` the console asks itself), and `Triage::Brief` is the
same detail as Markdown for an agent. A person's answer to a finding is
the one thing kept: a `TriageDismissal` (primary) keyed by that id —
dismissed stays out of the list until it is worse than it was, ignored
stays out for good — and `Triage.report` applies it for the console and
the MCP tool alike. A new kind of problem is a detector and a
`Triage::Kind`, not a new endpoint.

## The Node client

`clients/node` is the same agent for a long-lived Node process, and the
pieces an agent harness needs: a run as an envelope that is sent when it
finishes (phases, spend, what the person saw), a model call as a record of
its own. TypeScript source with no runtime dependencies and erasable syntax
only, so Node runs it as it is; apps vendor it at `packages/glass` with
`bin/sync-client`. Same discipline as the gem. Its tests are `node --test`,
its types are checked by the console's compiler, and
`spec/services/ingest/node_client_spec.rb` feeds a batch it built to the
real server.

## The agent gem

`clients/ruby` is the canonical source; apps vendor it at
`vendor/gems/glass` with `bin/sync-client`. It follows Flare's discipline
(fog's clients/flare): inert without `GLASS_URL` + `GLASS_API_KEY`, one
background thread, bounded buffers, drop on overflow, never retry into a
dead server, honour 429, stop on 401, rescue everything. Its one runtime
dependency is `vernier` (the gemspec explains why a dependency-free
profiler cannot be right). It has its own minitest suite and is excluded
from the app's Sorbet run. Glass vendors it by path and observes itself.

## Agents read through MCP

`/mcp` (`McpController`, outside the bearer stack like `/ingest` and
`/fog`) is stateless Streamable HTTP, a
server per request, an `ApiToken` and never a session. Tools live in
`app/services/mcp/tools/`, one class each on `Mcp::Tools::Base`, and are
appended to `Mcp::Toolbox::ALL` — never inserted, the order is every
client's prompt-cache prefix. A tool is the read path with an agent's
manners, not a second read path: it asks through `Query::Context` and the
query engine, takes times through `Mcp::TimeRange`, answers through
`McpSerializer` (ISO times, rounded numbers, no blanks), and wraps its body
in `answer { }` so a `Query::Invalid` reaches the agent as the sentence
that says what to fix. Every tool only reads today; one that changes
something declares `read_only? = false` and the toolbox keeps it from
read-scoped tokens and guests. The tool names are generated into the
console (`MCP_TOOLS`), and Settings › API tokens must describe each.

## Sorbet, enums, controllers, serializers

Every file in `app/` is `# typed: strict`;
closed vocabularies are `T::Enum`s wired with `ApplicationRecord.attribute`
and `ApplicationEnum`; controllers are thin and use `BaseController`'s
`finds`, `paginate`, `render_errors`; the only error envelope is
`{ errors: [...] }`; every JSON shape lives in `app/serializers/`; the
console's closed vocabularies are generated into
`frontend/src/types/generated.ts` by `bin/rails glass:types`.

## Frontend

`frontend/CLAUDE.md` has the non-negotiables. The scope bar (app, time
range, live) is URL state every page obeys (`lib/scope.tsx`); charts are
`components/charts/*` on tokens from `src/index.css` (categorical series
slots are fixed and validated — an app keeps its slot); every number on
screen should lead to the rows behind it.

## Configuration belongs in the UI

Credentials (ntfy, fog) are entered in Settings, `encrypts`-ed, never
serialized back. Agent behaviour is set per app in Settings › Apps and
delivered as directives — never by env var in the reporting app. Env vars
are for what fog must inject to boot.

## Deployment

fog-managed git app (`glass.fog.yaml`; `fog.yaml` carries the
getting-started text). Migrations run in the release phase only; `/up` is
unauthenticated; small state in the managed `storage` volume; telemetry in
Postgres under the disk budget.

## Local development

```bash
docker compose up -d db          # Postgres on 5438
bin/setup --skip-server          # gems, frontend packages, db:prepare (both databases); --demo also runs glass:demo
bin/rails glass:demo             # a pretend fleet to look at (DAYS=7 by default)
bin/dev                          # API on 3004 + console on 5175 (proxies /api to 3004); Ctrl-C stops both
bin/ci                           # everything CI runs
```
