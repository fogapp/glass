package glass

import (
	"bufio"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"strings"
)

// Middleware is c.Middleware on the default client, whichever client that
// is when a request arrives: the handler can be built before SetDefault.
func Middleware(next http.Handler) http.Handler { return middleware(next, Default) }

// Middleware makes each request a transaction of c's, named for the route
// pattern that served it ("GET /api/apps/{name}"), continuing the caller's
// traceparent. It goes directly around the ServeMux, which writes Pattern
// on the request it is handed. Upgrades, hijacked connections and responses
// that flush (the log streams) are not reported: how long one stays open is
// how long someone watched, not how slow fog was.
func (c *Client) Middleware(next http.Handler) http.Handler {
	return middleware(next, func() *Client { return c })
}

func middleware(next http.Handler, client func() *Client) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c := client()
		if !c.active() || r.Header.Get("Upgrade") != "" {
			next.ServeHTTP(w, r)
			return
		}
		ctx, t := c.Start(WithTraceparent(r.Context(), r.Header.Get("traceparent")), "request", "")
		t.setOrigin(requestOrigin(r))
		r = r.WithContext(ctx)
		rec := &recorder{ResponseWriter: w, status: http.StatusOK}
		returned := false
		defer func() {
			if rec.streamed {
				t.Discard()
				return
			}
			status := rec.status
			if !returned {
				// A panic on its way to the recovery above us, which answers 500.
				status = http.StatusInternalServerError
				t.Fail("panic")
			} else if status >= 500 {
				t.Fail(fmt.Sprintf("http %d", status))
			}
			name, route := routeName(r.Pattern, status)
			t.SetName(name)
			t.HTTP(r.Method, route, r.URL.Path, status)
			t.End(nil)
		}()
		next.ServeHTTP(rec, r)
		returned = true
	})
}

// routeName is a request's name and route template from the pattern the
// mux matched. The catch-all "/" is the bundled UI.
func routeName(pattern string, status int) (name, route string) {
	route = pattern
	if _, path, ok := strings.Cut(pattern, " "); ok {
		route = path
	}
	switch {
	case pattern == "" && status == http.StatusNotFound:
		return "(404)", ""
	case pattern == "":
		return "(unrouted)", ""
	case route == "/":
		return "(static)", route
	}
	return pattern, route
}

type recorder struct {
	http.ResponseWriter
	status   int
	wrote    bool
	streamed bool
}

func (r *recorder) WriteHeader(code int) {
	if !r.wrote {
		r.status, r.wrote = code, true
	}
	r.ResponseWriter.WriteHeader(code)
}

func (r *recorder) Write(b []byte) (int, error) {
	r.wrote = true
	return r.ResponseWriter.Write(b)
}

// Unwrap lets http.ResponseController reach the underlying writer.
func (r *recorder) Unwrap() http.ResponseWriter { return r.ResponseWriter }

// Flush and Hijack are forwarded explicitly, as fog's own recorder does:
// the log stream type-asserts http.Flusher and the terminal http.Hijacker.
func (r *recorder) Flush() {
	r.streamed = true
	if f, ok := r.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (r *recorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	hj, ok := r.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, fmt.Errorf("connection does not support hijacking")
	}
	r.streamed = true
	return hj.Hijack()
}

// Transport makes each outbound call made inside a transaction an http
// span, and counts it toward the transaction's ext_ms. It passes
// traceparent only to hosts that are ours (see ours) — the apps on this box,
// its LAN and its VPN — never to the public internet.
type Transport struct {
	Base http.RoundTripper
	// PropagateTo names host suffixes that are ours beyond private and VPN
	// addresses, bare hostnames and InternalSuffixes: "example.net" lets
	// app.example.net continue the trace.
	PropagateTo []string
}

func (t Transport) RoundTrip(req *http.Request) (*http.Response, error) {
	base := t.Base
	if base == nil {
		base = http.DefaultTransport
	}
	host := req.URL.Hostname()
	ctx, sp := StartSpan(req.Context(), "http", req.Method+" "+host, req.Method+" "+host+req.URL.Path)
	if sp == nil {
		return base.RoundTrip(req)
	}
	if ours(host, t.PropagateTo) {
		req = req.Clone(ctx)
		req.Header.Set("traceparent", Traceparent(ctx))
	}
	resp, err := base.RoundTrip(req)
	switch {
	case err != nil:
		sp.End(err)
	default:
		sp.Attr("status", resp.StatusCode)
		if resp.StatusCode >= 500 {
			sp.End(fmt.Errorf("http %d", resp.StatusCode))
		} else {
			sp.End(nil)
		}
	}
	return resp, err
}

