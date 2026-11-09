// Command emit prints one batch body, as the client would send it, for the
// server's suite to read (spec/services/ingest/go_client_spec.rb): the one
// test in which the Go client and the real ingest builders meet. It never
// touches the network.
package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"time"

	glass "github.com/fogapp/glass/clients/go"
)

func main() {
	c := glass.New("5cec02a")
	c.SetKind("web")
	c.Set("http://glass.test", "glass_ing_test")
	log := slog.New(c.LogHandler(slog.NewTextHandler(io.Discard, nil)))

	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/apps/{name}", func(w http.ResponseWriter, r *http.Request) {
		ctx, sp := glass.StartSpan(r.Context(), "sql", "App Load", "SELECT apps")
		sp.Attr("rows", 1)
		sp.End(nil)
		log.InfoContext(ctx, "\x1b[32mloaded\x1b[0m app", "app", r.PathValue("name"), "password", "s3cret")
		c.ModelCall(ctx, time.Now().Add(-640*time.Millisecond), glass.LLM{
			Provider: "llama.cpp", Model: "qwen3:8b", Tier: "local", Purpose: "title", Origin: "internal",
			In: 900, Out: 24, CostSrc: "free", Stop: "end_turn",
		})
		w.WriteHeader(http.StatusOK)
	})
	req := httptest.NewRequest("GET", "/api/apps/manor", nil)
	req.RemoteAddr = "127.0.0.1:41000"
	req.Header.Set("X-Forwarded-For", "100.88.12.34")
	c.Middleware(mux).ServeHTTP(httptest.NewRecorder(), req)

	ctx, job := c.Start(context.Background(), "job", "backup")
	_, sp := glass.StartSpan(ctx, "custom", "snapshot", "")
	sp.End(nil)
	job.End(errors.New("disk full"))

	c.Count("jobs.done", 1, map[string]string{"queue": "default"})
	c.Gauge("go.goroutines", "", 12, nil)
	c.Dist("fog.backup.ms", "ms", 250, nil)
	c.Dist("fog.backup.ms", "ms", 1000, nil)

	z, err := gzip.NewReader(bytes.NewReader(c.Body(true)))
	if err != nil {
		panic(err)
	}
	io.Copy(os.Stdout, z)
}
