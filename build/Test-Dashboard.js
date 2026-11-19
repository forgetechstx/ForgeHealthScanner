// Run with: node build/Test-Dashboard.js
// Executes the dashboard's own inline JavaScript against an isolated, minimal DOM.
// These are behavior regressions; layout and real browser integration need visual QA.
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
const scripts = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)]
  .filter(match => !/\bsrc\s*=/.test(match[1])).map(match => match[2]).join('\n');
const START = Date.parse('2026-11-10T18:00:00Z');
const payload = '<img src=x onerror="globalThis.reportPayloadExecuted=true">';

class EventTarget {
  constructor() { this.listeners = new Map(); }
  addEventListener(type, fn) {
    if (!this.listeners.has(type)) this.listeners.set(type, []);
    this.listeners.get(type).push(fn);
  }
  dispatchEvent(event) {
    if (!event.target) event.target = this;
    event.preventDefault ||= () => {};
    event.stopPropagation ||= () => {};
    if (typeof this['on' + event.type] === 'function') this['on' + event.type](event);
    for (const fn of this.listeners.get(event.type) || []) fn.call(this, event);
    return true;
  }
}

class Element extends EventTarget {
  constructor(tagName = 'div', audit) {
    super();
    this.tagName = tagName.toUpperCase();
    this.children = [];
    this.parentElement = null;
    this.attributes = {};
    this.dataset = {};
    this.style = { setProperty(key, value) { this[key] = value; } };
    this.value = '';
    this.disabled = false;
    this.hidden = false;
    this.open = false;
    this.audit = audit;
    this.classList = {
      contains: name => this.className.split(/\s+/).includes(name),
      add: (...names) => { this.className = [...new Set([...this.className.split(/\s+/).filter(Boolean), ...names])].join(' '); },
      remove: (...names) => { this.className = this.className.split(/\s+/).filter(name => !names.includes(name)).join(' '); },
      toggle: (name, force) => {
        const enabled = force === undefined ? !this.classList.contains(name) : !!force;
        this.classList[enabled ? 'add' : 'remove'](name);
        return enabled;
      }
    };
  }
  get className() { return this.attributes.class || ''; }
  set className(value) { this.attributes.class = String(value); }
  get id() { return this.attributes.id || ''; }
  set id(value) { this.attributes.id = String(value); }
  get textContent() { return this._text || this.children.map(child => child.textContent).join(''); }
  set textContent(value) { this._text = value == null ? '' : String(value); this.children = []; }
  set innerHTML(value) {
    this.audit.htmlWrites.push(String(value));
    this.replaceChildren();
    parseFragment(String(value), this, this.audit);
  }
  get innerHTML() { return this.textContent; }
  append(...nodes) {
    if (this._text) { this.children.push({ textContent: this._text }); this._text = ''; }
    for (const node of nodes) {
      const child = typeof node === 'string' ? { textContent: node } : node;
      if (!child) continue;
      child.parentElement = this;
      this.children.push(child);
    }
  }
  appendChild(node) { this.append(node); return node; }
  replaceChildren(...nodes) { this._text = ''; this.children = []; this.append(...nodes); }
  setAttribute(name, value) {
    this.attributes[name] = String(value);
    if (name.startsWith('data-')) this.dataset[name.slice(5).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase())] = String(value);
    if (name === 'value') this.value = String(value);
    if (name === 'disabled') this.disabled = true;
  }
  getAttribute(name) { return this.attributes[name] ?? null; }
  removeAttribute(name) { delete this.attributes[name]; }
  querySelectorAll(selector) {
    const found = [];
    const visit = node => {
      for (const child of node.children || []) {
        if (child instanceof Element) {
          if (matches(child, selector)) found.push(child);
          visit(child);
        }
      }
    };
    visit(this);
    return found;
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  closest(selector) { for (let node = this; node; node = node.parentElement) if (matches(node, selector)) return node; return null; }
  click() { this.dispatchEvent({ type: 'click', target: this }); }
  focus(options) { this.focused = true; this.focusOptions = options; this.audit.activeElement = this; }
  contains(node) { for (let current = node; current; current = current.parentElement) if (current === this) return true; return false; }
  scrollIntoView(options) { this.audit.scrolls.push({ element: this, options }); }
  showModal() { this.open = true; }
  close() { this.open = false; }
  remove() {
    if (this.parentElement) this.parentElement.children = this.parentElement.children.filter(node => node !== this);
    this.parentElement = null;
  }
}

