// node --test clients/browser/test — glass.js against a hand-rolled window.
// No jsdom: the script only needs a handful of DOM surfaces, and a fake
// that small is easier to reason about than a browser emulator.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const SRC = readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'glass.js'), 'utf8');

class Element {
  constructor(tag, attrs = {}, parent = null) {
    this.tagName = tag.toUpperCase();
    this.nodeType = 1;
    this.attrs = attrs;
    this.id = attrs.id || '';
    this.className = attrs.class || '';
    this.innerText = attrs.text || '';
    this.title = attrs.title || '';
    this.href = attrs.href || '';
    this.type = attrs.type || '';
    this.value = attrs.value || '';
    this.parentElement = parent;
  }
  getAttribute(name) { return this.attrs[name] == null ? null : this.attrs[name]; }
  matches(sel) {
    return sel.split(',').some((s) => {
      s = s.trim();
      if (s === '[data-glass]') return this.attrs['data-glass'] != null;
      if (s === '[role=button]') return this.attrs.role === 'button';
      const m = s.match(/^(\w+)(?:\[type=(\w+)\])?$/);
      return m && this.tagName === m[1].toUpperCase() && (!m[2] || this.type === m[2]);
    });
  }
  closest(sel) { let n = this; while (n) { if (n.matches(sel)) return n; n = n.parentElement; } return null; }
}

function makeWindow({ origin = 'https://app.example.net', pathname = '/wants/8c1f2a3b4d5e', referrer = '', storage = new Map(), dataset = {} } = {}) {
  const listeners = {};
  const sent = [];
  const fetches = [];
  const storageObj = { getItem: (k) => (storage.has(k) ? storage.get(k) : null), setItem: (k, v) => storage.set(k, String(v)) };
  const location = { origin, pathname, href: origin + pathname };
  const body = new Element('body');
  const win = {
    location,
    navigator: { language: 'en-US', sendBeacon: (url, data) => { sent.push({ url, data: JSON.parse(data) }); return true; } },
    screen: { width: 390, height: 844 },
    sessionStorage: storageObj,
    history: { pushState() {}, replaceState() {} },
    setTimeout: (f) => { f(); return 1; },
    setInterval: () => 1,
    addEventListener: (k, f) => { (listeners['w:' + k] ||= []).push(f); },
    fetch: (input, init) => { fetches.push({ input, init }); return Promise.resolve({}); },
    XMLHttpRequest: class { open() {} send() {} setRequestHeader(k, v) { this.headers = { [k]: v }; } },
    Headers: class { constructor(init) { this.map = new Map(Object.entries(init || {})); } set(k, v) { this.map.set(k, v); } get(k) { return this.map.get(k); } },
    URL,
    Uint8Array,
    Math, Date, JSON, Object, Array, String, Number, RegExp, Promise, Error,
    crypto: { getRandomValues: (a) => { for (let i = 0; i < a.length; i++) a[i] = Math.floor(Math.random() * 256); return a; } },
    performance: { getEntriesByType: () => [{ responseStart: 95.4 }] },
  };
  win.window = win;
  win.document = {
    title: 'Hook · Wants',
    referrer,
    body,
    documentElement: new Element('html'),
    visibilityState: 'visible',
    currentScript: { dataset },
    addEventListener: (k, f) => { (listeners['d:' + k] ||= []).push(f); },
  };
  vm.createContext(win);
  vm.runInContext(SRC, win);
  return {
    win, sent, fetches, storage, body,
    fire: (scope, name, event) => (listeners[scope + ':' + name] || []).forEach((f) => f(event)),
    events: () => sent.flatMap((b) => b.data.events),
  };
}

test('a visit id is created, reused within 30 minutes, and renewed after idling', () => {
  const storage = new Map();
  const a = makeWindow({ storage });
  const id = a.win.glass.visit;
  assert.match(id, /^v_[0-9a-f]{12}$/);
  assert.equal(storage.get('glass_visit'), id);
  const b = makeWindow({ storage });
  assert.equal(b.win.glass.visit, id, 'same tab, same visit');
  storage.set('glass_seen', String(Date.now() - 31 * 60 * 1000));
  const c = makeWindow({ storage });
  assert.notEqual(c.win.glass.visit, id, 'idle past 30 minutes starts a new visit');
  const d = makeWindow({ storage: new Map() });
  assert.notEqual(d.win.glass.visit, id, 'a new tab is a new visit');
});

