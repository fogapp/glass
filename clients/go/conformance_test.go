package glass

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"strings"
	"testing"
	"time"
)

// The sketch mapping is the one thing every client must match exactly:
// sketches merge by adding counts, so an index off by one skews every
// percentile silently.
func TestSketchConformance(t *testing.T) {
	raw, err := os.ReadFile("../../spec/fixtures/ingest/sketch.json")
	if err != nil {
		t.Fatal(err)
	}
	type wire struct {
		Values []float64 `json:"values"`
		N      int       `json:"n"`
		SK     []int     `json:"sk"`
	}
	var kit struct {
		Indexes []struct {
			Value float64 `json:"value"`
			Index *int    `json:"index"`
		} `json:"indexes"`
		Sketches []wire `json:"sketches"`
		Folded   []wire `json:"folded"`
	}
	if err := json.Unmarshal(raw, &kit); err != nil {
		t.Fatal(err)
	}
	if len(kit.Indexes) == 0 || len(kit.Sketches) == 0 || len(kit.Folded) == 0 {
		t.Fatal("no vectors")
	}
	for _, v := range kit.Indexes {
		got, ok := sketchIndex(v.Value)
		if v.Index == nil {
			if ok {
				t.Errorf("%g has no bucket, got %d", v.Value, got)
			}
			continue
		}
		if !ok || got != *v.Index {
			t.Errorf("%g: want bucket %d, got %d", v.Value, *v.Index, got)
		}
	}
	// Through the client itself: a dist series' record carries the pairs.
	for i, w := range append(kit.Sketches, kit.Folded...) {
		s := &series{kind: "dist", sketch: map[int]int{}}
		for _, v := range w.Values {
			s.n++
			if i, ok := sketchIndex(v); ok {
				s.sketch[i]++
			}
		}
		rec := s.record(0)
		if got := rec["sk"].([]int); !slices.Equal(got, w.SK) {
			t.Errorf("case %d: wire pairs differ (%d ints, want %d; first %v, want %v)", i, len(got), len(w.SK), got[:min(4, len(got))], w.SK[:min(4, len(w.SK))])
		}
		if rec["n"] != w.N {
			t.Errorf("case %d: n = %v, want %d", i, rec["n"], w.N)
		}
	}
}

