// Package glass reports a Go program to Glass, the household's observability
// console, over glass-ingest/1 (docs/ingest-protocol.md): newline-delimited
// JSON, gzipped, one POST per ten-second window. The program is an app there
// like any other: its requests and jobs as transactions, the outbound calls
// inside them as spans, its log lines, its Go runtime as metrics, its CPU as
// profiles, and every model call as an llm record.
//
// It keeps the agent rules every Glass client keeps: a report never blocks
// the caller, a failed send is dropped and never retried, 429 pauses, 401
// stops until the key changes, and what is shed is counted in the next
// header. Until Set gives it an address and a key every call is a cheap
// no-op and nothing is queued.
package glass

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"math"
	"net/http"
	"os"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"
)

const (
	window    = 10 // seconds
	maxSeries = 500
	maxSpans  = 500
	// version is this client's, bare: process.runtime.agent. The client's
	// name goes beside it as process.runtime.client.
	version    = "0.1.0"
	clientName = "glass-go"
	agent      = clientName + "/" + version // the User-Agent
	gamma      = 1.02
	minValue   = 1e-9
	maxBuckets = 2048

	// A batch is at most this many records and inflated bytes; a 413
	// halves both, down to the floors, and six accepted batches in a row
	// double them back. The server allows 20,000 records and 32 MiB.
	defaultMaxRecords = 10000
	minMaxRecords     = 250
	defaultMaxBytes   = 16 << 20
	minMaxBytes       = 256 << 10
	recoverAfter      = 6

	// A series carries at most this many tags, each value at most this
	// many characters; past them the rest are dropped, as the gem does.
	maxTags     = 20
	maxTagValue = 200
)

// metricName is the form a metric's name must take; a series under any
// other name is dropped and counted.
var metricName = regexp.MustCompile(`^[a-zA-Z][a-zA-Z0-9_.:-]{0,119}$`)

// recordTypes are the record types of glass-ingest/1 this client sends, in
// the order a batch takes them: the cheap uniform rows first, the bulky
// optional ones last.
var recordTypes = []string{"txn", "llm", "metric", "marker", "span", "log", "profile"}

// queueLimits bounds each type's buffer between flushes; past it a record
// is dropped and counted.
var queueLimits = map[string]int{
	"txn": 5000, "llm": 10000, "metric": 10000, "marker": 500, "span": 20000, "log": 5000, "profile": 8,
}

var defaultClient atomic.Pointer[Client]

// SetDefault makes c the client the package-level calls (Start, StartSpan,
// Count, Gauge, Dist) report through.
func SetDefault(c *Client) { defaultClient.Store(c) }

// Default is the client SetDefault set, or nil (inert).
func Default() *Client { return defaultClient.Load() }

// Client batches and sends. A nil *Client is inert.
type Client struct {
	release string
	kind    string
	started float64
	http    *http.Client

	mu       sync.Mutex
	endpoint string
	key      string
	windows  map[int64]map[string]*series
	bufs     map[string][]any
	dropped  map[string]int
	pause    time.Time
	halted   bool
	// The batch limits, halved by a 413 and grown back by a run of
	// accepted batches.
	maxRecords int
	maxBytes   int
	accepted   int
	// From the directives in Glass's last reply.
	sampleRate float64
	logLevel   slog.Level
	logOff     bool
	profiling  bool
	profileNow *profileNow
	// Per transaction name: its first sighting this boot, and its recent
	// durations for the slow-outlier test.
	seen map[string]*durations

	gc gcState
}

// New returns an unconfigured client; Set points it at Glass.
func New(release string) *Client {
	return &Client{
		release:    release,
		kind:       "app",
		started:    float64(time.Now().UnixNano()) / 1e9,
		http:       &http.Client{Timeout: 5 * time.Second},
		windows:    map[int64]map[string]*series{},
		bufs:       map[string][]any{},
		dropped:    map[string]int{},
		maxRecords: defaultMaxRecords,
		maxBytes:   defaultMaxBytes,
		sampleRate: 0.1,
		logLevel:   slog.LevelInfo,
		seen:       map[string]*durations{},
	}
}

// SetKind names the process (process.kind in the batch header): web, worker,
// or any short label. Call it before the client runs.
func (c *Client) SetKind(kind string) {
	if c != nil && kind != "" {
		c.kind = kind
	}
}

