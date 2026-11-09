# flare

Error reporting to Fog's built-in tracker. Zero runtime dependencies; the
whole client is a `Rails.error` subscriber, a Sentry-schema event builder,
and one background thread with a bounded queue.

## How apps get it

Vendored, not fetched — Docker builds need zero credentials and zero network:

```ruby
# Gemfile
gem "flare", path: "vendor/gems/flare"
```

Copies are synced from this canonical source by `scripts/sync-flare` in the
fog repo. Edit here, sync, commit in each app.

## How it works

- Fog injects `FLARE_DSN` into every managed app's container. No DSN
  (development, test, running outside Fog) → the gem is completely inert.
- On Rails 7.1+ the railtie's `Rails.error.subscribe` covers unhandled
  errors in HTTP requests, ActiveJob jobs, and runners — no middleware.
- Rescued errors report via `Rails.error.report(e, handled: true)` (the
  Activity bridge in each app) or `Flare.notify(e, context: {...})`.
- Delivery: bounded queue (100), drop on overflow, drop on connection
  failure, pause on 429 Retry-After, 2s flush at exit. The reporter can
  never hurt the app it reports for.
- Params ride through `request.filtered_parameters` (the app's own
  filter_parameters) plus a built-in key scrub (password/token/secret/…).

The wire format is Sentry's envelope + event schema, so pointing the
official `sentry-ruby` SDK at the same DSN is always a drop-in alternative.

## Tests

```
cd clients/flare && rake
```
