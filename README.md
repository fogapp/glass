# Glass

**Observability for a self-hosted fleet.** Metrics, request traces, logs,
continuous profiles and visitor analytics for every app you run, in one
console, behind one query bar.

Glass is made for [Fog](https://github.com/fogapp/fog), a home server that
runs a household's apps. It runs as a Fog app beside the apps it watches,
and an app starts reporting to it with two environment variables.

## What it does

- **Requests and jobs.** Every request and background job is recorded as a
  single row with its route, status, timings, database and cache time, and
  queue wait. Sampled traces keep their spans and logs for a waterfall
  view.
- **Metrics.** Runtime vitals (memory, GC, event-loop delay) and your
  own counters, gauges and timers. Percentiles come from merged DDSketches,
  so they are never averages of averages.
- **Continuous profiles.** The agents sample the process all the time.
  Flamegraphs can be filtered to one endpoint or job and compared between
  two time ranges.
- **Logs.** Structured logs, tied to the request or job that wrote them.
- **Visitor analytics.** A small browser script that the agent serves from
  the app's own origin records pageviews, clicks, errors and Core Web
  Vitals. There's nothing to add to the frontend and no third-party domain.
- **Agent harnesses.** Runs of an AI agent, each with its phases, model
  calls, token spend and what the person saw. Prompts and completions are
  never recorded.
- **Triage.** A ranked list of what changed for the worse: regressions,
  new errors, N+1 queries, stuck jobs, queue waits, slow web vitals. Each
  finding links to the evidence.
- **Explore, dashboards and monitors.** One query language for every
  signal. Pin a query to a dashboard, or put a condition on it to open
  incidents and send notifications through [ntfy](https://ntfy.sh).
- **MCP server.** Coding agents can ask Glass questions like "why was this
  endpoint slow at 3 am?" through `/mcp`, with a read-only API token.

## What is here

| Part | Where |
|---|---|
| The server: ingest, storage, query engine, API, MCP | `app/` (Rails 8.1, Sorbet) |
| The console | `frontend/` (React 19, Vite, Tailwind v4, uPlot) |
| The agent for Rails apps | [`clients/ruby/`](clients/ruby/README.md) |
| The agent for Node processes and agent harnesses | [`clients/node/`](clients/node/README.md) |
| The agent for Go programs | [`clients/go/`](clients/go/README.md) |
| The browser script the agents serve | `clients/browser/` |
| The wire protocol the agents speak | [`docs/ingest-protocol.md`](docs/ingest-protocol.md) |
| The conformance kit every agent is tested against | `spec/fixtures/ingest/` |

## Reporting from an app

Create an app in Glass under **Settings › Apps** and mint an ingest key for
it. Then give the app:

```
GLASS_URL=http://glass
GLASS_API_KEY=glass_ing_…
```

Without both, every agent is inert. The agents are built to stay out of the
app's way: each uses one background thread with bounded buffers, drops data
rather than blocking, never retries into a server that is down, and stops
when its key is revoked.
Sampling, profiling and the other per-app settings are set in the console
and delivered to the agent with each reply, so an app never needs
redeploying to change them.

- **Rails**: vendor the gem with `bin/sync-client path/to/app` and add
  `gem "glass", path: "vendor/gems/glass"` after `gem "rails"`. Requests,
  SQL, views, cache, jobs, outbound HTTP, logs, profiles and visitor
  analytics report from the next boot.
- **Node**: `bin/sync-client path/to/app` vendors the client at
  `packages/glass`. It needs Node 24 or later and has no dependencies.
- **Go**: `go get github.com/fogapp/glass/clients/go`.

## Running Glass

Glass is a Fog app. `glass.fog.yaml` is its manifest: import it into Fog and
Fog builds the image, provisions the Postgres databases and secrets, runs
migrations in the release phase and swaps versions with no downtime.

Glass needs Postgres 18 with `pg_trgm`, `citext` and `pgcrypto`. It uses
four databases: configuration, telemetry, cache and queue. The
configuration database is small and is the only one in backups. Telemetry
is partitioned by day, kept for as long as **Settings › Retention** says,
and trimmed to stay within a disk budget.

## Local development

You need Ruby 3.4, Node 24, Go and Docker.

```bash
docker compose up -d db          # Postgres 18 on port 5438
bin/setup --skip-server          # gems, frontend packages, all four databases
bin/rails glass:demo             # a pretend fleet with a few days of telemetry
bin/dev                          # API on :3004, console on :5175
bin/ci                           # everything CI runs
```

Sign in at <http://localhost:5175> as `dev@glass.test` with the password
`glass-dev-password` (the demo task creates this account).
`bin/rails glass:demo:live` keeps the pretend fleet reporting through the
real ingest endpoint.

The house conventions are in [`CLAUDE.md`](CLAUDE.md) and
[`frontend/CLAUDE.md`](frontend/CLAUDE.md).

## License

Copyright (C) 2026 Matthew Werner

Glass is free software: you can redistribute it and/or modify it under the
terms of the GNU Affero General Public License as published by the Free
Software Foundation, version 3 (AGPL-3.0-only). See [LICENSE](LICENSE) for
the full text.

The agents under `clients/` (`ruby`, `node`, `go`, `browser`) are under the
MIT License instead, each with its own `LICENSE`, so an app of any license
can build one in to report to Glass. So are the Fog client libraries
vendored under `vendor/gems/`.

The names and logos (Fog, fogapp, Fin, Stream and Glass) are trademarks,
which the licenses don't cover. You may use them to refer to the software,
and run or redistribute it unmodified under them; a modified version you
distribute or offer to others needs its own name. See
[TRADEMARKS.md](TRADEMARKS.md).

Issues are welcome; pull requests aren't accepted for now. See
[CONTRIBUTING.md](CONTRIBUTING.md). To report a security problem, see
[SECURITY.md](SECURITY.md).