test('the first pageview carries route, title and a cross-origin referrer only once', () => {
  const storage = new Map();
  const a = makeWindow({ storage, referrer: 'https://portal.example.net/today?x=1' });
  a.win.glass.flush();
  const [pv] = a.events();
  assert.equal(pv.kind, 'pageview');
  assert.equal(pv.path, '/wants/8c1f2a3b4d5e');
  assert.equal(pv.route, '/wants/:id');
  assert.equal(pv.title, 'Hook · Wants');
  assert.equal(pv.ref, 'https://portal.example.net/today');
  assert.equal(typeof pv.ts, 'number');
  const b = makeWindow({ storage, referrer: 'https://portal.example.net/today', pathname: '/wants' });
  b.win.glass.flush();
  assert.equal(b.events()[0].ref, undefined, 'only the visit\'s first pageview has a referrer');
  const c = makeWindow({ storage: new Map(), referrer: 'https://app.example.net/other' });
  c.win.glass.flush();
  assert.equal(c.events()[0].ref, undefined, 'a same-origin referrer is dropped');
});

test('route templating collapses ids, uuids and hex', () => {
  const w = makeWindow({ pathname: '/api/v1/apps/2a4f6aa0-52c6-4493-b77a-1d9b2c51f978/wants/42/tag/deadbeef99/x' });
  w.win.glass.flush();
  assert.equal(w.events()[0].route, '/api/v1/apps/:id/wants/:id/tag/:id/x');
});

test('SPA navigation emits a pageview per path change, deduped, with a vital for the previous view', () => {
  const w = makeWindow({ pathname: '/wants' });
  w.win.location.pathname = '/wants/7';
  w.win.history.pushState({}, '', '/wants/7');
  w.win.history.replaceState({}, '', '/wants/7');
  w.fire('w', 'popstate', {});
  w.win.glass.flush();
  const kinds = w.events().map((e) => [e.kind, e.path]);
  assert.deepEqual(kinds, [['pageview', '/wants'], ['vital', '/wants'], ['pageview', '/wants/7']]);
  const vital = w.events()[1];
  assert.deepEqual(vital.vitals, { ttfb: 95 });
  assert.equal(vital.route, '/wants');
});

test('autocapture names and describes clicks, never values, and folds rage clicks', () => {
  const w = makeWindow();
  const form = new Element('form', { id: 'add-want', class: 'p-4 flex' }, w.body);
  const div = new Element('div', { class: 'md:flex actions' }, form);
  const button = new Element('button', { class: 'primary', text: '  Add   want  ' }, div);
  const span = new Element('span', {}, button);
  const input = new Element('input', { type: 'text', value: 'secret typed text' }, form);
  w.fire('d', 'click', { target: span });
  w.fire('d', 'click', { target: input });
  w.win.glass.flush();
  const clicks = w.events().filter((e) => e.kind === 'click');
  assert.equal(clicks.length, 1, 'clicks on plain inputs are not captured');
  assert.equal(clicks[0].name, 'Add want');
  assert.deepEqual(clicks[0].el, { tag: 'button', role: 'button', sel: 'form#add-want > div.actions > button.primary', href: null });
  assert.equal(JSON.stringify(clicks[0]).includes('secret'), false);
  // rage: the span click above was the first on this selector; two more
  // within a second make three → the third is flagged, the rest dropped
  for (let i = 0; i < 4; i++) w.fire('d', 'click', { target: button });
  w.win.glass.flush();
  const burst = w.events().filter((e) => e.kind === 'click');
  assert.equal(burst.length, 3);
  assert.deepEqual(burst.map((e) => e.props), [undefined, undefined, { rage: true }]);
});

test('links keep a same-origin pathname only, submits name the form', () => {
  const w = makeWindow();
  const a = new Element('a', { href: 'https://app.example.net/wants?q=1', 'aria-label': 'All wants' }, w.body);
  const ext = new Element('a', { href: 'https://example.com/x', text: 'Out' }, w.body);
  const form = new Element('form', { name: 'search' }, w.body);
  const submit = new Element('input', { type: 'submit', value: 'Go' }, form);
  w.fire('d', 'click', { target: a });
  w.fire('d', 'click', { target: ext });
  w.fire('d', 'click', { target: submit });
  w.fire('d', 'submit', { target: form, submitter: submit });
  w.win.glass.flush();
  const ev = w.events().filter((e) => e.kind !== 'pageview');
  assert.deepEqual(ev.map((e) => [e.kind, e.name, e.el.href]), [
    ['click', 'All wants', '/wants'], ['click', 'Out', null], ['click', 'Go', null], ['submit', 'search', null],
  ]);
  assert.equal(ev[3].el.tag, 'form');
});

