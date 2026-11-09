/* glass.js — browser analytics for Glass. Served and
 * relayed by the host app: nothing here talks to Glass, carries a key, or
 * reads anything a person typed. Plain ES2020, no dependencies, and every
 * entry point is wrapped so it can never throw into the page. */
(function () {
  'use strict';
  var w = window, d = document, n = navigator, loc = location;
  if (!w || !d || w.glass) return;
  var ds = (d.currentScript && d.currentScript.dataset) || {};
  function opt(k, def) { var v = ds[k]; return v == null || v === '' ? def : v; }
  function on(v) { return !/^(off|false|0|no)$/i.test(String(v)); }
  var endpoint = opt('endpoint', '/_glass/b');
  var autocapture = on(opt('autocapture', 'on'));
  var vitalsOn = on(opt('vitals', 'on'));
  var flushMs = +opt('flush', 5000) || 5000;
  var IDLE = 30 * 60 * 1000, MAX_QUEUE = 200, MAX_ERRORS = 10, PER_BEACON = 100;
  var ID = /^(\d+|[0-9a-f]{8,}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i;
  var TARGETS = 'button,a,[role=button],input[type=submit],input[type=button],summary,[data-glass]';

  function guard(f) { return function () { try { return f.apply(this, arguments); } catch (e) { } }; }
  function now() { return Date.now(); }
  function ss(k, v) {
    try { var s = w.sessionStorage; if (v === undefined) return s.getItem(k); s.setItem(k, v); } catch (e) { return null; }
  }
  function hex(bytes) {
    var a = new Uint8Array(bytes), s = '', i;
    if (w.crypto && w.crypto.getRandomValues) w.crypto.getRandomValues(a);
    else for (i = 0; i < bytes; i++) a[i] = Math.random() * 256;
    for (i = 0; i < bytes; i++) s += (a[i] & 255).toString(16).padStart(2, '0');
    return s;
  }

  /* ---- visit: one per tab, renewed after 30 minutes idle ---------------- */
  var visitId, lastSeen = 0;
  function newVisit() {
    visitId = 'v_' + hex(6);
    ss('glass_visit', visitId);
    ss('glass_first', '');
  }
  function touch() {
    var t = now();
    if (!visitId || t - lastSeen > IDLE) {
      var stored = ss('glass_visit'), seen = +ss('glass_seen') || 0;
      if (stored && /^v_[0-9a-f]{12}$/.test(stored) && t - seen <= IDLE) visitId = stored; else newVisit();
    }
    lastSeen = t;
    ss('glass_seen', String(t));
    return visitId;
  }

  /* ---- routes and selectors ---------------------------------------------- */
  function route(p) {
    return p.replace(/\/[^/]+/g, function (seg) { return ID.test(seg.slice(1)) ? '/:id' : seg; });
  }
  function pathOnly(u) { try { return new URL(u, loc.href).pathname; } catch (e) { return null; } }
  function sameOrigin(u) { try { return new URL(u, loc.href).origin === loc.origin; } catch (e) { return false; } }
  function firstClass(el) {
    var cs = (typeof el.className === 'string' ? el.className : '').split(/\s+/);
    for (var i = 0; i < cs.length; i++) if (cs[i] && !/[\d:\[\]\/]/.test(cs[i])) return cs[i];
    return '';
  }
  function selector(el) {
    var parts = [], node = el, depth = 0;
    while (node && node.nodeType === 1 && depth < 5 && node !== d.body && node !== d.documentElement) {
      var tag = node.tagName.toLowerCase(), c;
      if (node.id) { parts.unshift(tag + '#' + node.id); break; }
      c = firstClass(node);
      parts.unshift(c ? tag + '.' + c : tag);
      node = node.parentElement; depth++;
    }
    return parts.join(' > ');
  }
  function text(el) {
    var t = el.innerText || el.textContent || '';
    if (!t && /^(submit|button)$/i.test(el.type || '')) t = el.value || '';
    return t.replace(/\s+/g, ' ').trim().slice(0, 60);
  }
  function nameOf(el) {
    return el.getAttribute('data-glass') || el.getAttribute('aria-label') || text(el) || el.title || el.tagName.toLowerCase();
  }
  function describe(el) {
    var tag = el.tagName.toLowerCase(), href = null;
    if (tag === 'a' && el.href) href = sameOrigin(el.href) ? pathOnly(el.href) : null;
    return { tag: tag, role: el.getAttribute('role') || (tag === 'a' ? 'link' : tag === 'form' ? 'form' : 'button'), sel: selector(el), href: href };
  }

  /* ---- queue and transport ------------------------------------------------- */
  var queue = [];
  function push(ev) {
    ev.ts = now() / 1000;
    ev.visit = touch();
    if (ev.path == null) ev.path = loc.pathname;
    if (ev.route == null) ev.route = route(ev.path);
    queue.push(ev);
    if (queue.length > MAX_QUEUE) queue.shift();
  }
  function envelope(events) {
    return JSON.stringify({ visit: visitId, lang: n.language, screen: (w.screen ? w.screen.width + 'x' + w.screen.height : ''), events: events });
  }
  function send(body) {
    try { if (n.sendBeacon && n.sendBeacon(endpoint, body)) return; } catch (e) { }
    try { w.fetch(endpoint, { method: 'POST', body: body, keepalive: true, headers: { 'Content-Type': 'text/plain' } }).catch(function () {}); } catch (e) { }
  }
  function flush() {
    while (queue.length) send(envelope(queue.splice(0, PER_BEACON)));
  }

  /* ---- vitals: one record per pageview ------------------------------------ */
  var vitals = null, viewPath = null;
  function observe(type, opts, f) {
    try { var o = new w.PerformanceObserver(function (list) { try { f(list.getEntries()); } catch (e) { } }); o.observe(Object.assign({ type: type, buffered: true }, opts)); } catch (e) { }
  }
  if (vitalsOn && w.PerformanceObserver) {
    observe('largest-contentful-paint', {}, function (es) { var e = es[es.length - 1]; if (vitals && e) vitals.lcp = Math.round(e.startTime); });
    observe('paint', {}, function (es) { es.forEach(function (e) { if (vitals && e.name === 'first-contentful-paint') vitals.fcp = Math.round(e.startTime); }); });
    observe('layout-shift', {}, function (es) { es.forEach(function (e) { if (vitals && !e.hadRecentInput) vitals.cls = Math.round(((vitals.cls || 0) + e.value) * 10000) / 10000; }); });
    observe('event', { durationThreshold: 40 }, function (es) { es.forEach(function (e) { if (vitals && e.interactionId) vitals.inp = Math.max(vitals.inp || 0, Math.round(e.duration)); }); });
  }
  function finishVitals() {
    if (vitals && Object.keys(vitals).length) push({ kind: 'vital', path: viewPath, route: route(viewPath), vitals: vitals });
    vitals = null;
  }
  function startVitals(first) {
    vitals = vitalsOn ? {} : null;
    if (vitals && first) try { var nav = w.performance.getEntriesByType('navigation')[0]; if (nav && nav.responseStart) vitals.ttfb = Math.round(nav.responseStart); } catch (e) { }
  }

  /* ---- pageviews (load + SPA navigation) ----------------------------------- */
  var lastPath = null;
  function pageview() {
    var p = loc.pathname;
    if (p === lastPath) return;
    var first = lastPath === null;
    finishVitals();
    lastPath = viewPath = p;
    startVitals(first);
    setTimeout(guard(function () {
      var ev = { kind: 'pageview', path: p, route: route(p), title: (d.title || '').slice(0, 200) };
      touch();
      if (!ss('glass_first')) {
        ss('glass_first', '1');
        var r = d.referrer;
        if (r && !sameOrigin(r)) ev.ref = r.split('?')[0];
      }
      push(ev);
    }), 0);
  }
  ['pushState', 'replaceState'].forEach(function (m) {
    var orig = w.history[m];
    if (!orig) return;
    w.history[m] = function () { var r = orig.apply(this, arguments); guard(pageview)(); return r; };
  });
  w.addEventListener('popstate', guard(pageview));

  /* ---- autocapture --------------------------------------------------------- */
  var rage = { sel: null, times: [] };
  if (autocapture) {
    d.addEventListener('click', guard(function (e) {
      var t = e.target && e.target.closest ? e.target.closest(TARGETS) : null;
      if (!t) return;
      var el = describe(t), ev = { kind: 'click', name: nameOf(t).slice(0, 200), el: el }, ts = now();
      if (rage.sel !== el.sel) rage = { sel: el.sel, times: [] };
      rage.times = rage.times.filter(function (x) { return ts - x < 1000; });
      rage.times.push(ts);
      if (rage.times.length > 3) return;
      if (rage.times.length === 3) ev.props = { rage: true };
      push(ev);
    }), true);
    d.addEventListener('submit', guard(function (e) {
      var f = e.target; if (!f || f.tagName !== 'FORM') return;
      var sub = e.submitter, name = f.getAttribute('data-glass') || f.getAttribute('aria-label') || f.id || f.getAttribute('name') || (sub && nameOf(sub)) || 'form';
      push({ kind: 'submit', name: String(name).slice(0, 200), el: describe(f) });
    }), true);
  }

  /* ---- errors ---------------------------------------------------------------- */
  var errors = 0;
  function error(name, file, line) {
    if (errors++ >= MAX_ERRORS) return;
    var props = {};
    if (file) props.file = pathOnly(file) || String(file).split('?')[0].slice(0, 200);
    if (line) props.line = line;
    push({ kind: 'error', name: String(name || 'Error').slice(0, 80), props: props });
  }
  w.addEventListener('error', guard(function (e) {
    error((e.error && e.error.name) || (e.message || '').slice(0, 80), e.filename, e.lineno);
  }));
  w.addEventListener('unhandledrejection', guard(function (e) {
    var r = e.reason;
    error(r && r.name ? r.name : String(r == null ? 'unhandledrejection' : r).slice(0, 80));
  }));

  /* ---- same-origin requests carry the visit ---------------------------------- */
  var HEADER = 'X-Glass-Visit';
  if (w.fetch) {
    var fetch0 = w.fetch;
    w.fetch = function (input, init) {
      try {
        var url = typeof input === 'string' ? input : (input && input.url);
        if (url && sameOrigin(url)) {
          init = init || {};
          var h = init.headers || (input && input.headers && typeof input !== 'string' ? new Headers(input.headers) : undefined);
          if (!h) h = init.headers = {};
          if (typeof h.set === 'function') h.set(HEADER, touch());
          else if (Array.isArray(h)) h.push([HEADER, touch()]);
          else h[HEADER] = touch();
          init.headers = h;
        }
      } catch (e) { }
      return fetch0.call(this, input, init);
    };
  }
  if (w.XMLHttpRequest && w.XMLHttpRequest.prototype) {
    var xp = w.XMLHttpRequest.prototype, open0 = xp.open, send0 = xp.send;
    xp.open = function (method, url) { try { this.__glass = !!(url && sameOrigin(String(url))); } catch (e) { } return open0.apply(this, arguments); };
    xp.send = function () { try { if (this.__glass) this.setRequestHeader(HEADER, touch()); } catch (e) { } return send0.apply(this, arguments); };
  }

  /* ---- lifecycle -------------------------------------------------------------- */
  function hidden() { if (d.visibilityState === 'hidden') { finishVitals(); flush(); } }
  d.addEventListener('visibilitychange', guard(hidden));
  w.addEventListener('pagehide', guard(function () { finishVitals(); flush(); }));
  setInterval(guard(flush), flushMs);

  w.glass = {
    track: guard(function (name, props) {
      var p = {}, k, v, i = 0;
      for (k in (props || {})) {
        if (i++ >= 32) break;
        v = props[k];
        if (v == null || typeof v === 'object') continue;
        p[k] = typeof v === 'string' ? v.slice(0, 200) : v;
      }
      push({ kind: 'custom', name: String(name).slice(0, 200), props: p });
    }),
    flush: guard(flush),
    get visit() { return touch(); }
  };
  touch();
  guard(pageview)();
})();