// Set points the client at Glass's base URL with an ingest key; either
// empty makes it inert again and forgets what was queued. A new key lifts a
// 401 stop.
func (c *Client) Set(baseURL, key string) {
	if c == nil {
		return
	}
	endpoint := ""
	if baseURL != "" && key != "" {
		endpoint = strings.TrimRight(baseURL, "/") + "/ingest/v1/batch"
	} else {
		key = ""
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if key != c.key {
		c.halted = false
	}
	c.endpoint, c.key = endpoint, key
	if key == "" {
		c.windows = map[int64]map[string]*series{}
		c.bufs = map[string][]any{}
	}
}

// Halted is true once Glass refused the key (401/403); only a new key
// through Set sends again.
func (c *Client) Halted() bool {
	if c == nil {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.halted
}

// profileNow is a one-shot request from Glass's console.
type profileNow struct {
	ID      string `json:"id"`
	Seconds int    `json:"seconds"`
	HZ      int    `json:"hz"`
}

func (c *Client) profileDirectives() (bool, *profileNow) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.profiling, c.profileNow
}

// sketchIndex is the DDSketch bucket of a value; values too small to have
// one answer false.
func sketchIndex(v float64) (int, bool) {
	if v <= minValue {
		return 0, false
	}
	return int(math.Ceil(math.Log(v) / math.Log(gamma))), true
}

// activeLocked: configured and not stopped. Caller holds mu.
func (c *Client) activeLocked() bool { return c.key != "" && !c.halted }

func (c *Client) active() bool {
	if c == nil {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.activeLocked()
}

// enqueue adds one record of type kind to its buffer, or counts it shed.
func (c *Client) enqueue(kind string, rec any) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.enqueueLocked(kind, rec)
}

func (c *Client) enqueueLocked(kind string, rec any) {
	if !c.activeLocked() {
		return
	}
	if len(c.bufs[kind]) >= queueLimits[kind] {
		c.dropped[kind]++
		return
	}
	c.bufs[kind] = append(c.bufs[kind], rec)
}

// ---- metrics ----

type series struct {
	name, kind, unit string
	tags             map[string]string
	n                int
	sum, min, max    float64
	last             float64
	sketch           map[int]int
}

func seriesKey(kind, name string, tags map[string]string) string {
	keys := make([]string, 0, len(tags))
	for k := range tags {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	b.WriteString(kind + "\x00" + name)
	for _, k := range keys {
		b.WriteString("\x00" + k + "=" + tags[k])
	}
	return b.String()
}

// normalizeTags bounds tags as the gem does: the first maxTags by key,
// each value cut to maxTagValue characters. Tags within the bounds come
// back as they are (the caller's map: a series copies it); others as a
// new map.
func normalizeTags(tags map[string]string) map[string]string {
	if len(tags) == 0 {
		return nil
	}
	fits := len(tags) <= maxTags
	for _, v := range tags {
		if !fits {
			break
		}
		fits = utf8.RuneCountInString(v) <= maxTagValue
	}
	if fits {
		return tags
	}
	keys := make([]string, 0, len(tags))
	for k := range tags {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	if len(keys) > maxTags {
		keys = keys[:maxTags]
	}
	out := make(map[string]string, len(keys))
	for _, k := range keys {
		out[k] = truncateRunes(tags[k], maxTagValue)
	}
	return out
}

func truncateRunes(s string, n int) string {
	for i := range s {
		if n == 0 {
			return s[:i]
		}
		n--
	}
	return s
}

func copyTags(tags map[string]string) map[string]string {
	if len(tags) == 0 {
		return nil
	}
	out := make(map[string]string, len(tags))
	for k, v := range tags {
		out[k] = v
	}
	return out
}

func (c *Client) observe(kind, name, unit string, v float64, tags map[string]string) {
	if c == nil || math.IsNaN(v) || math.IsInf(v, 0) {
		return
	}
	tags = normalizeTags(tags)
	w := time.Now().Unix() / window * window
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.activeLocked() {
		return
	}
	m := c.windows[w]
	if m == nil {
		m = map[string]*series{}
		c.windows[w] = m
	}
	k := seriesKey(kind, name, tags)
	s := m[k]
	if s == nil {
		if len(m) >= maxSeries || !metricName.MatchString(name) {
			c.dropped["metric"]++
			return
		}
		// A copy: the caller's map is theirs, and may change after this.
		s = &series{name: name, kind: kind, unit: unit, tags: copyTags(tags), min: v, max: v}
		if kind == "dist" {
			s.sketch = map[int]int{}
		}
		m[k] = s
	}
	s.n++
	s.sum += v
	s.min, s.max, s.last = math.Min(s.min, v), math.Max(s.max, v), v
	if i, ok := sketchIndex(v); ok && s.sketch != nil {
		s.sketch[i]++
	}
}

// Count adds n to a counter.
func (c *Client) Count(name string, n float64, tags map[string]string) {
	c.observe("counter", name, "", n, tags)
}

// Gauge records a level, in unit ("bytes", "percent", or "").
func (c *Client) Gauge(name, unit string, v float64, tags map[string]string) {
	c.observe("gauge", name, unit, v, tags)
}

// Dist records one observation of a distribution, in unit ("ms").
func (c *Client) Dist(name, unit string, v float64, tags map[string]string) {
	c.observe("dist", name, unit, v, tags)
}

func (s *series) record(w int64) map[string]any {
	r := map[string]any{"t": "metric", "ts": w, "name": s.name, "kind": s.kind, "n": s.n, "sum": s.sum}
	if s.unit != "" {
		r["unit"] = s.unit
	}
	if len(s.tags) > 0 {
		r["tags"] = s.tags
	}
	if s.kind == "gauge" || s.kind == "dist" {
		r["min"], r["max"], r["last"] = s.min, s.max, s.last
	}
	if s.kind == "dist" {
		r["sk"] = sketchPairs(s.sketch)
	}
	return r
}

// sketchPairs is a sketch's wire form: alternating index and count,
// ascending by index. Past maxBuckets the lowest buckets are folded into
// the lowest kept one, as the gem and the Node client fold them: the tail
// that matters for latency is the top.
func sketchPairs(sketch map[int]int) []int {
	idx := make([]int, 0, len(sketch))
	for i := range sketch {
		idx = append(idx, i)
	}
	sort.Ints(idx)
	folded := 0
	if len(idx) > maxBuckets {
		keep := len(idx) - maxBuckets
		for _, i := range idx[:keep] {
			folded += sketch[i]
		}
		idx = idx[keep:]
	}
	pairs := make([]int, 0, 2*len(idx))
	for n, i := range idx {
		count := sketch[i]
		if n == 0 {
			count += folded
		}
		pairs = append(pairs, i, count)
	}
	return pairs
}

// ---- sending ----

// Run samples the Go runtime and flushes every window until ctx ends, then
// flushes once more.
func (c *Client) Run(ctx context.Context) {
	if c == nil {
		return
	}
	go c.profile(ctx)
	t := time.NewTicker(window * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			c.flush(true)
			return
		case <-t.C:
			c.sampleRuntime()
			c.flush(false)
		}
	}
}

// Body builds one batch from every closed window (all of them when final)
// and the buffered records, taking what it carries; what does not fit the
// batch limits stays for the next one. With nothing to send it is the
// header alone, which is the process's heartbeat. Nil when the client is
// inert. Exported for tests.
func (c *Client) Body(final bool) []byte {
	body, _ := c.build(final)
	return body
}

// drainLocked moves every closed metric window (all when final) into the
// metric buffer. Caller holds mu.
func (c *Client) drainLocked(final bool) {
	now := time.Now().Unix()
	ws := make([]int64, 0, len(c.windows))
	for w := range c.windows {
		ws = append(ws, w)
	}
	sort.Slice(ws, func(i, j int) bool { return ws[i] < ws[j] })
	for _, w := range ws {
		if !final && w+window > now {
			continue
		}
		keys := make([]string, 0, len(c.windows[w]))
		for k := range c.windows[w] {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			c.enqueueLocked("metric", c.windows[w][k].record(w))
		}
		delete(c.windows, w)
	}
}

// build is Body, and how many records of each type the batch carries — what
// is counted shed when it fails to go.
func (c *Client) build(final bool) ([]byte, map[string]int) {
	c.mu.Lock()
	if !c.activeLocked() {
		c.mu.Unlock()
		return nil, nil
	}
	c.drainLocked(final)
	// Take up to maxRecords now, and encode them outside the lock: a report
	// never waits on a flush.
	limit, maxBytes := c.maxRecords, c.maxBytes
	taken := make(map[string][]any, len(recordTypes))
	for _, typ := range recordTypes {
		n := min(len(c.bufs[typ]), limit)
		if n == 0 {
			continue
		}
		taken[typ] = c.bufs[typ][:n:n]
		c.bufs[typ] = c.bufs[typ][n:]
		limit -= n
	}
	c.mu.Unlock()

	var lines bytes.Buffer
	carried := map[string]int{}
	unsendable := map[string]int{}
	left := map[string][]any{}
	size := 0
	full := false
	for _, typ := range recordTypes {
		for i, r := range taken[typ] {
			if full {
				left[typ] = taken[typ][i:]
				break
			}
			line, err := json.Marshal(r)
			if err != nil {
				unsendable[typ]++
				continue
			}
			if size+len(line)+1 > maxBytes {
				full = true
				left[typ] = taken[typ][i:]
				break
			}
			lines.Write(line)
			lines.WriteByte('\n')
			size += len(line) + 1
			carried[typ]++
		}
	}

	c.mu.Lock()
	for typ, rs := range left {
		if !c.activeLocked() {
			break
		}
		// What did not fit goes back to the front of its buffer, for the
		// next batch.
		c.bufs[typ] = append(append(make([]any, 0, len(rs)+len(c.bufs[typ])), rs...), c.bufs[typ]...)
	}
	for typ, n := range unsendable {
		c.dropped[typ] += n
	}
	dropped := make(map[string]int, len(c.dropped))
	for k, v := range c.dropped {
		dropped[k] = v
	}
	c.mu.Unlock()

	host, _ := os.Hostname()
	process := map[string]any{
		"kind": c.kind, "host": host, "pid": os.Getpid(), "started_at": c.started,
		"runtime": map[string]string{"go": runtime.Version(), "agent": version, "client": clientName},
	}
	if c.release != "" {
		process["release"] = c.release
	}
	head, _ := json.Marshal(map[string]any{"v": 1, "process": process, "sent_at": float64(time.Now().UnixNano()) / 1e9, "dropped": dropped})
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	zw.Write(head)
	zw.Write([]byte{'\n'})
	zw.Write(lines.Bytes())
	zw.Close()
	return gz.Bytes(), carried
}

// discard drops what Body would have sent, counting it shed, so the next
// batch that goes tells Glass what the pause cost.
func (c *Client) discard(final bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.drainLocked(final)
	for typ, rs := range c.bufs {
		c.dropped[typ] += len(rs)
	}
	c.bufs = map[string][]any{}
}

func (c *Client) flush(final bool) {
	c.mu.Lock()
	endpoint, key := c.endpoint, c.key
	paused := time.Now().Before(c.pause)
	stopped := !c.activeLocked()
	c.mu.Unlock()
	if stopped {
		return
	}
	if paused {
		c.discard(final)
		return
	}
	body, carried := c.build(final)
	if body == nil {
		return
	}
	// A batch that does not land is shed; the next header says so.
	shed := func() {
		for k, n := range carried {
			c.dropped[k] += n
		}
	}
	req, err := http.NewRequest("POST", endpoint, bytes.NewReader(body))
	if err != nil {
		c.mu.Lock()
		shed()
		c.mu.Unlock()
		return
	}
	req.Header.Set("Content-Type", "application/x-ndjson")
	req.Header.Set("Content-Encoding", "gzip")
	req.Header.Set("User-Agent", agent)
	req.Header.Set("Authorization", "Bearer "+key)
	res, err := c.http.Do(req)
	if err != nil {
		c.mu.Lock()
		shed()
		c.mu.Unlock()
		return
	}
	defer res.Body.Close()
	reply, _ := io.ReadAll(io.LimitReader(res.Body, 64<<10))
	c.mu.Lock()
	defer c.mu.Unlock()
	switch res.StatusCode {
	case http.StatusAccepted, http.StatusOK:
		c.accepted++
		if c.accepted >= recoverAfter && (c.maxRecords < defaultMaxRecords || c.maxBytes < defaultMaxBytes) {
			c.accepted = 0
			c.maxRecords = min(c.maxRecords*2, defaultMaxRecords)
			c.maxBytes = min(c.maxBytes*2, defaultMaxBytes)
		}
		c.applyLocked(reply)
	case http.StatusUnauthorized, http.StatusForbidden:
		shed()
		c.halted = true
	case http.StatusRequestEntityTooLarge:
		// Too big for Glass: this batch is gone, and the next is half the size.
		c.maxRecords = max(c.maxRecords/2, minMaxRecords)
		c.maxBytes = max(c.maxBytes/2, minMaxBytes)
		c.accepted = 0
		shed()
	case http.StatusTooManyRequests:
		secs, err := strconv.Atoi(res.Header.Get("Retry-After"))
		if err != nil || secs < 1 || secs > 300 {
			secs = 60
		}
		shed()
		c.pause = time.Now().Add(time.Duration(secs) * time.Second)
	default:
		shed()
	}
}

// applyLocked takes the directives this agent understands from an ingest
// reply and ignores the rest. Caller holds mu.
func (c *Client) applyLocked(reply []byte) {
	var r struct {
		Directives struct {
			TraceSampleRate *float64    `json:"trace_sample_rate"`
			LogLevel        string      `json:"log_level"`
			Profiling       *bool       `json:"profiling"`
			ProfileNow      *profileNow `json:"profile_now"`
		} `json:"directives"`
	}
	if json.Unmarshal(reply, &r) != nil {
		return
	}
	if v := r.Directives.TraceSampleRate; v != nil && *v >= 0 && *v <= 1 {
		c.sampleRate = *v
	}
	if r.Directives.Profiling != nil {
		c.profiling = *r.Directives.Profiling
	}
	c.profileNow = r.Directives.ProfileNow
	switch r.Directives.LogLevel {
	case "debug":
		c.logLevel, c.logOff = slog.LevelDebug, false
	case "info":
		c.logLevel, c.logOff = slog.LevelInfo, false
	case "warn":
		c.logLevel, c.logOff = slog.LevelWarn, false
	case "error":
		c.logLevel, c.logOff = slog.LevelError, false
	case "off":
		c.logOff = true
	}
}
