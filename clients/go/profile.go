package glass

import (
	"bytes"
	"context"
	"path"
	"path/filepath"
	"reflect"
	"runtime"
	"runtime/debug"
	"runtime/pprof"
	"strconv"
	"strings"
	"time"

	"github.com/google/pprof/profile"
)

const (
	profileWindow = 60 * time.Second
	// Go's CPU profiler samples at 100 Hz; setting another rate before
	// StartCPUProfile is not supported, so profile_hz is not honoured.
	profileHz = 100
)

// maxHandled is how many profile_now ids are remembered as done, the
// oldest forgotten first: enough that a request still in Glass's replies
// is not run twice, never a set that grows for the life of the process.
const maxHandled = 50

// txnLabel is the pprof label a profile credits samples to.
const txnLabel = "glass.txn"

// profile samples the CPU in back-to-back minutes while Glass's profiling
// setting is on, and for as long as the console asks when it asks for a
// profile now (profile_now). Each window is folded into one record.
func (c *Client) profile(ctx context.Context) {
	done := map[string]bool{}
	var order []string
	for {
		profiling, now := c.profileDirectives()
		var req *profileNow
		if now != nil && now.ID != "" && !done[now.ID] {
			req, done[now.ID] = now, true
			order = append(order, now.ID)
			if len(order) > maxHandled {
				delete(done, order[0])
				order = order[1:]
			}
		}
		span := profileWindow
		switch {
		case !c.active() || (req == nil && !profiling):
			select {
			case <-ctx.Done():
				return
			case <-time.After(window * time.Second):
			}
			continue
		case req != nil:
			span = time.Duration(min(max(req.Seconds, 1), 300)) * time.Second
		}
		// A continuous window gives way to a request from the console, and
		// ends when profiling is turned off.
		stop := func() bool {
			profiling, now := c.profileDirectives()
			asked := now != nil && now.ID != "" && !done[now.ID]
			return req == nil && (asked || !profiling || !c.active())
		}
		rec := cpuWindow(ctx, span, stop)
		if ctx.Err() != nil {
			return
		}
		if rec == nil {
			// Someone else is profiling (a test, a debugger): try later.
			select {
			case <-ctx.Done():
				return
			case <-time.After(window * time.Second):
			}
			continue
		}
		if req != nil {
			rec["request"] = req.ID
		}
		c.enqueue("profile", rec)
	}
}

// cpuWindow profiles the CPU for span, or until ctx ends or stop says to
// (it is asked every second), and folds what it saw. Nil when the profiler
// is in use or nothing ran.
func cpuWindow(ctx context.Context, span time.Duration, stop func() bool) map[string]any {
	var buf bytes.Buffer
	if pprof.StartCPUProfile(&buf) != nil {
		return nil
	}
	start := time.Now()
	end := time.After(span)
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
wait:
	for {
		select {
		case <-ctx.Done():
			break wait
		case <-end:
			break wait
		case <-tick.C:
			if stop() {
				break wait
			}
		}
	}
	pprof.StopCPUProfile()
	p, err := profile.Parse(&buf)
	if err != nil {
		return nil
	}
	return fold(p, start, time.Since(start))
}

