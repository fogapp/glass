# fog-client

The app-side view of Fog's federation. Fog injects `FOG_API_URL` and
`FOG_API_TOKEN` into every app it manages; this zero-dependency client wraps
that surface.

```ruby
FogClient.available?          # running under fog with the API surface injected?
FogClient.federation.peers    # => [Peer(name:, display_name:, instance_id:, online, apps: [DirectoryApp...])]
                              # address by name; show display_name to people
```

Two rules, by construction:

1. **Inert without Fog.** No env vars → `available?` is false, `peers` is
   `[]`, nothing raises. Apps must run identically outside the fog stack.
   Key any fog-assisted UI off `available?` and nothing else.
2. **Never hurt the host app.** Short timeouts on every phase of the HTTP
   exchange (open, read, write); every failure becomes an empty answer.
   Fog being down costs a feature, never a request.

## Caching and timeouts

`peers` is meant for the request path (rendering a household list), so a
successful answer is cached in-process for 30 seconds — one fog round-trip
per TTL window, not one per page view. Failures are never cached; the next
call retries. Tune or bypass per call, and tighten the HTTP bounds where a
render can't afford the defaults (open 2s / read 5s; introduce reads up to
20s because it relays across instances):

```ruby
FogClient.federation.peers(fresh: true)              # skip the cache (still refills it)
FogClient.federation.peers(ttl: 5)                   # accept a 5s-old answer
FogClient.federation.peers(open_timeout: 1, read_timeout: 1)
FogClient.federation.introduce(peer: "dave", app: "feed", read_timeout: 10)
```

## Reachability

`FogClient.federation.reachability` asks fog whether this household is
dialable from the internet — the same verdict fog shows its operator on the
Federation page — as a `Reachability(reachable?, url, via, tunnel_configured,
tunnel_running, advice)`. `via` is `"advertised"`, `"domain"` or `"none"`;
`advice` is the operator's next step when unreachable. Use it to say so
honestly in your own UI and to pause public delivery rather than burn
attempts; an unreachable household still federates with any peer that is
reachable itself. Uncached, `nil` outside fog or when fog is unreachable.

## Sign in with fog

`FogClient::Signin` is the relying-party half of `fog-signin/1`
(fog's docs/signin-contract.md): authorization code with PKCE, pushed
authorization requests, ES256 ID tokens verified with OpenSSL (no JOSE
dependency), back-channel logout, and the fog-only proof. It is plain
OpenID Connect, configured by `OIDC_ISSUER`, `OIDC_CLIENT_ID` and
`OIDC_CLIENT_SECRET` — fog injects them, and any other provider works the
same way. Without them `FogClient::Signin.config` is nil.

Rails apps `require "fog_client/signin/rails"` and include
`FogClient::Signin::Rails` in a controller outside their own
authentication, supplying an adapter that maps a verified identity onto
the app's accounts (the module's header lists what it answers). Accounts
are never matched by email: an unlinked identity is sent to `/auth/link`
to prove an existing account is theirs, or to start fresh — in the same
browser only (`__Host-fog_link`).

A **visitor** — a paired household's person, signed in by their own fog
(fog's docs/signin-contract.md) — has `identity.visitor?`, a subject
and `home` naming their household, and never an email. The linker never
bootstraps, adopts or links one: an app that hosts visitors (its `fog.yaml`
declares `signin.visitors`) answers `visit!(identity)` with a visitor's
account (and `visitor_account?(account)`, so a visitor never signs in as
anyone else); any other app refuses them. `link!` follows `visit!`, to
remember the visitor's identity. Refusals redirect to
`/login#signin_error=<code>`; `FogClient::Signin::VISITOR_REFUSALS` holds the
codes and the sentence for each.

The kit rate-limits the link step as `fog-link`: an adopter that limited
it itself should remove its own, or the two share the budget.

What every adopter must also do is listed at the top of
`lib/fog_client/signin/rails.rb`: refuse every local way in once fog-only
(passwords, passkeys, invites, sign-up, setup and its restore), throttle
the proof (`Proof.check_throttled`) on unauthenticated pages, filter
`code`, `pending` and `handoff` from logs, prune sessions whose handoff was
never redeemed, and give fog-created accounts an email only when fog marks
it verified and nobody holds it. The kit rate-limits `link` itself.

An app that already has a constant named `FogClient` must rename it first:
the gem's module takes that name.

`rbi/fog_client_signin.rbi` is the typed surface for Sorbet; copy it to the
app's `sorbet/rbi/shims/` when syncing the gem.

`FogClient::Signin::SCIM` (`signin/scim.rb`) is the app's provisioning
endpoint, and `FogClient::Signin::Device` the RFC 8628 device sign-in.

`test/vectors/signin.json` holds tokens fog's Go keyring signed, and the
verdict for each; fog's `internal/signin` tests check the same file with
go-jose, so the two implementations cannot drift apart silently.

## Tests

`cd clients/fog-client && rake test` — stdlib only, no gems to install.

Vendored into apps via `scripts/sync-fog-client` (same discipline as the
flare gem — Docker builds need zero credentials and zero network).