function matches(node, selector) {
  return selector.split(',').some(part => {
    let candidate = node;
    const selectors = part.trim().split(/\s+/);
    const simple = (element, token) => {
      if (!(element instanceof Element)) return false;
      const tag = /^[a-z][\w-]*/i.exec(token);
      if (tag && element.tagName !== tag[0].toUpperCase()) return false;
      for (const id of token.matchAll(/#([\w-]+)/g)) if (element.id !== id[1]) return false;
      for (const cls of token.matchAll(/\.([\w-]+)/g)) if (!element.classList.contains(cls[1])) return false;
      for (const attr of token.matchAll(/\[([^\]=]+)(?:=["']?([^\]"']*)["']?)?\]/g)) {
        if (element.getAttribute(attr[1]) === null) return false;
        if (attr[2] !== undefined && element.getAttribute(attr[1]) !== attr[2]) return false;
      }
      return true;
    };
    if (!simple(candidate, selectors.pop())) return false;
    for (let i = selectors.length - 1; i >= 0; i--) {
      candidate = candidate.parentElement;
      while (candidate && !simple(candidate, selectors[i])) candidate = candidate.parentElement;
      if (!candidate) return false;
    }
    return true;
  });
}

function parseFragment(markup, root, audit) {
  const stack = [root];
  const voidTags = new Set(['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr']);
  const stripped = markup.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi, '').replace(/<!--[\s\S]*?-->/g, '');
  for (const match of stripped.matchAll(/<\/([\w-]+)\s*>|<([\w-]+)\b([^>]*)>|([^<]+)/g)) {
    if (match[1]) {
      const at = stack.map(node => node.tagName.toLowerCase()).lastIndexOf(match[1].toLowerCase());
      if (at > 0) stack.length = at;
    } else if (match[2]) {
      const element = new Element(match[2], audit);
      for (const attr of match[3].matchAll(/([^\s=/>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g)) {
        element.setAttribute(attr[1], attr[2] ?? attr[3] ?? attr[4] ?? '');
      }
      stack[stack.length - 1].append(element);
      if (!voidTags.has(match[2].toLowerCase()) && !/\/\s*$/.test(match[3])) stack.push(element);
    } else if (match[4]) stack[stack.length - 1].append({ textContent: match[4] });
  }
}

function dashboard(globals = {}, setup = {}) {
  const audit = { htmlWrites: [], scrolls: [], confirms: [], activeElement: null };
  const document = new Element('document', audit);
  const markup = setup.markup || html;
  parseFragment(markup, document, audit);
  if (setup.beforeRun) setup.beforeRun(document, audit);
  Object.defineProperty(document, 'activeElement', { get: () => audit.activeElement || document.body });
  document.getElementById = id => document.querySelector('#' + id);
  document.createElement = tag => new Element(tag, audit);
  document.createElementNS = (_, tag) => new Element(tag, audit);
  document.createTextNode = value => ({ textContent: String(value) });
  document.createDocumentFragment = () => new Element('fragment', audit);
  document.body = document.querySelector('body');
  document.documentElement = document.querySelector('html');
  document.visibilityState = 'visible';
  let now = START;
  class Clock extends Date {
    constructor(...args) { super(...(args.length ? args : [now])); }
    static now() { return now; }
  }
  let timerId = 0;
  const timers = new Map();
  const schedule = (callback, delay, repeat) => {
    timers.set(++timerId, { callback, delay, repeat, at: now + Number(delay || 0) });
    return timerId;
  };
  const context = vm.createContext({
    console, document, Date: Clock, TextDecoder, TextEncoder, Blob,
    URL: { createObjectURL: () => 'blob:test', revokeObjectURL() {} },
    location: { hash: '', pathname: '/index.html', search: '' },
    history: { replaceState() {} },
    navigator: {},
    atob: text => Buffer.from(text, 'base64').toString('binary'),
    setTimeout: (fn, delay) => schedule(fn, delay, false),
    clearTimeout: id => timers.delete(id),
    setInterval: (fn, delay) => schedule(fn, delay, true),
    clearInterval: id => timers.delete(id),
    ...globals,
    confirm: message => { audit.confirms.push(message); return globals.confirm ? globals.confirm(message) : true; }
  });
  context.window = context;
  context.addEventListener = document.addEventListener.bind(document);
  if (!globals.matchMedia) context.matchMedia = () => ({ matches: false, addEventListener() {} });
  const pageScripts = setup.markup
    ? [...markup.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)]
      .filter(match => !/\bsrc\s*=/.test(match[1])).map(match => match[2]).join('\n')
    : scripts;
  vm.runInContext(pageScripts, context, { filename: 'index.html inline JavaScript' });
  return {
    context, document, audit, timers,
    get: id => { const element = document.getElementById(id); assert.ok(element, 'Missing dashboard element #' + id); return element; },
    run: code => vm.runInContext(code, context),
    load: (report, origin) => { context.testReport = report; context.testOrigin = origin; vm.runInContext('load(testReport, testOrigin)', context); },
    loadBaseline: report => { context.testBaseline = report; return vm.runInContext('loadBaseline(testBaseline)', context); },
    compare: (current, previous) => { context.testCurrent = current; context.testPrevious = previous; return vm.runInContext('compareReports(testCurrent, testPrevious)', context); },
    trigger: async (id, type) => {
      const element = document.getElementById(id);
      assert.ok(element, 'Missing dashboard element #' + id);
      const event = { type, target: element, preventDefault() {}, stopPropagation() {} };
      const handlers = [element['on' + type], ...(element.listeners.get(type) || [])].filter(fn => typeof fn === 'function');
      assert.ok(handlers.length, 'Missing ' + type + ' handler on #' + id);
      for (const handler of handlers) await handler.call(element, event);
    },
    advance: milliseconds => {
      now += milliseconds;
      for (const [id, timer] of [...timers]) if (timer.at <= now) {
        if (timer.repeat) timer.at = now + timer.delay; else timers.delete(id);
        timer.callback();
      }
    }
  };
}

function report(overrides = {}) {
  return {
    schemaVersion: 1, source: 'windows-collector', device: 'TEST-PC', os: 'Windows 11 Pro',
    collectedAt: new Date(START).toISOString(),
    checks: [
      { name: 'Real-time antivirus protection', status: 'pass', detail: 'Defender is enabled.', action: 'Keep protection enabled.' },
      { name: 'Disk space C:', status: 'warning', detail: '8% free.', action: 'Review Storage settings.' },
      { name: 'System drive encryption', status: 'unknown', detail: 'BitLocker could not be read.', action: 'Review encryption settings.' },
      { name: 'Defender quick scan', status: 'info', detail: 'A scan completed yesterday.', action: 'Review history.' }
    ],
    ...overrides
  };
}

const tests = [];
function test(name, run) { tests.push({ name, run }); }

test('the executable can start the dashboard with its embedded report', () => {
  const app = dashboard({ HEALTHSCAN_HOST: 'exe', HEALTHSCAN_LIVE: report() });
  assert.equal(app.run('report.device'), 'TEST-PC');
  assert.equal(app.run('origin'), 'live');
  assert.match(app.get('checks').textContent, /Disk space C:/);
});

test('a launcher address takes precedence over a previously saved report', () => {
  const encoded = Buffer.from(JSON.stringify(report({ device: 'NEW-SCAN-PC' }))).toString('base64url');
  const app = dashboard({
    location: { hash: '#report=' + encoded, pathname: '/index.html', search: '' },
    HEALTHSCAN_REPORT: report({ device: 'OLD-SCAN-PC' })
  });
  assert.equal(app.run('report.device'), 'NEW-SCAN-PC');
  // An address can be supplied by anything that opens the page, so it is not labelled as the local collector.
  assert.equal(app.run('origin'), 'link');
});

test('a damaged saved report surfaces an error instead of invented results', () => {
  const app = dashboard({ HEALTHSCAN_REPORT_FILE: true });
  assert.equal(app.run('report'), null);
  assert.ok(app.get('error').textContent.trim());
});

test('an invalid file import preserves the current report and displays an error', async () => {
  const app = dashboard();
  app.load(report(), 'import');
  const invalid = JSON.stringify(report({ checks: [{ name: 'invalid', status: 'success' }] }));
  app.get('file').files = [{ size: Buffer.byteLength(invalid), text: async () => invalid }];
  await app.trigger('file', 'change');
  assert.equal(app.run('report.device'), 'TEST-PC');
  assert.equal(app.run('report.checks.length'), 4);
  assert.match(app.get('checks').textContent, /Disk space C:/);
  assert.ok(app.get('error').textContent.trim(), 'An invalid import should explain its failure');
  assert.equal(app.get('file').value, '', 'Reset the file input so the same corrected file can be selected');
});

test('status values must be strings rather than values that coerce to status names', () => {
  const app = dashboard();
  app.load(report(), 'import');
  assert.throws(() => app.load(report({ checks: [{ name: 'Malformed check', status: ['pass'], detail: '', action: '' }] }), 'import'));
  assert.equal(app.run('report.checks.length'), 4);
});

test('renders untrusted report text without creating active HTML', () => {
  const app = dashboard();
  const initialImages = app.document.querySelectorAll('img').length;
  app.load(report({ device: payload, checks: [
    { name: payload, detail: payload, action: payload, status: 'warning' },
    { name: 'Disk space C:', detail: payload, action: payload, status: 'warning', href: 'javascript:reportPayloadExecuted=true' }
  ] }), 'import');
  assert.ok(app.get('checks').textContent.includes(payload));
  assert.equal(app.document.querySelectorAll('img').length, initialImages);
  assert.equal(app.context.reportPayloadExecuted, undefined);
  assert.ok(app.audit.htmlWrites.every(value => !value.includes(payload)), 'Untrusted report content passed to innerHTML');
  const links = app.get('checks').querySelectorAll('a');
  assert.ok(links.length, 'A known check should offer a remediation shortcut');
  for (const link of links) assert.match(String(link.href || link.getAttribute('href')), /^(?:ms-settings:|windowsdefender:)/);
});

test('demo mode and clearing work without a collector', () => {
  const app = dashboard();
  app.get('demo').click();
  assert.equal(app.run('report.source'), 'demo');
  assert.match(app.get('mode').textContent, /demo/i);
  app.get('clear').click();
  assert.equal(app.run('report'), null);
  assert.equal(app.get('export').disabled, true);
  assert.equal(app.get('clear').disabled, true);
});

test('pasting remains available with a report loaded and validates before replacing it', () => {
  const app = dashboard();
  app.load(report(), 'import');
  assert.equal(app.get('paste').closest('.hidden'), null, 'Paste is inside a hidden onboarding section');
  app.get('paste').click();
  assert.equal(app.get('pasteModal').open, true);
  app.get('pasteText').value = '{invalid JSON';
  app.get('pasteLoad').click();
  assert.equal(app.run('report.device'), 'TEST-PC');
  assert.ok(app.get('pasteError').textContent.trim());
  assert.equal(app.get('pasteModal').open, true);
  app.get('pasteText').value = JSON.stringify(report({ device: 'PASTED-PC' }));
  app.get('pasteLoad').click();
  assert.equal(app.run('report.device'), 'PASTED-PC');
  assert.equal(app.run('origin'), 'paste');
  assert.equal(app.get('pasteModal').open, false);
});

// Freshness and filtering regressions below are intentionally tied to visible
// outcomes rather than a duplicated implementation of the dashboard logic.
test('a live report ages automatically without a click or reload', () => {
  const app = dashboard();
  app.load(report(), 'live');
  const before = app.get('mode').textContent + ' ' + app.get('notice').textContent;
  assert.ok([...app.timers.values()].some(timer => timer.repeat), 'No recurring freshness refresh is registered');
  app.advance(31 * 60 * 1000);
  const after = app.get('mode').textContent + ' ' + app.get('notice').textContent;
  assert.notEqual(after, before, 'The report still has its initial freshness message after 31 minutes');
  assert.doesNotMatch(after, /collected a few minutes ago/i);
  assert.equal(app.run('report.checks.length'), 4, 'Refreshing age must preserve the report');
});

test('background freshness refresh preserves row objects and open disclosures', () => {
  const app = dashboard();
  app.load(report(), 'live');
  const rows = app.get('checks').querySelectorAll('.check');
  const details = app.get('checks').querySelectorAll('details');
  assert.ok(details.length, 'The fixture should include expandable check details');
  details.forEach((node, index) => { node.open = index % 2 === 0; });
  const states = details.map(node => node.open);
  app.advance(31 * 60 * 1000);
  const afterRows = app.get('checks').querySelectorAll('.check');
  const afterDetails = app.get('checks').querySelectorAll('details');
  assert.equal(afterRows.length, rows.length);
  rows.forEach((node, index) => assert.equal(afterRows[index], node, 'A freshness update replaced a check row'));
  details.forEach((node, index) => {
    assert.equal(afterDetails[index], node, 'A freshness update replaced a disclosure');
    assert.equal(afterDetails[index].open, states[index]);
  });
});

test('a saved report older than ten minutes is marked as an earlier snapshot', () => {
  const app = dashboard();
  app.load(report({ collectedAt: new Date(START - 45 * 60 * 1000).toISOString() }), 'saved');
  const text = app.get('mode').textContent + ' ' + app.get('notice').textContent;
  assert.match(text, /earlier|older|stale|45 minutes|45 min/i);
  assert.doesNotMatch(text, /collected a few minutes ago/i);
});

test('a future timestamp is explained instead of displaying a negative age', () => {
  const app = dashboard();
  app.load(report({ collectedAt: new Date(START + 2 * 60 * 60 * 1000).toISOString() }), 'saved');
  const text = app.get('mode').textContent + ' ' + app.get('notice').textContent;
  assert.match(text, /clock|future|ahead/i);
  assert.doesNotMatch(text, /-\d+\s+(?:min|hour|day)/i);
});

test('category navigation filters the displayed checks', () => {
  const app = dashboard();
  app.load(report(), 'import');
  const storage = app.document.querySelector('[data-category="storage"]');
  assert.ok(storage, 'Storage category control is missing');
  storage.click();
  assert.match(app.get('checks').textContent, /Disk space C:/);
  assert.doesNotMatch(app.get('checks').textContent, /Real-time antivirus protection|Defender quick scan/);
  app.document.querySelector('[data-category="all"]').click();
  assert.match(app.get('checks').textContent, /Real-time antivirus protection/);
});

test('status filtering and case-insensitive search work together', async () => {
  const app = dashboard();
  app.load(report(), 'import');
  const unknown = app.document.querySelector('[data-filter="unknown"]');
  assert.ok(unknown, 'Unknown status control is missing');
  unknown.click();
  assert.match(app.get('checks').textContent, /System drive encryption/);
  assert.doesNotMatch(app.get('checks').textContent, /Disk space C:|Real-time antivirus protection/);
  app.get('search').value = '  BITLOCKER  ';
  await app.trigger('search', 'input');
  assert.match(app.get('checks').textContent, /System drive encryption/);
  app.get('search').value = 'Defender';
  await app.trigger('search', 'input');
  assert.doesNotMatch(app.get('checks').textContent, /System drive encryption|Defender quick scan/);
  app.get('search').value = '';
  await app.trigger('search', 'input');
  assert.match(app.get('checks').textContent, /System drive encryption/);
  app.document.querySelector('[data-filter="all"]').click();
  assert.match(app.get('checks').textContent, /Real-time antivirus protection/);
});

test('printing includes every check and then restores filters and disclosures', async () => {
  const app = dashboard();
  app.load(report(), 'import');
  app.document.querySelector('[data-category="protection"]').click();
  app.document.querySelector('[data-filter="pass"]').click();
  app.get('search').value = 'DeFender';
  await app.trigger('search', 'input');
  app.get('checks').querySelectorAll('details').forEach(node => { node.open = true; });
  const previousState = app.run('JSON.stringify({filter, category, query})');
  const previousText = app.get('checks').textContent;
  const previousDetails = app.get('checks').querySelectorAll('details').map(node => node.open);
  assert.equal(app.get('checks').querySelectorAll('.check').length, 1);
  app.document.dispatchEvent({ type: 'beforeprint' });
  assert.equal(app.get('checks').querySelectorAll('.check').length, 4, 'Printing omitted checks hidden by the current view');
  assert.ok(app.get('checks').querySelectorAll('details').every(node => node.open), 'Printing left check details collapsed');
  app.document.dispatchEvent({ type: 'beforeprint' }); // Browsers can emit this more than once.
  app.document.dispatchEvent({ type: 'afterprint' });
  assert.equal(app.run('JSON.stringify({filter, category, query})'), previousState);
  assert.equal(app.get('search').value, 'DeFender');
  assert.equal(app.get('checks').textContent, previousText);
  assert.deepEqual(app.get('checks').querySelectorAll('details').map(node => node.open), previousDetails);
  assert.equal(app.run('printState'), null);
});

test('the score excludes informational checks and the theme control toggles', () => {
  const app = dashboard();
  app.load(report(), 'import');
  assert.equal(app.get('score').textContent, '1/3');
  assert.equal(app.get('infos').textContent, '1');
  app.get('theme').click();
  assert.equal(app.document.documentElement.dataset.theme, 'dark');
  assert.match(app.get('theme').getAttribute('aria-label'), /light/i);
  app.get('theme').click();
  assert.equal(app.document.documentElement.dataset.theme, 'light');
  assert.match(app.get('theme').getAttribute('aria-label'), /dark/i);
});

function earlierReport(overrides = {}) {
  return report({ collectedAt: new Date(START - 60 * 60 * 1000).toISOString(), ...overrides });
}

test('comparison classifies protection changes without ranking unknown or informational states', () => {
  const app = dashboard();
  const expected = {
    pass: { pass: 'unchanged', warning: 'worsened', unknown: 'changed', info: 'changed' },
    warning: { pass: 'improved', warning: 'unchanged', unknown: 'changed', info: 'changed' },
    unknown: { pass: 'changed', warning: 'changed', unknown: 'unchanged', info: 'changed' },
    info: { pass: 'changed', warning: 'changed', unknown: 'changed', info: 'unchanged' }
  };
  const before = [], after = [], expectedKinds = {};
  for (const [oldStatus, nextStatuses] of Object.entries(expected)) {
    for (const [newStatus, kind] of Object.entries(nextStatuses)) {
      const name = oldStatus + ' to ' + newStatus;
      const common = { name, detail: 'Same detail', action: 'Same action' };
      before.push({ ...common, status: oldStatus }); after.push({ ...common, status: newStatus });
      expectedKinds[name] = kind;
    }
  }
  const current = report({ checks: after }), previous = earlierReport({ checks: before });
  const currentBefore = JSON.stringify(current), previousBefore = JSON.stringify(previous);
  const rows = app.compare(current, previous);
  assert.deepEqual(Object.fromEntries(Array.from(rows, row => [row.name, row.kind])), expectedKinds);
  assert.equal(JSON.stringify(current), currentBefore, 'Comparison mutated the current report');
  assert.equal(JSON.stringify(previous), previousBefore, 'Comparison mutated the baseline report');
});

test('comparison separates changed details, new checks, and checks absent from the new scan', () => {
  const app = dashboard();
  const previous = earlierReport({ checks: [
    { name: 'Disk space C:', status: 'pass', detail: '40% free', action: 'Review storage' },
    { name: 'Old provider check', status: 'warning', detail: 'Provider reported a problem', action: 'Review provider' },
    { name: 'Memory availability', status: 'pass', detail: '50% free', action: 'Review Task Manager' }
  ] });
  const current = report({ checks: [
    { name: 'Disk space C:', status: 'pass', detail: '45% free', action: 'Review storage' },
    { name: 'Battery health', status: 'info', detail: 'No battery installed', action: 'No action needed' },
    { name: 'Memory availability', status: 'pass', detail: '50% free', action: 'Review Task Manager' }
  ] });
  const kinds = Object.fromEntries(Array.from(app.compare(current, previous), row => [row.name, row.kind]));
  assert.deepEqual(kinds, { 'Disk space C:': 'updated', 'Battery health': 'added', 'Memory availability': 'unchanged', 'Old provider check': 'removed' });
});

test('baseline validation rejects a different device, source, timestamp, or ambiguous names without losing state', () => {
  const app = dashboard();
  app.load(report(), 'import');
  app.loadBaseline(earlierReport());
  const currentBefore = app.run('JSON.stringify(report)'), baselineBefore = app.run('JSON.stringify(baseline)');
  const duplicate = earlierReport(); duplicate.checks.push({ ...duplicate.checks[0] });
  const invalid = [
    earlierReport({ device: 'DIFFERENT-PC' }),
    earlierReport({ source: 'demo' }),
    earlierReport({ collectedAt: new Date(START).toISOString() }),
    earlierReport({ collectedAt: new Date(START + 60 * 1000).toISOString() }),
    earlierReport({ schemaVersion: 2 }),
    duplicate
  ];
  for (const candidate of invalid) {
    assert.throws(() => app.loadBaseline(candidate));
    assert.equal(app.run('JSON.stringify(report)'), currentBefore, 'Invalid baseline changed the current report');
    assert.equal(app.run('JSON.stringify(baseline)'), baselineBefore, 'Invalid baseline discarded a valid comparison');
  }
  assert.throws(() => app.load(report({ schemaVersion: 2 }), 'import'));
  assert.equal(app.run('JSON.stringify(baseline)'), baselineBefore, 'A rejected current report discarded its comparison');
});

test('comparison refuses an ambiguous current report as well as an ambiguous baseline', () => {
  const app = dashboard();
  const duplicate = report(); duplicate.checks.push({ ...duplicate.checks[0] });
  try { app.load(duplicate, 'import'); }
  catch (_) { assert.equal(app.run('report'), null); return; }
  assert.throws(() => app.loadBaseline(earlierReport()));
  assert.equal(app.run('baseline'), null);
});

test('baseline file import enforces size and JSON validation while preserving the accepted comparison', async () => {
  const app = dashboard();
  app.load(report(), 'import');
  app.get('baselineFile').files = [{ size: 10, text: async () => '{not JSON' }];
  await app.trigger('baselineFile', 'change');
  assert.equal(app.run('baseline'), null);
  assert.ok(app.get('comparisonError').textContent.trim());
  assert.equal(app.get('comparisonError').closest('.hidden'), null, 'The first baseline error is hidden with the unopened comparison');
  const json = JSON.stringify(earlierReport());
  app.get('baselineFile').files = [{ size: Buffer.byteLength(json), text: async () => json }];
  await app.trigger('baselineFile', 'change');
  assert.ok(app.run('baseline'));
  assert.equal(app.get('comparison').closest('.hidden'), null);
  assert.ok(app.get('comparisonSummary').textContent.trim());
  const baselineBefore = app.run('JSON.stringify(baseline)');
  let oversizedRead = false;
  app.get('baselineFile').files = [{ size: 1024 * 1024 + 1, text: async () => { oversizedRead = true; return json; } }];
  await app.trigger('baselineFile', 'change');
  assert.equal(oversizedRead, false, 'An oversized baseline was read before rejecting its size');
  assert.equal(app.run('JSON.stringify(baseline)'), baselineBefore);
  assert.ok(app.get('comparisonError').textContent.trim());
  app.get('baselineFile').files = [{ size: 10, text: async () => '{not JSON' }];
  await app.trigger('baselineFile', 'change');
  assert.equal(app.run('JSON.stringify(baseline)'), baselineBefore);
  assert.equal(app.run('report.device'), 'TEST-PC');
  assert.ok(app.get('comparisonError').textContent.trim());
  assert.equal(app.get('baselineFile').value, '');
});

test('comparison renders report-derived names and details as inert text', () => {
  const app = dashboard();
  const initialImages = app.document.querySelectorAll('img').length;
  app.load(report({ checks: [{ name: payload, status: 'pass', detail: payload, action: payload }] }), 'import');
  app.loadBaseline(earlierReport({ checks: [{ name: payload, status: 'warning', detail: payload, action: payload }] }));
  assert.ok(app.get('comparisonRows').textContent.includes(payload));
  assert.equal(app.document.querySelectorAll('img').length, initialImages);
  assert.equal(app.context.reportPayloadExecuted, undefined);
  assert.ok(app.audit.htmlWrites.every(value => !value.includes(payload)), 'A comparison inserted report data using innerHTML');
});

test('clearing or replacing a current report also clears its comparison', () => {
  const app = dashboard();
  assert.equal(app.get('compare').disabled, true);
  assert.throws(() => app.loadBaseline(earlierReport()));
  app.load(report(), 'import');
  assert.equal(app.get('compare').disabled, false);
  app.loadBaseline(earlierReport());
  const currentBefore = app.run('JSON.stringify(report)');
  app.get('clearComparison').click();
  assert.equal(app.run('baseline'), null);
  assert.equal(app.run('JSON.stringify(report)'), currentBefore);
  app.loadBaseline(earlierReport());
  app.load(report({ device: 'NEW-CURRENT-PC' }), 'import');
  assert.equal(app.run('baseline'), null);
  app.loadBaseline(earlierReport({ device: 'NEW-CURRENT-PC' }));
  app.get('clear').click();
  assert.equal(app.run('baseline'), null);
  assert.equal(app.run('report'), null);
  assert.equal(app.get('compare').disabled, true);
});

function deferred() {
  let resolve, reject;
  const promise = new Promise((accept, fail) => { resolve = accept; reject = fail; });
  return { promise, resolve, reject };
}

test('a slower baseline read cannot overwrite a newer file selection', async () => {
  const app = dashboard();
  app.load(report(), 'import');
  const slow = deferred();
  app.get('baselineFile').files = [{ size: 100, text: () => slow.promise }];
  const pending = app.trigger('baselineFile', 'change');
  const newerSelection = earlierReport({ collectedAt: new Date(START - 2 * 60 * 60 * 1000).toISOString() });
  const json = JSON.stringify(newerSelection);
  app.get('baselineFile').files = [{ size: Buffer.byteLength(json), text: async () => json }];
  await app.trigger('baselineFile', 'change');
  slow.resolve(JSON.stringify(earlierReport()));
  await pending;
  assert.equal(app.run('baseline.collectedAt'), newerSelection.collectedAt);
  assert.equal(app.get('comparisonError').textContent, '');

  const failing = deferred();
  app.get('baselineFile').files = [{ size: 100, text: () => failing.promise }];
  const failingRead = app.trigger('baselineFile', 'change');
  app.get('baselineFile').files = [{ size: Buffer.byteLength(json), text: async () => json }];
  await app.trigger('baselineFile', 'change');
  failing.reject(new Error('Outdated file read failed'));
  await failingRead;
  assert.equal(app.get('comparisonError').textContent, '', 'An outdated read error replaced the accepted selection');
});

test('replacing or clearing the report or comparison cancels a pending baseline read', async () => {
  const operations = [
    app => app.load(report({ collectedAt: new Date(START + 60 * 1000).toISOString() }), 'import'),
    app => app.get('clear').click(),
    app => app.get('clearComparison').click()
  ];
  for (const operation of operations) {
    const app = dashboard();
    app.load(report(), 'import'); app.loadBaseline(earlierReport());
    const slow = deferred();
    app.get('baselineFile').files = [{ size: 100, text: () => slow.promise }];
    const pending = app.trigger('baselineFile', 'change');
    operation(app);
    slow.resolve(JSON.stringify(earlierReport()));
    await pending;
    assert.equal(app.run('baseline'), null, 'An obsolete read restored a cleared comparison');
    assert.equal(app.get('comparisonError').textContent, '');
  }
});

test('printing expands comparison details and restores them after the dialog closes', () => {
  const app = dashboard();
  app.get('demo').click();
  assert.ok(app.run('baseline'), 'The demo should include a fictional comparison');
  const details = app.get('comparisonRows').querySelectorAll('details');
  assert.ok(details.length > 1);
  details.forEach((node, index) => { node.open = index % 2 === 0; });
  const states = details.map(node => node.open);
  app.advance(31 * 60 * 1000);
  details.forEach((node, index) => {
    assert.equal(app.get('comparisonRows').querySelectorAll('details')[index], node, 'Freshness updates replaced a comparison disclosure');
    assert.equal(node.open, states[index]);
  });
  app.document.dispatchEvent({ type: 'beforeprint' });
  assert.ok(app.get('comparisonRows').querySelectorAll('details').every(node => node.open));
  app.document.dispatchEvent({ type: 'afterprint' });
  assert.deepEqual(app.get('comparisonRows').querySelectorAll('details').map(node => node.open), states);
});

test('stable check ids distinguish batteries and survive display-name changes', () => {
  const app = dashboard();
  const previous = earlierReport({ checks: [
    { id: 'battery:a', name: 'Battery health: Battery 1', status: 'warning', detail: '60% capacity', action: 'Review runtime' },
    { id: 'battery:b', name: 'Battery health: Battery 2', status: 'pass', detail: '95% capacity', action: 'Review runtime' }
  ] });
  const current = report({ checks: [
    { id: 'battery:b', name: 'Battery health: Battery 1', status: 'pass', detail: '95% capacity', action: 'Review runtime' },
    { id: 'battery:a', name: 'Battery health: Battery 2', status: 'pass', detail: '90% capacity', action: 'Review runtime' }
  ] });
  const rows = Array.from(app.compare(current, previous));
  assert.equal(rows.length, 2, 'The same physical batteries were treated as new or missing checks');
  const improved = rows.filter(row => row.kind === 'improved');
  assert.equal(improved.length, 1, 'The improved battery was paired with the wrong previous battery');
  assert.equal(improved[0].before.id, 'battery:a');
  assert.equal(improved[0].after.id, 'battery:a');
  assert.equal(rows.filter(row => row.kind === 'worsened').length, 0);
  app.load(current, 'import'); app.loadBaseline(previous);
  assert.ok(app.get('comparisonRows').textContent.includes('Battery health: Battery 2'));
});

test('check ids and legacy names use separate namespaces and duplicate ids are rejected', () => {
  const app = dashboard();
  const previous = earlierReport({ checks: [{ id: 'shared-key', name: 'Battery health', status: 'warning', detail: '', action: '' }] });
  const current = report({ checks: [{ name: 'shared-key', status: 'pass', detail: '', action: '' }] });
  const kinds = Array.from(app.compare(current, previous), row => row.kind).sort();
  assert.deepEqual(kinds, ['added', 'removed'], 'A legacy check name collided with an explicit identity');
  const duplicate = earlierReport({ checks: [
    { id: 'duplicate', name: 'Battery A', status: 'pass', detail: '', action: '' },
    { id: 'duplicate', name: 'Battery B', status: 'pass', detail: '', action: '' }
  ] });
  app.load(report(), 'import'); app.loadBaseline(earlierReport());
  const accepted = app.run('JSON.stringify(baseline)');
  assert.throws(() => app.loadBaseline(duplicate));
  assert.equal(app.run('JSON.stringify(baseline)'), accepted);
  for (const id of [42, ['id'], 'x'.repeat(129)]) {
    assert.throws(() => app.load(report({ checks: [{ id, name: 'Battery', status: 'pass', detail: '', action: '' }] }), 'import'));
  }
});

test('newer current-report selections win and stale callbacks preserve newer inputs and comparisons', async () => {
  const app = dashboard();
  app.load(report(), 'import'); app.loadBaseline(earlierReport());
  const slow = deferred();
  app.get('file').files = [{ size: 100, text: () => slow.promise }];
  const oldRead = app.trigger('file', 'change');
  const selected = report({ device: 'LATEST-PC' });
  const json = JSON.stringify(selected);
  app.get('file').files = [{ size: Buffer.byteLength(json), text: async () => json }];
  await app.trigger('file', 'change');
  app.loadBaseline(earlierReport({ device: 'LATEST-PC' }));
  const currentBefore = app.run('JSON.stringify(report)'), baselineBefore = app.run('JSON.stringify(baseline)');
  slow.resolve(JSON.stringify(report({ device: 'OUTDATED-READ-PC' })));
  await oldRead;
  assert.equal(app.run('JSON.stringify(report)'), currentBefore);
  assert.equal(app.run('JSON.stringify(baseline)'), baselineBefore, 'An outdated current import erased the newer comparison');

  const failing = deferred(), newer = deferred();
  app.get('file').files = [{ size: 100, text: () => failing.promise }];
  const failingRead = app.trigger('file', 'change');
  app.get('file').files = [{ size: 100, text: () => newer.promise }];
  app.get('file').value = 'new-current.json';
  const newerRead = app.trigger('file', 'change');
  failing.reject(new Error('Outdated current import failed'));
  await failingRead;
  assert.equal(app.get('error').textContent, '', 'An outdated read error appeared over the newer selection');
  assert.equal(app.get('file').value, 'new-current.json', 'An outdated finally handler cleared the newer input');
  assert.equal(app.run('JSON.stringify(report)'), currentBefore);
  assert.equal(app.run('JSON.stringify(baseline)'), baselineBefore);
  newer.resolve(JSON.stringify(report({ device: 'FINAL-PC' })));
  await newerRead;
  assert.equal(app.run('report.device'), 'FINAL-PC');
  assert.equal(app.run('baseline'), null);
  assert.equal(app.get('file').value, '');
});

test('Clear, Demo, and explicit current loads cancel pending current-import successes and errors', async () => {
  const operations = [
    { name: 'Clear', run: app => app.get('clear').click() },
    { name: 'Demo', run: app => app.get('demo').click() },
    { name: 'Explicit load', run: app => { app.load(report({ device: 'REPLACEMENT-PC' }), 'paste'); app.loadBaseline(earlierReport({ device: 'REPLACEMENT-PC' })); } }
  ];
  for (const operation of operations) for (const fail of [false, true]) {
    const app = dashboard();
    app.load(report(), 'import'); app.loadBaseline(earlierReport());
    const slow = deferred();
    app.get('file').files = [{ size: 100, text: () => slow.promise }];
    app.get('file').value = 'outdated-current.json';
    app.get('baselineFile').value = 'outdated-baseline.json';
    const pending = app.trigger('file', 'change');
    operation.run(app);
    const currentAfter = app.run('JSON.stringify(report)'), baselineAfter = app.run('JSON.stringify(baseline)');
    assert.equal(app.get('file').value, '', operation.name + ' left the old current input selected');
    assert.equal(app.get('baselineFile').value, '', operation.name + ' left the old baseline input selected');
    if (operation.name !== 'Clear') assert.ok(app.run('baseline'), 'The replacement comparison should be available');
    if (fail) slow.reject(new Error('Obsolete file read error'));
    else slow.resolve(JSON.stringify(report({ device: 'OUTDATED-READ-PC' })));
    await pending;
    assert.equal(app.run('JSON.stringify(report)'), currentAfter, operation.name + ' was overwritten by a pending import');
    assert.equal(app.run('JSON.stringify(baseline)'), baselineAfter, operation.name + ' lost its replacement comparison');
    assert.equal(app.get('error').textContent, '', operation.name + ' displayed an obsolete import error');
    assert.equal(app.get('file').value, '');
  }
});

test('a rejected newer current import retains its error and comparison after an older read completes', async () => {
  const app = dashboard();
  app.load(report(), 'import'); app.loadBaseline(earlierReport());
  const currentBefore = app.run('JSON.stringify(report)'), baselineBefore = app.run('JSON.stringify(baseline)');
  const slow = deferred();
  app.get('file').files = [{ size: 100, text: () => slow.promise }];
  const pending = app.trigger('file', 'change');
  app.get('file').files = [{ size: 10, text: async () => '{invalid JSON' }];
  await app.trigger('file', 'change');
  const visibleError = app.get('error').textContent;
  assert.ok(visibleError.trim());
  slow.resolve(JSON.stringify(report({ device: 'OUTDATED-READ-PC' })));
  await pending;
  assert.equal(app.run('JSON.stringify(report)'), currentBefore);
  assert.equal(app.run('JSON.stringify(baseline)'), baselineBefore);
  assert.equal(app.get('error').textContent, visibleError);
});

// ---- Static checks of the page's guide text and stylesheet ----
const css = [...html.matchAll(/<style>([\s\S]*?)<\/style>/gi)].map(match => match[1]).join('\n');
function tokens(selectorPattern) {
  const block = new RegExp(selectorPattern + '\\{([^}]*)\\}').exec(css);
  assert.ok(block, 'Missing token block ' + selectorPattern);
  return Object.fromEntries([...block[1].matchAll(/--([\w-]+):(#[0-9a-f]{6}|#[0-9a-f]{3})\b/gi)].map(match => [match[1], match[2].length === 4 ? '#' + [...match[2].slice(1)].map(c => c + c).join('') : match[2]]));
}
function contrast(a, b) {
  const lum = hex => {
    const [r, g, bl] = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255).map(v => v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
    return 0.2126 * r + 0.7152 * g + 0.0722 * bl;
  };
  const [x, y] = [lum(a), lum(b)];
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
}

test('manual collector commands bypass the default Restricted execution policy for that run only', () => {
  const app = dashboard();
  const codes = app.get('scriptGuide').querySelectorAll('code').map(node => node.textContent.trim());
  const collector = codes.filter(code => /Collect-Health\.ps1/.test(code));
  assert.ok(collector.length >= 2, 'The guide should cover the manual and quick-scan commands');
  for (const code of collector) {
    assert.match(code, /^powershell\.exe -NoProfile -ExecutionPolicy Bypass -File \S*Collect-Health\.ps1/, 'A bare script call is refused on a default Windows PC: ' + code);
  }
  assert.ok(collector.some(code => /-QuickScan$/.test(code)));
  assert.match(app.get('scriptGuide').textContent, /administrator[\s\S]*app folder/i, 'The administrator case must say to change to the app folder first');
  assert.match(app.get('onboardNote').textContent, /Scan instructions/);
});

test('a report from the page address is not presented as a verified fresh collector scan', () => {
  const encoded = Buffer.from(JSON.stringify(report())).toString('base64url');
  const app = dashboard({ location: { hash: '#report=' + encoded, pathname: '/index.html', search: '' } });
  assert.equal(app.run('origin'), 'link');
  assert.doesNotMatch(app.get('mode').textContent, /fresh/i);
  assert.doesNotMatch(app.get('source').textContent, /collector/i);
  assert.match(app.get('source').textContent, /page address/i);
  assert.match(app.get('notice').textContent, /page address/i);
  assert.match(app.get('notice').textContent, /unverified/i);
  const exe = dashboard({ HEALTHSCAN_HOST: 'exe', HEALTHSCAN_LIVE: report() });
  assert.match(exe.get('mode').textContent, /fresh/i, 'The executable-embedded scan keeps its label');
});

test('clearing a saved report explains that the saved copy remains on disk', () => {
  const app = dashboard({ HEALTHSCAN_REPORT: report() });
  assert.equal(app.run('origin'), 'saved');
  app.get('clear').click();
  assert.equal(app.run('report'), null);
  assert.match(app.get('notice').textContent, /latest-report\.js/);
  assert.match(app.get('notice').textContent, /reload/i);
  app.get('demo').click();
  app.get('clear').click();
  assert.doesNotMatch(app.get('notice').textContent, /latest-report\.js/, 'The saved-copy note outlived the saved report');
});

test('the executable page drops its embedded copy of the report once it is loaded', () => {
  const app = dashboard({ HEALTHSCAN_HOST: 'exe', HEALTHSCAN_LIVE: report() }, {
    beforeRun: document => {
      const script = new Element('script', document.audit);
      script.textContent = 'window.HEALTHSCAN_HOST="exe";window.HEALTHSCAN_LIVE={};';
      script.id = 'injected';
      document.querySelector('body').append(script);
    }
  });
  assert.equal(app.run('report.device'), 'TEST-PC');
  assert.equal(app.run('typeof window.HEALTHSCAN_LIVE'), 'undefined');
  assert.equal(app.document.querySelector('#injected'), null, 'The injected report script is still in the page');
  assert.equal(app.run('window.HEALTHSCAN_HOST'), 'exe');
});

test('printing uses a zero page margin so browser headers and footers carry no local path', () => {
  assert.match(css, /@page\{margin:0\}/);
  assert.match(css, /@media print\{[^@]*body\{[^}]*padding:12mm/);
});

test('an unsaved live or address-supplied scan is only replaced after confirmation', () => {
  const encoded = Buffer.from(JSON.stringify(report({ device: 'LINK-PC' }))).toString('base64url');
  const setups = [
    { HEALTHSCAN_HOST: 'exe', HEALTHSCAN_LIVE: report({ device: 'LIVE-PC' }) },
    { location: { hash: '#report=' + encoded, pathname: '/index.html', search: '' } }
  ];
  for (const globals of setups) {
    let answer = false;
    const app = dashboard({ ...globals, confirm: () => answer });
    const device = app.run('report.device');
    let picker = 0; app.get('file').click = () => { picker++; };
    app.get('demo').click();
    app.get('clear').click();
    app.get('paste').click(); app.get('pasteText').value = JSON.stringify(report({ device: 'PASTED-PC' })); app.get('pasteLoad').click();
    assert.equal(app.run('report.device'), device, 'A declined confirmation still replaced the scan');
    assert.equal(app.audit.confirms.length, 3);
    answer = true;
    app.get('demo').click();
    assert.equal(app.run('report.source'), 'demo');
    assert.equal(app.audit.confirms.length, 4);
    app.get('clear').click(); app.get('import').click();
    assert.equal(app.audit.confirms.length, 4, 'Replacing a demo or imported report should not ask');
    assert.equal(picker, 1);
  }
  const exported = dashboard({ HEALTHSCAN_HOST: 'exe', HEALTHSCAN_LIVE: report(), confirm: () => false });
  exported.get('export').click();
  exported.get('demo').click();
  assert.equal(exported.run('report.source'), 'demo', 'An exported scan should be replaceable without asking');
  assert.equal(exported.audit.confirms.length, 0);
});

test('import opens the file picker at once and asks only after a valid file is chosen', async () => {
  const encoded = Buffer.from(JSON.stringify(report({ device: 'LINK-PC' }))).toString('base64url');
  for (const globals of [{ HEALTHSCAN_HOST: 'exe', HEALTHSCAN_LIVE: report({ device: 'LIVE-PC' }) }, { location: { hash: '#report=' + encoded, pathname: '/index.html', search: '' } }]) {
    let answer = false;
    const app = dashboard({ ...globals, confirm: () => answer });
    const device = app.run('report.device');
    let picker = 0; app.get('file').click = () => { picker++; };
    app.get('import').click();
    assert.equal(picker, 1, 'Import must open the picker straight from the click, before any dialog');
    assert.equal(app.audit.confirms.length, 0, 'A dialog before the picker can use up the user activation');
    const invalid = '{"schemaVersion":1}';
    app.get('file').files = [{ size: invalid.length, text: async () => invalid }];
    await app.trigger('file', 'change');
    assert.equal(app.audit.confirms.length, 0, 'An invalid file should be rejected without asking');
    assert.ok(app.get('error').textContent.trim());
    assert.equal(app.run('report.device'), device);
    const valid = JSON.stringify(report({ device: 'IMPORTED-PC' }));
    app.get('file').files = [{ size: valid.length, text: async () => valid }];
    app.get('file').value = 'imported.json';
    await app.trigger('file', 'change');
    assert.equal(app.audit.confirms.length, 1);
    assert.equal(app.run('report.device'), device, 'A declined confirmation still replaced the scan');
    assert.equal(app.get('file').value, '', 'The declined file stays selectable again');
    answer = true;
    await app.trigger('file', 'change');
    assert.equal(app.audit.confirms.length, 2);
    assert.equal(app.run('report.device'), 'IMPORTED-PC');
    assert.equal(app.run('origin'), 'import');
    await app.trigger('file', 'change');
    assert.equal(app.audit.confirms.length, 2, 'Replacing an imported report should not ask');
  }
});

test('exe-mode text says the report lives only in this tab and reloading will not bring it back', () => {
  const app = dashboard({ HEALTHSCAN_HOST: 'exe', HEALTHSCAN_LIVE: report() });
  const live = app.get('notice').textContent;
  assert.match(live, /only in this tab/i);
  assert.match(live, /reload[\s\S]*not bring it back/i);
  assert.match(live, /Export JSON/);
  assert.match(live, /HealthScan\.exe again/);
  app.get('clear').click();
  const cleared = app.get('notice').textContent;
  assert.match(cleared, /cleared/i);
  assert.match(cleared, /reload[\s\S]*not bring it back/i);
  assert.match(cleared, /HealthScan\.exe again/);
  assert.match(app.get('checks').textContent, /HealthScan\.exe again/);
  assert.match(app.get('checks').textContent, /Reloading this page will not bring back/);
  const reloaded = dashboard({ HEALTHSCAN_HOST: 'exe' });
  assert.match(reloaded.get('notice').textContent, /reload[\s\S]*not bring an earlier report back/i);
  assert.match(reloaded.get('notice').textContent, /HealthScan\.exe again/);
  for (const text of [live, cleared, reloaded.get('notice').textContent, app.get('onboardNote').textContent, app.get('checks').textContent]) {
    assert.doesNotMatch(text, /30 minutes|session expires/i, 'The report itself has no 30-minute session: ' + text);
  }
  const guide = app.get('exeGuide').textContent;
  assert.match(guide, /only in this browser tab/);
  assert.match(guide, /quick scan[^.]*\.[^.]*30 minutes/i, 'The 30-minute limit belongs to the quick-scan button');
  assert.doesNotMatch(guide, /session expires/i);
  const demo = dashboard({ HEALTHSCAN_HOST: 'exe' });
  demo.get('demo').click(); demo.get('clear').click();
  assert.doesNotMatch(demo.get('notice').textContent, /^Report cleared/, 'A cleared demo was never handed over by the executable');
});

test('a report from the page address says reloading clears it, with no session', () => {
  const encoded = Buffer.from(JSON.stringify(report())).toString('base64url');
  const app = dashboard({ location: { hash: '#report=' + encoded, pathname: '/index.html', search: '' } });
  const notice = app.get('notice').textContent;
  assert.doesNotMatch(notice, /session|30 minutes|expires/i);
  assert.match(notice, /only in this tab/i);
  assert.match(notice, /reloading will clear it/i);
  assert.match(notice, /Export JSON/);
  app.get('clear').click();
  assert.match(app.get('notice').textContent, /not bring it back/i);
  assert.match(app.get('notice').textContent, /Open-HealthScan\.cmd again/);
});

test('a page-address report keeps its warnings when it is old, dated ahead or claims to be a demo', () => {
  const variants = [
    report({ collectedAt: new Date(START - 3 * 24 * 60 * 60 * 1000).toISOString() }),
    report({ collectedAt: new Date(START + 2 * 60 * 60 * 1000).toISOString() }),
    report({ source: 'demo' })
  ];
  for (const data of variants) {
    const encoded = Buffer.from(JSON.stringify(data)).toString('base64url');
    const app = dashboard({ location: { hash: '#report=' + encoded, pathname: '/index.html', search: '' } });
    assert.equal(app.get('mode').textContent, 'FROM PAGE ADDRESS', 'A crafted timestamp or source must not hide the page-address label');
    const notice = app.get('notice').textContent;
    assert.match(notice, /unverified/i);
    assert.match(notice, /reloading will clear it/i);
    assert.match(notice, /Export JSON/);
  }
});

test('a live exe report still warns that reloading loses it once it is more than ten minutes old', () => {
  const app = dashboard({ HEALTHSCAN_HOST: 'exe', HEALTHSCAN_LIVE: report() });
  app.advance(11 * 60 * 1000);
  const notice = app.get('notice').textContent;
  assert.match(notice, /11 minutes/);
  assert.match(notice, /only in this tab/i);
  assert.match(notice, /Export JSON/);
});

test('the quick-scan request sends a same-origin referrer so the Origin header is usable', async () => {
  const calls = [];
  const app = dashboard({ HEALTHSCAN_HOST: 'exe', HEALTHSCAN_LIVE: report(), fetch: async (url, options) => { calls.push({ url, options }); return { ok: true, text: async () => 'Started.' }; } });
  const button = app.get('quickScan');
  assert.ok(!button.classList.contains('hidden'));
  await button.onclick();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, '/index.htmlquickscan');
  assert.equal(calls[0].options.method, 'POST');
  assert.equal(calls[0].options.referrerPolicy, 'same-origin');
  assert.equal(calls[0].options.credentials, 'omit');
  assert.equal(button.disabled, false);
});

test('an invalid paste is rejected before asking to replace an unsaved scan', () => {
  const app = dashboard({ HEALTHSCAN_HOST: 'exe', HEALTHSCAN_LIVE: report() });
  app.get('paste').click(); app.get('pasteText').value = '{"schemaVersion":1}'; app.get('pasteLoad').click();
  assert.equal(app.audit.confirms.length, 0);
  assert.ok(app.get('pasteError').textContent.trim());
  assert.equal(app.run('origin'), 'live');
});

test('focus rings reach 3:1 and status filter rings sit inside their scroll container', () => {
  assert.match(css, /button:focus-visible,[^{]*\{outline:3px solid var\(--accent\)/);
  assert.match(css, /\.filter:focus-visible\{outline-offset:-3px\}|\.nav-button:focus-visible,\.filter:focus-visible\{outline-offset:-3px\}/);
  assert.match(css, /\.sidebar :focus-visible\{outline-color:#66b58a\}/);
  const light = tokens(':root'), dark = tokens('\\[data-theme=dark\\]');
  for (const surface of ['surface', 'soft', 'bg']) {
    assert.ok(contrast(light.accent, light[surface]) >= 3, 'Light focus ring on ' + surface);
    assert.ok(contrast(dark.accent, dark[surface]) >= 3, 'Dark focus ring on ' + surface);
  }
  assert.ok(contrast('#66b58a', '#113b30') >= 3 && contrast('#66b58a', '#0e241b') >= 3, 'Sidebar focus ring');
  // The active category button has its own pale background, and its ring is drawn inside it.
  const activeNav = /\.nav-button\.active\{background:(#[0-9a-f]{6})/.exec(css)[1];
  const activeRing = /\.nav-button\.active:focus-visible\{outline-color:(#[0-9a-f]{6})\}/.exec(css);
  assert.ok(activeRing, 'The active category button needs its own focus ring colour');
  assert.ok(contrast(activeRing[1], activeNav) >= 3, 'Active category ring ' + contrast(activeRing[1], activeNav).toFixed(2));
  assert.ok(contrast('#66b58a', activeNav) < 3, 'Sanity: the sidebar ring alone is too faint on the active button');
  // The About dialog keeps light colours in both themes, so it cannot use the dark-theme accent.
  const aboutRing = /\.about-dialog :focus-visible\{outline-color:(#[0-9a-f]{6})\}/.exec(css);
  assert.ok(aboutRing, 'The About dialog needs its own focus ring colour');
  const aboutBackgrounds = [/\.about-dialog\{[^}]*background:(#[0-9a-f]{6})/, /\.about-dialog \.about-titlebar\{[^}]*background:(#[0-9a-f]{6})/, /\.about-titlebar \.icon-button:hover\{background:(#[0-9a-f]{6})/, /\.about-dialog \.about-footer \.button\{[^}]*background:(#[0-9a-f]{6})/].map(pattern => pattern.exec(css)[1]);
  for (const back of aboutBackgrounds) assert.ok(contrast(aboutRing[1], back) >= 3, 'About focus ring on ' + back + ' ' + contrast(aboutRing[1], back).toFixed(2));
  assert.ok(contrast(dark.accent, aboutBackgrounds[0]) < 3, 'Sanity: the dark-theme accent alone is too faint in the About dialog');
});

test('small text and the search field boundary meet WCAG AA in both themes', () => {
  const light = tokens(':root'), dark = tokens('\\[data-theme=dark\\]');
  for (const theme of [light, dark]) {
    for (const back of ['bg', 'surface', 'soft', 'line', 'yellow', 'bluebg', 'green']) assert.ok(contrast(theme.muted, theme[back]) >= 4.5, 'muted on ' + back + ' ' + contrast(theme.muted, theme[back]).toFixed(2));
    for (const back of ['surface', 'soft', 'yellow']) assert.ok(contrast(theme.amber, theme[back]) >= 4.5, 'amber on ' + back);
    assert.ok(contrast(theme.blue, theme.bluebg) >= 4.5 && contrast(theme.accent, theme.green) >= 4.5);
    assert.ok(contrast(theme.field, theme.soft) >= 3 && contrast(theme.field, theme.surface) >= 3, 'Search field boundary');
  }
  const pill = /\.status-banner\.warning \.pill\{background:(#[0-9a-f]{6});color:var\(--amber\)\}/.exec(css);
  assert.ok(pill && contrast(light.amber, pill[1]) >= 4.5, 'Light warning pill');
  const darkPill = /\[data-theme=dark\] \.status-banner\.warning \.pill\{background:(#[0-9a-f]{6});color:(#[0-9a-f]{6})\}/.exec(css);
  assert.ok(darkPill && contrast(darkPill[1], darkPill[2]) >= 4.5, 'Dark warning pill');
  assert.match(css, /input\[type=search\]\{[^}]*border:1px solid var\(--field\)/);
  const print = /@media print\{html,html\[data-theme\]\{([^}]*)\}/.exec(css)[1];
  const printMuted = /--muted:(#[0-9a-f]{6})/.exec(print)[1], printAmber = /--amber:(#[0-9a-f]{6})/.exec(print)[1];
  assert.ok(contrast(printMuted, '#ffffff') >= 4.5 && contrast(printAmber, '#f6e4bd') >= 4.5, 'Printed text');
});

test('selected filters, stats and categories stay visible in forced-colors mode', () => {
  const block = /@media\(forced-colors:active\)\{([\s\S]*?\})\}/.exec(css);
  assert.ok(block, 'No forced-colors rules');
  for (const selector of ['.nav-button[aria-pressed="true"]', '.filter[aria-pressed="true"]', '.stat[aria-pressed="true"]']) assert.ok(block[1].includes(selector), selector);
  assert.match(block[1], /background:Highlight;color:HighlightText/);
  assert.match(block[1], /\.filter\{border-bottom-color:Canvas\}/);
});

test('hard-coded dark-theme colours do not apply when printing', () => {
  const outsideScreen = css.replace(/@media screen\{(?:[^{}]*\{[^}]*\})*\}/g, '');
  assert.doesNotMatch(outsideScreen, /\[data-theme=dark\] \.status-banner\.warning \.pill/);
  assert.doesNotMatch(outsideScreen, /\[data-theme=dark\] \.error/);
  assert.match(css, /@media screen\{\[data-theme=dark\] \.status-banner\.warning \.pill/);
});

test('search results, load and clear are announced to assistive technology', async () => {
  const app = dashboard();
  assert.equal(app.get('resultMeta').getAttribute('role'), 'status');
  assert.equal(app.document.querySelector('.filters').getAttribute('role'), 'group');
  app.load(report(), 'import');
  assert.match(app.get('announce').textContent, /Report loaded: 4 checks, 1 need attention, 1 need review/);
  assert.equal(app.get('announce').getAttribute('role'), 'status');
  app.get('search').value = 'no such text';
  await app.trigger('search', 'input');
  assert.match(app.get('resultMeta').textContent, /No checks match.*0 of 4/);
  app.advance(31 * 60 * 1000);
  assert.match(app.get('announce').textContent, /Report loaded/, 'The freshness timer should not rewrite the announcement');
  app.get('clear').click();
  assert.match(app.get('announce').textContent, /cleared/i);
});

test('focus follows next-step shortcuts and leaves controls that are hidden or disabled', async () => {
  const app = dashboard();
  app.load(report(), 'import');
  const plan = app.get('plan').querySelectorAll('button');
  plan[0].click();
  const target = app.run('document.activeElement');
  assert.equal(target.id, 'check-1', 'Focus stayed on the next-step shortcut');
  assert.equal(target.getAttribute('tabindex'), '-1');
  assert.equal(JSON.stringify(target.focusOptions), '{"preventScroll":true}');

  app.get('search').value = 'disk'; await app.trigger('search', 'input');
  app.get('resetFilters').focus(); app.get('resetFilters').click();
  assert.equal(app.run('document.activeElement'), app.get('search'));

  app.loadBaseline(earlierReport());
  app.get('clearComparison').focus(); app.get('clearComparison').click();
  assert.equal(app.run('document.activeElement'), app.get('compare'));

  app.get('checks').querySelectorAll('.check')[0].querySelector('a').focus();
  const focusedRow = app.get('checks').querySelectorAll('.check')[0].id;
  app.document.dispatchEvent({ type: 'beforeprint' });
  app.document.dispatchEvent({ type: 'afterprint' });
  assert.equal(app.run('document.activeElement').id, focusedRow, 'Printing lost focus inside the results');

  app.get('clear').focus(); app.get('clear').click();
  assert.equal(app.run('document.activeElement'), app.get('import'));
});

test('search ignores the browser locale, so I and i match under Turkish rules', async () => {
  const app = dashboard();
  app.run(`{ const original = String.prototype.toLocaleLowerCase; String.prototype.toLocaleLowerCase = function () { return original.call(this, 'tr'); }; }`);
  app.load(report({ checks: [{ name: 'Windows Update', status: 'pass', detail: 'Installed 3 days ago.', action: 'Info only.' }] }), 'import');
  for (const term of ['installed', 'INSTALLED', 'info']) {
    app.get('search').value = term; await app.trigger('search', 'input');
    assert.equal(app.get('checks').querySelectorAll('.check').length, 1, 'Search for "' + term + '" missed under a Turkish locale');
  }
});

test('programmatic scrolling honours reduced motion', () => {
  for (const reduce of [true, false]) {
    const app = dashboard({ matchMedia: query => ({ matches: reduce && /prefers-reduced-motion:\s*reduce/.test(query), addEventListener() {} }) });
    app.load(report(), 'import');
    app.document.querySelector('[data-stat="warning"]').click();
    app.document.querySelector('[data-category="storage"]').click();
    app.get('plan').querySelectorAll('button')[0].click();
    assert.equal(app.audit.scrolls.length, 3);
    for (const scroll of app.audit.scrolls) assert.equal(scroll.options.behavior, reduce ? 'auto' : 'smooth');
  }
});

test('reports with more than 100 checks from PCs with many drives are accepted, within a strict bound', () => {
  const app = dashboard();
  const many = count => report({ checks: Array.from({ length: count }, (_, index) => ({ id: 'volume:' + index, name: 'Disk space V' + index, status: index % 7 ? 'pass' : 'warning', detail: 'Free space reported.', action: 'Review storage.' })) });
  app.load(many(180), 'import');
  assert.equal(app.run('report.checks.length'), 180);
  assert.equal(app.get('checks').querySelectorAll('.check').length, 180);
  app.load(many(500), 'import');
  assert.equal(app.run('report.checks.length'), 500);
  assert.throws(() => app.load(many(501), 'import'));
  assert.equal(app.run('report.checks.length'), 500, 'A rejected oversized report replaced the current one');
});

test('startup cleaner button is available in the executable and sends a local POST', async () => {
  const requests = [];
  const app = dashboard({ HEALTHSCAN_HOST: 'exe', HEALTHSCAN_LIVE: report(), location: { hash: '', pathname: '/token/', search: '' },
    fetch: async (url, options) => { requests.push({ url, options }); return { ok: true, text: async () => 'Startup cleanup opened.' }; } });
  const button = app.get('registryCleaner');
  assert.equal(button.classList.contains('hidden'), false);
  await button.onclick();
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, '/token/registrycleaner');
  assert.equal(requests[0].options.method, 'POST');
  assert.equal(requests[0].options.referrerPolicy, 'same-origin');
  assert.match(app.document.querySelector('.report-actions').textContent, /Startup cleanup opened/);
  assert.equal(button.disabled, false);
  assert.equal(dashboard().get('registryCleaner').classList.contains('hidden'), true);
});

async function main() {
  let failures = 0;
  for (const { name, run } of tests) {
    try { await run(); console.log('PASS ' + name); }
    catch (error) { failures++; console.error('FAIL ' + name + '\n' + error.stack); }
  }
  console.log(`${tests.length - failures}/${tests.length} dashboard regression tests passed.`);
  process.exitCode = failures ? 1 : 0;
}
async function historyEndToEnd(address, older, newer) {
  const page = new URL(address);
  assert.equal(page.hostname, '127.0.0.1');
  const markup = await (await fetch(page)).text();
  const app = dashboard({
    location: { hash: '', pathname: page.pathname, search: '' },
    fetch: (path, options) => fetch(new URL(path, page), {
      ...options, headers: { Origin: page.origin }
    })
  }, { markup });
  assert.equal(app.get('scanHistory').classList.contains('hidden'), false);
  await app.trigger('scanHistory', 'click');
  for (const id of ['historyFirst', 'historySecond']) {
    const choices = app.get(id).children.map(option => option.value);
    assert.ok(choices.includes(older) && choices.includes(newer), 'Saved fixtures were not listed');
  }
  app.get('historyFirst').value = older;
  app.get('historySecond').value = older;
  await app.trigger('historySecond', 'change');
  assert.equal(app.get('historyCompare').disabled, true, 'Same scan must not compare');
  app.get('historySecond').value = newer;
  await app.trigger('historySecond', 'change');
  await app.trigger('historyCompare', 'click');
  assert.equal(app.get('historyModal').open, false, app.get('historyStatus').textContent);
  assert.equal(app.run('Date.parse(report.collectedAt) > Date.parse(baseline.collectedAt)'), true);
  assert.match(app.get('comparisonSummary').textContent, /2New warnings1Resolved warnings/);
  const rows = app.get('comparisonRows').children;
  for (const [name, label] of [['New disk warning', 'New warning'], ['Newly checked', 'New warning'],
    ['Recovery completed', 'Resolved warning'], ['No longer measured', 'Not in current'],
    ['Unreadable now', 'Status changed']]) {
    const row = rows.find(item => item.textContent.includes(name));
    assert.ok(row, name + ' row missing');
    assert.match(row.textContent, new RegExp(label));
  }

  const normal = { method: 'POST', headers: { Origin: page.origin } };
  const endpoint = new URL(page.pathname + 'history/', page);
  for (const [url, options] of [
    [endpoint, { method: 'GET' }],
    [endpoint, { method: 'POST' }],
    [endpoint, { method: 'POST', headers: { Origin: 'https://example.invalid' } }],
    [new URL('/wrong-token/history/' + newer, page), normal],
    [new URL(endpoint.href + '%2e%2e%5cREADME.txt', page), normal]
  ]) assert.equal((await fetch(url, options)).status, 404);
  const fetched = await fetch(new URL(endpoint.href + newer), normal);
  assert.match(fetched.headers.get('content-type'), /^application\/json/);
  assert.equal(fetched.headers.get('cache-control'), 'no-store');
  console.log('PASS portable EXE dashboard opens and compares saved scans through loopback');
}
const task = process.argv[2] === '--history-e2e'
  ? historyEndToEnd(...process.argv.slice(3))
  : main();
task.catch(error => { console.error(error); process.exitCode = 1; });
