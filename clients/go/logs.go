package glass

import (
	"context"
	"log/slog"
	"regexp"
	"strings"
	"time"
)

// ansi is a terminal colour or cursor code: for a terminal, not for Glass
// (the gem's Glass::Logs::ANSI).
var ansi = regexp.MustCompile(`\x1b\[[0-9;]*[A-Za-z]`)

type logRecord struct {
	T     string         `json:"t"`
	TS    float64        `json:"ts"`
	Lvl   string         `json:"lvl"`
	Msg   string         `json:"msg"`
	Src   string         `json:"src"`
	Trace string         `json:"trace,omitempty"`
	Span  string         `json:"span,omitempty"`
	Attrs map[string]any `json:"attrs,omitempty"`
}

// LogHandler is c.LogHandler on the default client, whichever client that
// is when a line is logged: the handler can be installed before SetDefault.
func LogHandler(next slog.Handler) slog.Handler { return &logHandler{next: next, client: Default} }

// LogHandler passes every record on to next and also ships it to c when it
// is at or above the log_level directive Glass sent. A line logged with a
// context inside a transaction carries its trace and span, so the trace
// shows its own logs.
func (c *Client) LogHandler(next slog.Handler) slog.Handler {
	return &logHandler{next: next, client: func() *Client { return c }}
}

type logHandler struct {
	next   slog.Handler
	client func() *Client
	attrs  []slog.Attr
	groups []string
}

func (h *logHandler) wants(c *Client, level slog.Level) bool {
	if c == nil {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.activeLocked() && !c.logOff && level >= c.logLevel
}

func (h *logHandler) Enabled(ctx context.Context, level slog.Level) bool {
	return h.next.Enabled(ctx, level) || h.wants(h.client(), level)
}

func (h *logHandler) Handle(ctx context.Context, r slog.Record) error {
	var err error
	if h.next.Enabled(ctx, r.Level) {
		err = h.next.Handle(ctx, r)
	}
	c := h.client()
	if !h.wants(c, r.Level) {
		return err
	}
	msg := r.Message
	if strings.Contains(msg, "\x1b") {
		msg = ansi.ReplaceAllString(msg, "")
	}
	rec := &logRecord{T: "log", TS: unixSeconds(r.Time), Lvl: levelName(r.Level), Msg: truncate(msg, 8000), Src: "app"}
	if r.Time.IsZero() {
		rec.TS = unixSeconds(time.Now())
	}
	if s := scopeOf(ctx); s != nil && s.txn != nil {
		rec.Trace, rec.Span = s.trace, s.span
	}
	attrs := map[string]any{}
	for _, a := range h.attrs {
		flatten(attrs, "", a)
	}
	r.Attrs(func(a slog.Attr) bool {
		flatten(attrs, "", nest(h.groups, a))
		return len(attrs) < maxAttrs
	})
	if len(attrs) > 0 {
		rec.Attrs = attrs
	}
	c.enqueue("log", rec)
	return err
}

// nest wraps a in the handler's open groups, outermost first, so flatten
// sees every group name as a key of its own and can filter it.
func nest(groups []string, a slog.Attr) slog.Attr {
	for i := len(groups) - 1; i >= 0; i-- {
		a = slog.Attr{Key: groups[i], Value: slog.GroupValue(a)}
	}
	return a
}

// flatten turns a into dotted keys. A secret-looking key, at any depth,
// keeps its place and its value (a whole group's, if it is one) is sent
// as Filtered, as the gem scrubs a payload before flattening it.
func flatten(into map[string]any, prefix string, a slog.Attr) {
	if len(into) >= maxAttrs {
		return
	}
	a.Value = a.Value.Resolve()
	key := a.Key
	if prefix != "" && key != "" {
		key = prefix + "." + key
	} else if key == "" {
		key = prefix
	}
	if a.Key != "" && FilteredKey(a.Key) {
		into[key] = Filtered
		return
	}
	switch a.Value.Kind() {
	case slog.KindGroup:
		// A group with no key is inlined into its parent, as slog does.
		for _, g := range a.Value.Group() {
			flatten(into, key, g)
		}
	case slog.KindString:
		into[key] = truncate(a.Value.String(), 1000)
	case slog.KindInt64:
		into[key] = a.Value.Int64()
	case slog.KindUint64:
		into[key] = a.Value.Uint64()
	case slog.KindFloat64:
		into[key] = a.Value.Float64()
	case slog.KindBool:
		into[key] = a.Value.Bool()
	case slog.KindDuration:
		into[key] = millis(a.Value.Duration())
	default:
		into[key] = scalar(a.Value.Any())
	}
}

func (h *logHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	cp := *h
	cp.next = h.next.WithAttrs(attrs)
	cp.attrs = append([]slog.Attr(nil), h.attrs...)
	for _, a := range attrs {
		cp.attrs = append(cp.attrs, nest(h.groups, a))
	}
	return &cp
}

func (h *logHandler) WithGroup(name string) slog.Handler {
	if name == "" {
		return h
	}
	cp := *h
	cp.next = h.next.WithGroup(name)
	cp.groups = append(append([]string(nil), h.groups...), name)
	return &cp
}

func levelName(l slog.Level) string {
	switch {
	case l >= slog.LevelError+4:
		return "fatal"
	case l >= slog.LevelError:
		return "error"
	case l >= slog.LevelWarn:
		return "warn"
	case l >= slog.LevelInfo:
		return "info"
	}
	return "debug"
}
