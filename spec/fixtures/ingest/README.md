# The `glass-ingest/1` conformance kit

What every client is tested against, in whatever language it is written
(`clients/ruby`, `clients/node`, and whichever comes next). The protocol is
[`docs/ingest-protocol.md`](../../../docs/ingest-protocol.md); these files
are the same contract as data.

- `*.ndjson` — whole batch bodies as they travel: a header line, then one
  record per line. `rails.ndjson` is what the gem sends; `harness.ndjson`
  is an agent harness (a `run`, its spans, its model calls, the work it
  left behind); `tolerance.ndjson` is everything a server must survive —
  a kind it has never heard of (kept), fields that belong to another
  kind's facet (dropped), malformed and unknown records (skipped).
- `expected.json` — for each batch, how many records the server accepts and
  skips, and how many rows land where.
- `sketch.json` — the DDSketch mapping. A client's sketch must produce these
  indexes and these wire arrays exactly: sketches are merged by adding
  counts, so an index that is off by one skews every percentile silently.
  Its `folded` cases hold more buckets than a record may carry: the lowest
  are added into the lowest kept, never dropped.
- `origin.json` — how an agent decides a request's `origin` from its
  addresses, and which address it hashes into an anonymous `visitor`. A
  client that walks the chain the other way lets a visitor pick their own
  network class, and their own hash. Its `propagate` cases are where an
  outbound request may carry `traceparent` (protocol rule 8).
- `filter.json` — the keys whose values never leave the process, and keys
  that must survive. The same key is filtered by every client or by none.

The server reads `expected.json` and `sketch.json` in
`spec/services/ingest/conformance_spec.rb`. A client's suite should build
the records it sends and check them against the field tables in the
protocol document, and run `sketch.json` through its own sketch,
`origin.json` through its origin rule and `filter.json` through its
attribute filter.