// Every client decides a request's origin the same way, walking the chain
// from the nearest hop: origin.json is the kit the gem and the Node client
// are held to as well.
func TestOriginConformance(t *testing.T) {
	raw, err := os.ReadFile("../../spec/fixtures/ingest/origin.json")
	if err != nil {
		t.Fatal(err)
	}
	var kit struct {
		Cases []struct {
			Remote    string  `json:"remote"`
			Forwarded string  `json:"forwarded"`
			CF        *string `json:"cf_connecting_ip"`
			Ray       *string `json:"cf_ray"`
			Origin    *string `json:"origin"`
			Address   *string `json:"address"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &kit); err != nil {
		t.Fatal(err)
	}
	if len(kit.Cases) == 0 {
		t.Fatal("no cases")
	}
	str := func(p *string) string {
		if p == nil {
			return ""
		}
		return *p
	}
	for _, c := range kit.Cases {
		origin, address := originOf(c.Remote, c.Forwarded, c.CF, c.Ray != nil)
		if origin != str(c.Origin) || address != str(c.Address) {
			t.Errorf("%+v: got %q from %q, want %q from %q", c, origin, address, str(c.Origin), str(c.Address))
		}
	}

	// And through the middleware, from the request as net/http hands it over.
	c, f := setup(t)
	h := c.Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	for _, hop := range []struct{ remote, forwarded, cf string }{
		{"127.0.0.1:5000", "100.88.12.34", ""},
		{"10.0.0.2:5000", "192.168.1.5, 203.0.113.9", ""},
		{"10.0.0.2:5000", "", "203.0.113.7"},
		{"[::1]:5000", "", ""},
	} {
		req := httptest.NewRequest("GET", "/", nil)
		req.RemoteAddr = hop.remote
		if hop.forwarded != "" {
			req.Header.Set("X-Forwarded-For", hop.forwarded)
		}
		if hop.cf != "" {
			req.Header.Set("CF-Connecting-IP", hop.cf)
		}
		h.ServeHTTP(httptest.NewRecorder(), req)
	}
	c.flush(true)
	var got []any
	for _, r := range f.ofType("txn") {
		got = append(got, r["origin"])
	}
	if want := []any{"vpn", "public", "tunnel", "lan"}; !slices.Equal(got, want) {
		t.Errorf("origins %v, want %v", got, want)
	}
}

// traceparent goes to the same hosts from every client: origin.json's
// propagate cases are the kit the gem and the Node client are held to too.
func TestPropagateConformance(t *testing.T) {
	raw, err := os.ReadFile("../../spec/fixtures/ingest/origin.json")
	if err != nil {
		t.Fatal(err)
	}
	var kit struct {
		PropagateTo []string `json:"propagate_to"`
		Propagate   []struct {
			Host      string `json:"host"`
			Propagate bool   `json:"propagate"`
		} `json:"propagate"`
	}
	if err := json.Unmarshal(raw, &kit); err != nil {
		t.Fatal(err)
	}
	if len(kit.Propagate) == 0 {
		t.Fatal("no propagate cases")
	}
	for _, c := range kit.Propagate {
		if got := ours(c.Host, kit.PropagateTo); got != c.Propagate {
			t.Errorf("ours(%q) = %v, want %v", c.Host, got, c.Propagate)
		}
	}
}

// The same key is filtered by every client or by none: filter.json is the
// kit the gem and the Node client are held to as well.
func TestFilterConformance(t *testing.T) {
	raw, err := os.ReadFile("../../spec/fixtures/ingest/filter.json")
	if err != nil {
		t.Fatal(err)
	}
	var kit struct {
		Filtered []string `json:"filtered"`
		Kept     []string `json:"kept"`
	}
	if err := json.Unmarshal(raw, &kit); err != nil {
		t.Fatal(err)
	}
	if len(kit.Filtered) == 0 || len(kit.Kept) == 0 {
		t.Fatal("no cases")
	}
	for _, key := range kit.Filtered {
		if !FilteredKey(key) {
			t.Errorf("%q must be filtered", key)
		}
		if got := attrValue(key, "s3cret"); got != Filtered {
			t.Errorf("%q sent as %v", key, got)
		}
	}
	for _, key := range kit.Kept {
		if FilteredKey(key) {
			t.Errorf("%q must be kept", key)
		}
	}
}

// Every way an attribute leaves the process goes through the filter.
func TestSecretsNeverLeaveTheProcess(t *testing.T) {
	c, f := setup(t)
	log := slog.New(LogHandler(slog.NewTextHandler(io.Discard, nil)))
	ctx, txn := Start(context.Background(), "job", "deploy")
	txn.Attr("api_key", "s3cret")
	txn.Attr("app", "manor")
	sctx, sp := StartSpan(ctx, "db", "select", "users")
	sp.Attr("password", "s3cret")
	sp.Attr("rows", 3)
	sp.End(nil)
	log.InfoContext(sctx, "signed in", "user_id", 7, "token", "s3cret",
		slog.Group("session", "id", "s3cret"), slog.Group("req", "Cookie", "s3cret", "path", "/"))
	log.WithGroup("auth").With("user", "s3cret").InfoContext(ctx, "grouped", "pass", "s3cret")
	attrs := map[string]any{"client_secret": "s3cret", "input_tokens": 12}
	ModelCall(ctx, time.Now(), LLM{Provider: "p", Model: "m", Attrs: attrs})
	txn.End(nil)
	c.flush(true)

	if attrs["client_secret"] != "s3cret" {
		t.Error("ModelCall changed the caller's map")
	}
	want := map[string]map[string]any{
		"txn":  {"api_key": Filtered, "app": "manor"},
		"span": {"password": Filtered, "rows": 3.0},
		"llm":  {"client_secret": Filtered, "input_tokens": 12.0},
	}
	for typ, fields := range want {
		recs := f.ofType(typ)
		if len(recs) != 1 {
			t.Fatalf("%s: %v", typ, recs)
		}
		got, _ := recs[0]["attrs"].(map[string]any)
		for k, v := range fields {
			if got[k] != v {
				t.Errorf("%s attrs[%s] = %v, want %v", typ, k, got[k], v)
			}
		}
	}
	logs := f.ofType("log")
	if len(logs) != 2 {
		t.Fatalf("logs: %v", logs)
	}
	first := logs[0]["attrs"].(map[string]any)
	for k, v := range map[string]any{"user_id": 7.0, "token": Filtered, "session": Filtered, "req.Cookie": Filtered, "req.path": "/"} {
		if first[k] != v {
			t.Errorf("log attrs[%s] = %v, want %v (%v)", k, first[k], v, first)
		}
	}
	if second := logs[1]["attrs"].(map[string]any); len(second) != 1 || second["auth"] != Filtered {
		t.Errorf("a filtered group sends only its name: %v", second)
	}
	for _, typ := range []string{"txn", "span", "log", "llm"} {
		for _, r := range f.ofType(typ) {
			if b, _ := json.Marshal(r); strings.Contains(string(b), "s3cret") {
				t.Errorf("a secret left the process: %s", b)
			}
		}
	}
}

// batch captures what the client sends.
func batch(t *testing.T, reply string) (*httptest.Server, func() []map[string]any) {
	t.Helper()
	got := make(chan []byte, 8)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if r.Header.Get("Content-Encoding") == "gzip" {
			z, err := gzip.NewReader(bytes.NewReader(body))
			if err != nil {
				t.Error(err)
				return
			}
			body, _ = io.ReadAll(z)
		}
		got <- body
		w.WriteHeader(http.StatusAccepted)
		io.WriteString(w, reply)
	}))
	return srv, func() []map[string]any {
		select {
		case body := <-got:
			var out []map[string]any
			lines := bufio.NewScanner(bytes.NewReader(body))
			lines.Buffer(make([]byte, 1<<20), 1<<24)
			for lines.Scan() {
				var rec map[string]any
				if err := json.Unmarshal(lines.Bytes(), &rec); err != nil {
					t.Fatal(err)
				}
				out = append(out, rec)
			}
			return out
		case <-time.After(5 * time.Second):
			t.Fatal("nothing was sent")
			return nil
		}
	}
}

func TestLLMRecordCarriesStageFields(t *testing.T) {
	srv, next := batch(t, `{"accepted":1,"directives":{}}`)
	defer srv.Close()
	c := New("rel")
	c.SetKind("think")
	c.Set(srv.URL, "glass_ing_x")
	c.ModelCall(context.Background(), time.Now(), LLM{
		Provider: "llama.cpp", Model: "m", Tier: "local", Origin: "eval", In: 10, CacheRead: 4, Out: 5,
		TTFT: 100, ITLP95: 40, QueueMS: 1, LoadMS: 2, PromptMS: 3, DecodeMS: 4, CostSrc: "free",
	})
	c.flush(true)
	recs := next()
	if head := recs[0]["process"].(map[string]any); head["kind"] != "think" {
		t.Fatalf("header: %v", recs[0])
	}
	var llm map[string]any
	for _, r := range recs {
		if r["t"] == "llm" {
			llm = r
		}
	}
	if llm == nil {
		t.Fatalf("no llm record in %v", recs)
	}
	for field, want := range map[string]float64{"cache_read": 4, "itl_p95": 40, "queue_ms": 1, "load_ms": 2, "prompt_ms": 3, "decode_ms": 4} {
		if llm[field] != want {
			t.Errorf("%s = %v, want %v", field, llm[field], want)
		}
	}
	if llm["origin"] != "eval" {
		t.Errorf("origin = %v", llm["origin"])
	}
}

func TestNoPromptFieldExists(t *testing.T) {
	b, _ := json.Marshal(LLM{Provider: "p", Model: "m"})
	for _, banned := range []string{"prompt\"", "completion", "messages"} {
		if strings.Contains(string(b), banned) {
			t.Fatalf("%s must never be a field: %s", banned, b)
		}
	}
}

func TestProfileDirectiveProducesARecord(t *testing.T) {
	stop := make(chan struct{})
	go func() {
		for {
			select {
			case <-stop:
				return
			default:
				_ = strings.Repeat("x", 4096)
			}
		}
	}()
	defer close(stop)
	rec := cpuWindow(context.Background(), 400*time.Millisecond, func() bool { return false })
	if rec == nil {
		t.Skip("the profiler saw nothing, or is in use")
	}
	if rec["t"] != "profile" || rec["mode"] != "cpu" {
		t.Fatalf("got %v", rec)
	}
}
