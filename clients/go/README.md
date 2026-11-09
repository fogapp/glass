# Glass's Go client

Reports a Go program over `glass-ingest/1`: requests, spans, logs, runtime
vitals, profiles and `llm` records.

```go
client := glass.New(release)
client.SetKind("web")
client.Set(os.Getenv("GLASS_URL"), os.Getenv("GLASS_API_KEY"))
glass.SetDefault(client) // the package-level Start, StartSpan, ModelCall report through it
go client.Run(ctx)

slog.SetDefault(slog.New(client.LogHandler(slog.NewJSONHandler(os.Stderr, nil))))
http.ListenAndServe(addr, client.Middleware(mux))
```

`glass.Middleware` and `glass.LogHandler` are the same on whichever client
`SetDefault` names when a request or a line arrives, so they can be built
before it is set. With no URL or key it is an inert no-op, as every Glass
client is.
It is tested against the conformance kit in `spec/fixtures/ingest/`.