test('the visit header goes on same-origin fetch and XHR only', () => {
  const w = makeWindow();
  const id = w.win.glass.visit;
  w.win.fetch('/api/v1/wants');
  w.win.fetch('https://app.example.net/api/v1/wants', { headers: { Accept: 'application/json' } });
  w.win.fetch('https://api.github.com/x', { headers: { Accept: 'application/json' } });
  w.win.fetch('/x', { headers: new w.win.Headers({ A: '1' }) });
  const [rel, abs, cross, hdrs] = w.fetches;
  assert.equal(rel.init.headers['X-Glass-Visit'], id);
  assert.equal(abs.init.headers['X-Glass-Visit'], id);
  assert.equal(abs.init.headers.Accept, 'application/json');
  assert.equal(cross.init.headers['X-Glass-Visit'], undefined, 'never on a cross-origin request');
  assert.equal(hdrs.init.headers.get('X-Glass-Visit'), id);
  const xhr = new w.win.XMLHttpRequest();
  xhr.open('GET', '/api/v1/apps'); xhr.send();
  assert.deepEqual(xhr.headers, { 'X-Glass-Visit': id });
  const xhr2 = new w.win.XMLHttpRequest();
  xhr2.open('GET', 'https://example.com/'); xhr2.send();
  assert.equal(xhr2.headers, undefined);
});

test('events batch per beacon, flush on hide, and the queue is bounded', () => {
  const w = makeWindow();
  for (let i = 0; i < 250; i++) w.win.glass.track('tick', { i, note: 'x'.repeat(300), nested: { no: 1 } });
  assert.equal(w.sent.length, 0, 'nothing sent before a flush');
  w.win.document.visibilityState = 'hidden';
  w.fire('d', 'visibilitychange', {});
  assert.deepEqual(w.sent.map((b) => b.data.events.length), [100, 100]);
  assert.equal(w.sent[0].url, '/_glass/b');
  assert.equal(w.sent[0].data.visit, w.win.glass.visit);
  assert.equal(w.sent[0].data.lang, 'en-US');
  assert.equal(w.sent[0].data.screen, '390x844');
  const custom = w.events().find((e) => e.kind === 'custom');
  assert.equal(custom.props.note.length, 200);
  assert.equal(custom.props.nested, undefined, 'scalar props only');
  w.fire('d', 'visibilitychange', {});
  assert.equal(w.sent.length, 2, 'an empty flush sends nothing');
});

test('errors are recorded with path-only file names and rate-limited', () => {
  const w = makeWindow();
  for (let i = 0; i < 12; i++) w.fire('w', 'error', { error: new TypeError('x'), filename: 'https://app.example.net/assets/app.js?v=1', lineno: 12 });
  w.fire('w', 'unhandledrejection', { reason: 'nope' });
  w.win.glass.flush();
  const errs = w.events().filter((e) => e.kind === 'error');
  assert.equal(errs.length, 10);
  assert.deepEqual(errs[0].props, { file: '/assets/app.js', line: 12 });
  assert.equal(errs[0].name, 'TypeError');
});

test('data attributes turn autocapture and vitals off and set the endpoint', () => {
  const w = makeWindow({ dataset: { endpoint: '/beacons', autocapture: 'off', vitals: 'off' } });
  w.fire('d', 'click', { target: new Element('button', { text: 'x' }, w.body) });
  w.win.document.visibilityState = 'hidden';
  w.fire('d', 'visibilitychange', {});
  assert.equal(w.sent[0].url, '/beacons');
  assert.deepEqual(w.events().map((e) => e.kind), ['pageview']);
});

test('the script never throws into the page', () => {
  const w = makeWindow();
  w.fire('d', 'click', { target: null });
  w.fire('d', 'submit', { target: { tagName: 'DIV' } });
  w.win.glass.track(undefined, null);
  w.win.fetch(42);
  assert.ok(true);
});