// fold turns a pprof profile into a profile record: functions and stacks
// by index, root first, and samples by stack and the transaction whose
// label the goroutine wore.
func fold(p *profile.Profile, start time.Time, dur time.Duration) map[string]any {
	var funcs [][]any
	fidx := map[string]int{}
	var stacks [][]int
	sidx := map[string]int{}
	type key struct {
		stack int
		txn   string
		state string
	}
	weights := map[key]int64{}
	var order []key

	for _, smp := range p.Sample {
		if len(smp.Value) == 0 || smp.Value[0] == 0 {
			continue
		}
		var leafFirst []int
		state := "running"
		for _, loc := range smp.Location {
			for _, ln := range loc.Line {
				if ln.Function == nil {
					continue
				}
				name := ln.Function.Name
				if gcWork(name) {
					state = "gc"
				}
				k := name + "\x00" + ln.Function.Filename
				i, ok := fidx[k]
				if !ok {
					file, cat := place(name, ln.Function.Filename)
					i = len(funcs)
					fidx[k] = i
					funcs = append(funcs, []any{name, file, ln.Function.StartLine, cat})
				}
				leafFirst = append(leafFirst, i)
			}
		}
		if len(leafFirst) == 0 {
			continue
		}
		stack := make([]int, len(leafFirst))
		var sk strings.Builder
		for j, i := range leafFirst {
			stack[len(leafFirst)-1-j] = i
		}
		for _, i := range stack {
			sk.WriteString(strconv.Itoa(i) + ",")
		}
		si, ok := sidx[sk.String()]
		if !ok {
			si = len(stacks)
			sidx[sk.String()] = si
			stacks = append(stacks, stack)
		}
		var txn string
		if l := smp.Label[txnLabel]; len(l) > 0 {
			txn = l[0]
		}
		k := key{si, txn, state}
		if _, seen := weights[k]; !seen {
			order = append(order, k)
		}
		weights[k] += smp.Value[0]
	}
	if len(order) == 0 {
		return nil
	}
	samples := make([][]any, 0, len(order))
	for _, k := range order {
		var txn any
		if k.txn != "" {
			txn = k.txn
		}
		samples = append(samples, []any{k.stack, txn, k.state, weights[k]})
	}
	return map[string]any{"t": "profile", "ts": unixSeconds(start), "dur": dur.Seconds(), "hz": profileHz, "mode": "cpu",
		"funcs": funcs, "stacks": stacks, "samples": samples}
}

// dependency reports whether fn is in a module other than Go's own: its
// import path begins with a domain (github.com/…), where the standard
// library's never does (net/http.…, runtime.…).
func dependency(fn string) bool {
	first, _, nested := strings.Cut(fn, "/")
	return nested && strings.Contains(first, ".")
}

func gcWork(fn string) bool {
	return strings.HasPrefix(fn, "runtime.gcBgMarkWorker") || strings.HasPrefix(fn, "runtime.bgsweep") ||
		strings.HasPrefix(fn, "runtime.bgscavenge") || strings.HasPrefix(fn, "runtime.gcDrain")
}

var module = func() string {
	if bi, ok := debug.ReadBuildInfo(); ok && bi.Main.Path != "" {
		return bi.Main.Path
	}
	return "main"
}()

// goroot is where the standard library's files were when this binary was
// built, read from the runtime's own code (runtime.GOROOT is deprecated):
// "" in a -trimpath build, whose paths have no root.
var goroot = func() string {
	f := runtime.FuncForPC(reflect.ValueOf(runtime.Gosched).Pointer())
	if f == nil {
		return ""
	}
	file, _ := f.FileLine(f.Entry())
	file = filepath.ToSlash(file)
	if i := strings.LastIndex(file, "/src/runtime/"); i >= 0 {
		return file[:i+len("/src/")]
	}
	return ""
}()

// place is where a function's code is, never as an absolute path, and whose
// it is: the program's (app), a dependency's (gem, as the protocol calls one), or
// Go's own runtime and standard library (native).
func place(fn, file string) (string, string) {
	file = filepath.ToSlash(file)
	switch {
	case strings.HasPrefix(fn, module+"/") || strings.HasPrefix(fn, "main."):
		if i := strings.Index(file, module+"/"); i >= 0 {
			return file[i+len(module)+1:], "app"
		}
		return path.Base(file), "app"
	case dependency(fn):
		// A dependency: its module path and the file in it, without the
		// version and without the module cache it was built from.
		if i := strings.Index(file, "/pkg/mod/"); i >= 0 {
			file = file[i+len("/pkg/mod/"):]
		}
		if at := strings.Index(file, "@"); at >= 0 {
			if slash := strings.Index(file[at:], "/"); slash >= 0 {
				file = file[:at] + file[at+slash:]
			}
		}
		return file, "gem"
	}
	if goroot != "" && strings.HasPrefix(file, goroot) {
		file = strings.TrimPrefix(file, goroot)
	} else if i := strings.Index(file, "/src/"); i >= 0 && strings.HasPrefix(file, "/") {
		file = file[i+len("/src/"):]
	}
	return file, "native"
}