// InternalSuffixes are names that only resolve inside a home network: a
// router's .lan, mDNS's .local, ICANN's private-use .internal.
var InternalSuffixes = []string{"lan", "local", "internal"}

// ours reports whether host is one of ours. An address is ours when the
// origin rule does not call it public (private, CGNAT); a name is ours when
// it is bare (a container network's names) or is or ends in one of
// InternalSuffixes or suffixes. Every client's rule: the conformance kit's
// origin.json holds them to it.
func ours(host string, suffixes []string) bool {
	name := strings.ToLower(strings.TrimSuffix(strings.TrimPrefix(host, "["), "]"))
	if name == "" {
		return false
	}
	if kind := addressKind(name); kind != "" {
		return kind != "public"
	}
	if !strings.Contains(name, ".") {
		return true
	}
	for _, list := range [][]string{InternalSuffixes, suffixes} {
		for _, suffix := range list {
			want := strings.ToLower(strings.TrimPrefix(suffix, "."))
			if want != "" && (name == want || strings.HasSuffix(name, "."+want)) {
				return true
			}
		}
	}
	return false
}

// cgnat is 100.64.0.0/10, the range Tailscale and every home VPN hands out:
// a sibling over it is ours, and a visitor from it is on the VPN.
var cgnat = netip.MustParsePrefix("100.64.0.0/10")

// addressKind is what an address is to us: "private" (loopback, RFC 1918,
// link-local, a ULA), "vpn" (CGNAT) or "public"; "" when it is not an
// address at all, which decides nothing. The gem's and the Node client's
// rule.
func addressKind(address string) string {
	name := strings.TrimSuffix(strings.TrimPrefix(strings.TrimSpace(address), "["), "]")
	addr, err := netip.ParseAddr(name)
	if err != nil {
		return ""
	}
	addr = addr.Unmap()
	switch {
	case addr.Is4() && cgnat.Contains(addr):
		return "vpn"
	case addr.IsLoopback() || addr.IsPrivate() || addr.IsLinkLocalUnicast():
		return "private"
	}
	return "public"
}

// originOf is where a request came from, as a network class (lan, vpn,
// tunnel or public), and the address that decided it. Behind Cloudflare
// (CF-Connecting-IP, or a bare CF-Ray) it is a tunnel. Otherwise the chain
// is X-Forwarded-For then the socket's peer, walked from the nearest hop
// outwards: the first address that is not private decides, so a client on
// the public internet cannot claim the LAN with its own X-Forwarded-For. A
// chain private all the way out is the LAN, decided by its outermost hop.
// The conformance kit's origin.json holds every client to it.
func originOf(remote, forwarded string, cfConnectingIP *string, cfRay bool) (origin, address string) {
	if cfConnectingIP != nil {
		return "tunnel", strings.TrimSpace(*cfConnectingIP)
	}
	var chain []string
	if forwarded != "" {
		for _, hop := range strings.Split(forwarded, ",") {
			if hop = strings.TrimSpace(hop); hop != "" {
				chain = append(chain, hop)
			}
		}
	}
	if remote = strings.TrimSpace(remote); remote != "" {
		chain = append(chain, remote)
	}
	if cfRay {
		if len(chain) == 0 {
			return "tunnel", ""
		}
		return "tunnel", chain[0]
	}
	if len(chain) == 0 {
		return "", ""
	}
	for i := len(chain) - 1; i >= 0; i-- {
		if kind := addressKind(chain[i]); kind == "vpn" || kind == "public" {
			return kind, chain[i]
		}
	}
	return "lan", chain[0]
}

// requestOrigin is originOf for a request as net/http hands it over.
func requestOrigin(r *http.Request) string {
	remote := r.RemoteAddr
	if host, _, err := net.SplitHostPort(remote); err == nil {
		remote = host
	}
	var cf *string
	if v := r.Header.Values("Cf-Connecting-Ip"); len(v) > 0 {
		joined := strings.Join(v, ",")
		cf = &joined
	}
	origin, _ := originOf(remote, strings.Join(r.Header.Values("X-Forwarded-For"), ","), cf, len(r.Header.Values("Cf-Ray")) > 0)
	return origin
}
