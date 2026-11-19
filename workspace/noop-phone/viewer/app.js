'use strict';
/*
 * NOOP phone viewer — vanilla JS, no build step, no network beyond the same-origin
 * fetch('noop-data.json'). Everything below is organized top-to-bottom as:
 *   1. Tiny DOM helpers (createElement/textContent only — never innerHTML with data)
 *   2. Base64 / UTF-8 / gzip / WebCrypto helpers (the decrypt pipeline)
 *   3. Formatting helpers (timezone-aware, null-safe: a missing value is ALWAYS "—", never 0)
 *   4. Chart primitives (sparkline, bar chart, hypnogram) — SVG + a hidden <table> twin
 *   5. Screen renderers (Sleep / Workouts + detail / Trends / Lifestyle)
 *   6. Bootstrap: fetch envelope -> show data-age banner -> unlock (remembered key or passphrase)
 */

// ---------------------------------------------------------------------------
// 1. DOM helpers
// ---------------------------------------------------------------------------

/** Create an element. Children are appended as text nodes (strings) or nodes — never HTML. */
function el(tag, attrs, children) {
  const node = document.createElement(tag);
  attrs = attrs || {};
  for (const k in attrs) {
    if (!Object.prototype.hasOwnProperty.call(attrs, k)) continue;
    const v = attrs[k];
    if (v == null) continue;
    if (k === 'class') node.className = v;
    else if (k === 'style' && typeof v === 'object') Object.assign(node.style, v);
    else if (k === 'hidden') node.hidden = !!v;
    else if (k === 'title') node.setAttribute('title', v); // native tooltip, not innerHTML
    else if (k in node) { try { node[k] = v; } catch (e) { node.setAttribute(k, v); } }
    else node.setAttribute(k, v);
  }
  (children || []).forEach(c => {
    if (c == null) return;
    node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
  });
  return node;
}

function svgEl(tag, attrs) {
  const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
  attrs = attrs || {};
  for (const k in attrs) {
    if (!Object.prototype.hasOwnProperty.call(attrs, k)) continue;
    if (attrs[k] == null) continue;
    node.setAttribute(k, attrs[k]);
  }
  return node;
}

function clearNode(node) {
  while (node.firstChild) node.removeChild(node.firstChild);
}

function $(id) { return document.getElementById(id); }

// ---------------------------------------------------------------------------
// 2. Crypto / decode pipeline
// ---------------------------------------------------------------------------

function bytesFromB64(b64) {
  const bin = atob(b64);
  const arr = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
  return arr;
}

function b64FromBytes(bytes) {
  let bin = '';
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

function utf8(str) { return new TextEncoder().encode(str); }

/** v1 envelopes only: derive the payload's AES-256-GCM key straight from the passphrase via
 * PBKDF2-HMAC-SHA256 with the envelope's own salt. Kept so a v1 payload still opens during rollout. */
async function deriveKey(passphrase, saltB64, iterations) {
  const baseKey = await crypto.subtle.importKey('raw', utf8(passphrase), 'PBKDF2', false, ['deriveKey']);
  const salt = bytesFromB64(saltB64);
  return crypto.subtle.deriveKey(
    { name: 'PBKDF2', salt, iterations, hash: 'SHA-256' },
    baseKey,
    { name: 'AES-GCM', length: 256 },
    false,
    ['decrypt']
  );
}

/** v2 envelopes: payloadKey = HMAC-SHA256(master, "noop-payload-v2:" + saltB64), with a fresh random
 * salt on every publish (so every payload still gets its own key). `masterKey` is the non-extractable
 * HMAC CryptoKey of the passphrase root shared with the inbox (see section 5b). Contract shared byte for
 * byte with Sources/noop-publish/Crypto.swift (Payload.payloadKey). */
async function payloadKeyV2(masterKey, saltB64) {
  const raw = new Uint8Array(await crypto.subtle.sign('HMAC', masterKey, utf8('noop-payload-v2:' + saltB64)));
  try {
    return await crypto.subtle.importKey('raw', raw, { name: 'AES-GCM' }, false, ['decrypt']);
  } finally { raw.fill(0); }
}

/** The key that opens `envelope`: v2 from the master key, v1 from the passphrase (null if unavailable). */
async function envelopeKey(envelope, masterKey, passphrase) {
  if (envelope.v === 2) return payloadKeyV2(masterKey, envelope.kdf.saltB64);
  if (passphrase == null) return null;
  return deriveKey(passphrase, envelope.kdf.saltB64, envelope.kdf.iterations);
}

/** gzip-decompress an ArrayBuffer to a UTF-8 string using the native DecompressionStream. */
async function gunzipToText(buf) {
  const ds = new DecompressionStream('gzip');
  const stream = new Response(new Blob([buf]).stream().pipeThrough(ds));
  return stream.text();
}

/** Decrypt the envelope's ciphertext with `key`, gunzip, and parse the JSON payload. */
async function decryptEnvelope(envelope, key) {
  const iv = bytesFromB64(envelope.cipher.nonceB64);
  const aad = utf8(envelope.aad);
  const ct = bytesFromB64(envelope.ctB64);
  const plainBuf = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv, additionalData: aad, tagLength: envelope.cipher.tagBits },
    key,
    ct
  );
  const text = await gunzipToText(plainBuf);
  return JSON.parse(text);
}

// "Remember on this phone" (2026-11-19 decision: open without a passphrase on this phone).
// What is kept: the passphrase ROOT (the inbox master, section 5b) as a NON-EXTRACTABLE HMAC CryptoKey in
// IndexedDB. Page script can use it to derive keys but can never read its bytes back out; the passphrase
// itself is never stored. Anyone holding this unlocked phone can open the page — the phone's own lock is
// the gate. "Forget" deletes it. Safari may evict IndexedDB for a site unvisited for 7 days (Home Screen
// web apps are exempt); then the passphrase is simply asked for again.
const DEVICE_DB = 'noop-viewer';
const DEVICE_STORE = 'keys';
const DEVICE_KEY_ID = 'master';

function idbOpen() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DEVICE_DB, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(DEVICE_STORE);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function idbRun(mode, op) {
  const db = await idbOpen();
  try {
    return await new Promise((resolve, reject) => {
      const tx = db.transaction(DEVICE_STORE, mode);
      const req = op(tx.objectStore(DEVICE_STORE));
      tx.oncomplete = () => resolve(req ? req.result : undefined);
      tx.onerror = () => reject(tx.error);
      tx.onabort = () => reject(tx.error);
    });
  } finally { db.close(); }
}

async function saveDeviceKey(masterKey) {
  try {
    await idbRun('readwrite', s => s.put(masterKey, DEVICE_KEY_ID));
    try { if (navigator.storage && navigator.storage.persist) await navigator.storage.persist(); } catch (e) { /* best effort */ }
    return true;
  } catch (e) {
    console.error('NOOP viewer: could not remember the key on this device', e);
    return false;
  }
}

async function loadDeviceKey() {
  try {
    const k = await idbRun('readonly', s => s.get(DEVICE_KEY_ID));
    return (typeof CryptoKey !== 'undefined' && k instanceof CryptoKey) ? k : null;
  } catch (e) { return null; }
}

async function clearDeviceKey() {
  try { await idbRun('readwrite', s => s.delete(DEVICE_KEY_ID)); } catch (e) { /* nothing stored */ }
}

/** Earlier builds kept a derived key — and the raw inbox master — in sessionStorage. Wipe them. */
function clearLegacySessionKeys() {
  try {
    ['noopViewerKeyB64', 'noopViewerKeySalt', 'noopViewerKeyIter', 'noopViewerInboxMaster']
      .forEach(k => sessionStorage.removeItem(k));
  } catch (e) { /* storage unavailable */ }
}

// ---------------------------------------------------------------------------
// 3. Formatting helpers — every one of these returns "—" for null/undefined/NaN.
//    Never fall through to 0: many fields (spo2Pct, skinTempDevC, steps) are legitimately null.
// ---------------------------------------------------------------------------

function isNum(v) { return typeof v === 'number' && !isNaN(v); }

/** Minutes (a double) -> "7h 43m". Rounds only at render time. */
function fmtHM(min) {
  if (!isNum(min)) return '—';
  const total = Math.round(min);
  const h = Math.floor(total / 60), m = total - h * 60;
  return `${h}h ${m}m`;
}

/** A 0..1 fraction -> "96%". */
function fmtPct(frac, digits) {
  if (!isNum(frac)) return '—';
  return `${(frac * 100).toFixed(digits == null ? 0 : digits)}%`;
}

/** A plain number -> fixed-decimal string, or "—". */
function fmtNum(v, digits, unit) {
  if (!isNum(v)) return '—';
  return `${v.toFixed(digits == null ? 0 : digits)}${unit || ''}`;
}

/** An already-0..100 score -> "75%". */
function fmtScorePct(v) {
  if (!isNum(v)) return '—';
  return `${Math.round(v)}%`;
}

/** Build Intl formatters bound to the payload's named timezone (NOT the device's), with a safe
 * fallback to UTC if the tz string is somehow invalid — timestamps must read the same as the Mac app. */
function makeFormatters(tz) {
  let safeTz = tz || 'UTC';
  try { new Intl.DateTimeFormat('en-US', { timeZone: safeTz }); } catch (e) { safeTz = 'UTC'; }
  const timeFmt = new Intl.DateTimeFormat('en-US', { hour: 'numeric', minute: '2-digit', timeZone: safeTz });
  const dateFmt = new Intl.DateTimeFormat('en-US', { weekday: 'short', month: 'short', day: 'numeric', timeZone: safeTz });
  return {
    time: ts => isNum(ts) ? timeFmt.format(new Date(ts * 1000)) : '—',
    date: ts => isNum(ts) ? dateFmt.format(new Date(ts * 1000)) : '—',
  };
}

/** "YYYY-MM-DD" -> "Jul 28". Formatted as a plain calendar label (UTC-pinned parse) — the string is
 * already the local day bucket the Mac assigned, so no further timezone conversion applies. */
const DAY_LABEL_FMT = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' });
function dayLabel(dayStr) {
  if (!dayStr) return '—';
  const parts = dayStr.split('-').map(Number);
  if (parts.length !== 3 || parts.some(isNaN)) return dayStr;
  return DAY_LABEL_FMT.format(new Date(Date.UTC(parts[0], parts[1] - 1, parts[2])));
}

/** Build an ascending array of `n` consecutive calendar-day strings ending at `endDayStr`.
 * This is what makes "gaps in days are real" visible: any date in this range NOT present in the
 * source `days[]` becomes an explicit null slot in the chart, rather than silently compressing the
 * timeline so two non-adjacent nights look adjacent. */
function lastNCalendarDays(endDayStr, n) {
  const parts = endDayStr.split('-').map(Number);
  const end = new Date(Date.UTC(parts[0], parts[1] - 1, parts[2]));
  const out = [];
  for (let i = n - 1; i >= 0; i--) {
    const d = new Date(end);
    d.setUTCDate(d.getUTCDate() - i);
    const y = d.getUTCFullYear();
    const m = String(d.getUTCMonth() + 1).padStart(2, '0');
    const day = String(d.getUTCDate()).padStart(2, '0');
    out.push(`${y}-${m}-${day}`);
  }
  return out;
}

/** Recovery colour band, per spec: <34 red, 34–66 amber, >66 green. */
function recoveryBandVar(score) {
  if (!isNum(score)) return '--text-tertiary';
  if (score < 34) return '--status-critical';
  if (score <= 66) return '--status-warning';
  return '--status-positive';
}

// ---------------------------------------------------------------------------
// 4. Chart primitives
// ---------------------------------------------------------------------------

/** A minimal accessible data table — the "table view" twin every chart ships alongside it.
 * Wrapped in its own horizontally-scrolling container, so a wide table never widens the page. */
function buildDataTable(headers, rows) {
  const table = el('table', { class: 'data-table' });
  const thead = el('thead');
  thead.appendChild(el('tr', {}, headers.map(h => el('th', {}, [h]))));
  table.appendChild(thead);
  const tbody = el('tbody');
  rows.forEach(r => tbody.appendChild(el('tr', {}, r.map(c => el('td', {}, [c])))));
  table.appendChild(tbody);
  return el('div', { class: 'table-scroll' }, [table]);
}

/** Wraps a chart + its table twin with a "Show as table" toggle button. Only one is visible at once.
 * Uses `style.display` rather than the `hidden` IDL attribute: `hidden` is only defined on
 * HTMLElement, so setting it on an <svg> (an SVGElement) is a silent no-op — no attribute is
 * written and nothing is hidden. `style.display` works identically on SVG and HTML nodes. */
function withTableToggle(chartNode, tableNode, caption) {
  tableNode.style.display = 'none';
  const btn = el('button', { class: 'table-toggle', type: 'button' }, ['Show as table']);
  let showingTable = false;
  btn.addEventListener('click', () => {
    showingTable = !showingTable;
    chartNode.style.display = showingTable ? 'none' : '';
    if (caption) caption.style.display = showingTable ? 'none' : '';
    tableNode.style.display = showingTable ? '' : 'none';
    btn.textContent = showingTable ? 'Show as chart' : 'Show as table';
  });
  const wrap = el('div', { class: 'chart-wrap' }, [chartNode]);
  if (caption) wrap.appendChild(caption);
  wrap.appendChild(tableNode);
  wrap.appendChild(btn);
  return wrap;
}

/** A rounded-top / square-bottom bar path, per the mark spec (4px data-end radius, square baseline). */
function roundedTopRectPath(x, yTop, w, h, r) {
  const yBase = yTop + h;
  if (h <= 0) return '';
  const rr = Math.max(0, Math.min(r, w / 2, h));
  if (rr < 0.5) return `M${x} ${yBase} L${x} ${yTop} L${x + w} ${yTop} L${x + w} ${yBase} Z`;
  return `M${x} ${yBase} L${x} ${yTop + rr} Q${x} ${yTop} ${x + rr} ${yTop} ` +
         `L${x + w - rr} ${yTop} Q${x + w} ${yTop} ${x + w} ${yTop + rr} L${x + w} ${yBase} Z`;
}

/**
 * A single-series sparkline/line chart. `values` and `dayLabels` are parallel arrays; a null in
 * `values` breaks the line (a new SVG subpath, "M" instead of "L") rather than interpolating or
 * dropping to zero. Ends with an 8px (r=4 + 2px surface ring => r=5 drawn) marker on the last
 * present point, per the sparkline figure contract.
 */
function buildSparklineChart(values, dayLabels, colorVar, formatter) {
  const width = 320, height = 72, padX = 6, padY = 12;
  const n = values.length;
  const present = values.filter(isNum);
  // No `preserveAspectRatio="none"` / fixed `height` attribute: those force independent x/y scale
  // factors on a responsive width, which stretches circular end-dots into ellipses and skews the
  // rounded bar caps. Instead the viewBox defines an intrinsic aspect ratio and CSS (`width:100%;
  // height:auto`) scales it uniformly, so every mark spec (2px stroke, r=4 dot) stays true to shape.
  const svg = svgEl('svg', {
    viewBox: `0 0 ${width} ${height}`, role: 'img', 'aria-label': 'Trend sparkline',
  });

  if (present.length === 0) {
    const empty = el('p', { class: 'empty-state chart-empty' }, ['No data in this range.']);
    const table = buildDataTable(['Date', 'Value'], dayLabels.map(d => [dayLabel(d), '—']));
    return withTableToggle(empty, table, null);
  }

  const min = Math.min(...present), max = Math.max(...present);
  const span = (max - min) || 1;
  const xStep = n > 1 ? (width - padX * 2) / (n - 1) : 0;
  const xAt = i => padX + i * xStep;
  const yAt = v => (height - padY) - ((v - min) / span) * (height - padY * 2);

  // Gridline: recessive hairline baseline for orientation only.
  svg.appendChild(svgEl('line', {
    x1: padX, y1: height - padY, x2: width - padX, y2: height - padY,
    stroke: 'var(--chart-grid)', 'stroke-width': '1',
  }));

  let d = '';
  let open = false;
  let lastIdx = -1;
  for (let i = 0; i < n; i++) {
    const v = values[i];
    if (!isNum(v)) { open = false; continue; }
    const x = xAt(i), y = yAt(v);
    d += (open ? 'L' : 'M') + x.toFixed(2) + ' ' + y.toFixed(2) + ' ';
    open = true;
    lastIdx = i;
  }
  svg.appendChild(svgEl('path', {
    d: d.trim(), fill: 'none', stroke: `var(${colorVar})`,
    'stroke-width': '2', 'stroke-linecap': 'round', 'stroke-linejoin': 'round',
  }));

  if (lastIdx >= 0) {
    const x = xAt(lastIdx), y = yAt(values[lastIdx]);
    // 2px surface ring keeps the end-dot legible where it sits on/near the line.
    svg.appendChild(svgEl('circle', { cx: x.toFixed(2), cy: y.toFixed(2), r: '6', fill: 'var(--surface-raised)' }));
    svg.appendChild(svgEl('circle', { cx: x.toFixed(2), cy: y.toFixed(2), r: '4', fill: `var(${colorVar})` }));
  }

  const caption = el('div', { class: 'chart-caption' }, [`${dayLabel(dayLabels[0])} → ${dayLabel(dayLabels[n - 1])}`]);
  const table = buildDataTable(['Date', 'Value'], dayLabels.map((day, i) => [dayLabel(day), isNum(values[i]) ? formatter(values[i]) : '—']));
  return withTableToggle(svg, table, caption);
}

/**
 * A thin-bar column chart (nightly sleep duration). Bars are capped at 24px, rounded at the data
 * end, square at the baseline. A null value draws NO bar at all (an honest gap), never a zero-height
 * bar that would misreport "no sleep".
 */
function buildBarChart(values, dayLabels, colorVar, formatter) {
  const width = 320, height = 120, padX = 4, padTop = 6, padBottom = 18;
  const n = values.length;
  const present = values.filter(isNum);
  const max = present.length ? Math.max(...present, 1) : 1;
  const baseline = height - padBottom;
  const slot = (width - padX * 2) / n;
  const barWidth = Math.max(2, Math.min(24, slot - 2));

  // See buildSparklineChart for why there's no preserveAspectRatio/height attribute here: CSS
  // scales the viewBox uniformly so the 4px rounded bar caps stay true circles, not skewed arcs.
  const svg = svgEl('svg', {
    viewBox: `0 0 ${width} ${height}`, role: 'img', 'aria-label': 'Nightly sleep duration bar chart',
  });
  svg.appendChild(svgEl('line', { x1: padX, y1: baseline, x2: width - padX, y2: baseline, stroke: 'var(--chart-grid)', 'stroke-width': '1' }));

  values.forEach((v, i) => {
    if (!isNum(v)) return; // gap: no bar drawn, slot stays empty
    const h = (v / max) * (baseline - padTop);
    const x = padX + i * slot + (slot - barWidth) / 2;
    const yTop = baseline - h;
    const bar = svgEl('path', { d: roundedTopRectPath(x, yTop, barWidth, h, 4), fill: `var(${colorVar})` });
    const title = svgEl('title', {});
    title.textContent = `${dayLabel(dayLabels[i])}: ${formatter(v)}`;
    bar.appendChild(title);
    svg.appendChild(bar);
  });

  const caption = el('div', { class: 'chart-caption' }, [`${dayLabel(dayLabels[0])} → ${dayLabel(dayLabels[n - 1])}`]);
  const table = buildDataTable(['Date', 'Duration'], dayLabels.map((day, i) => [dayLabel(day), isNum(values[i]) ? formatter(values[i]) : '—']));
  return withTableToggle(svg, table, caption);
}

const STAGE_ORDER = ['wake', 'rem', 'light', 'deep']; // top-to-bottom band order, matches SleepStage.bandRank
const STAGE_LABEL = { wake: 'Awake', rem: 'REM', light: 'Light', deep: 'Deep' };
const STAGE_VAR = { wake: '--sleep-awake', rem: '--sleep-rem', light: '--sleep-light', deep: '--sleep-deep' };

/** Normalize a stage string to one of wake/rem/light/deep. The spec's payload shape spells the
 * awake stage "wake"; StrandDesign's own Swift `SleepStage` enum (Palette.swift) spells its case
 * `.awake` — so "awake" is a live possibility from whichever code path assembles the JSON. Map both
 * spellings together, and fold anything else unrecognized into the wake/"other" bucket rather than
 * silently dropping the segment (a dropped segment would understate the night and skew every % / gap). */
function normalizeStage(raw) {
  const s = String(raw || '').toLowerCase();
  if (s === 'rem' || s === 'light' || s === 'deep') return s;
  return 'wake'; // covers "wake", "awake", and any unrecognized value
}

/**
 * The hypnogram: a horizontal stacked timeline of stage segments, a time axis, an always-visible
 * legend (identity must never rely on hue alone), and a stage-totals table beneath it — which
 * doubles as the required table view AND as the mitigation for the deep/REM hue pair, which measures
 * below the CVD-safe floor in this palette (see the palette note in the shipping report). Deep/REM
 * additionally get a diagonal texture under forced-colors / prefers-contrast, never on by default.
 */
function buildHypnogram(night, tz) {
  const wrap = el('div', { class: 'card hypnogram-card' });
  wrap.appendChild(el('h3', { class: 'card-title' }, ['Sleep stages']));

  const stages = (night.stages || [])
    .filter(s => isNum(s.start) && isNum(s.end) && s.end > s.start)
    .map(s => ({ start: s.start, end: s.end, stage: normalizeStage(s.stage) }));
  if (!stages.length) {
    wrap.appendChild(el('p', { class: 'empty-state' }, ['No stage detail for this night.']));
    return wrap;
  }

  const start = isNum(night.effectiveStartTs) ? night.effectiveStartTs : stages[0].start;
  const end = isNum(night.endTs) ? night.endTs : stages[stages.length - 1].end;
  const totalSpan = Math.max(1, end - start);

  const track = el('div', { class: 'hyp-track' });
  const totals = { wake: 0, rem: 0, light: 0, deep: 0 };
  stages.forEach(seg => {
    const dur = Math.max(0, seg.end - seg.start);
    totals[seg.stage] = (totals[seg.stage] || 0) + dur;
    const pct = (dur / totalSpan) * 100;
    track.appendChild(el('div', {
      class: `hyp-seg hyp-${seg.stage}`,
      style: { flex: `${pct} 0 0%` },
      title: `${STAGE_LABEL[seg.stage]} · ${fmtHM(dur / 60)}`,
    }));
  });
  wrap.appendChild(track);

  const fmt = makeFormatters(tz);
  wrap.appendChild(el('div', { class: 'hypnogram-axis' }, [
    el('span', {}, [fmt.time(start)]),
    el('span', {}, [fmt.time(start + totalSpan / 2)]),
    el('span', {}, [fmt.time(end)]),
  ]));

  const legend = el('div', { class: 'hyp-legend' });
  STAGE_ORDER.forEach(stage => {
    legend.appendChild(el('span', { class: 'legend-item' }, [
      el('span', { class: `legend-swatch hyp-${stage}` }),
      el('span', { class: 'legend-label' }, [STAGE_LABEL[stage]]),
    ]));
  });
  wrap.appendChild(legend);

  const totalSec = STAGE_ORDER.reduce((a, s) => a + (totals[s] || 0), 0) || 1;
  const rows = STAGE_ORDER.map(stage => {
    const min = (totals[stage] || 0) / 60;
    const pct = (totals[stage] || 0) / totalSec * 100;
    return [STAGE_LABEL[stage], fmtHM(min), `${pct.toFixed(0)}%`];
  });
  const table = el('table', { class: 'stage-table' });
  const tbody = el('tbody');
  rows.forEach((r, i) => {
    const stage = STAGE_ORDER[i];
    tbody.appendChild(el('tr', {}, [
      el('td', { class: 'stage-name' }, [el('span', { class: `legend-swatch hyp-${stage}` }), r[0]]),
      el('td', {}, [r[1]]),
      el('td', {}, [r[2]]),
    ]));
  });
  table.appendChild(tbody);
  wrap.appendChild(table);

  return wrap;
}

// ---------------------------------------------------------------------------
// 5. Screen renderers
// ---------------------------------------------------------------------------

function statTile(label, value, colorVar) {
  const tile = el('div', { class: 'tile' });
  tile.appendChild(el('div', { class: 'tile-label' }, [label]));
  const valueEl = el('div', { class: 'tile-value' }, [value]);
  if (colorVar) valueEl.style.color = `var(${colorVar})`;
  tile.appendChild(valueEl);
  return tile;
}

const WINDOW_DAYS = 21;
const SYNC_GRACE_S = 30 * 60;

/** "YYYY-MM-DD" of a unix ts in the payload's timezone (matches the Mac's local-day bucketing). */
function localDayOf(ts, tz) {
  let safe = tz || 'UTC';
  try { new Intl.DateTimeFormat('en-US', { timeZone: safe }); } catch (e) { safe = 'UTC'; }
  return new Intl.DateTimeFormat('en-CA', { year: 'numeric', month: '2-digit', day: '2-digit', timeZone: safe })
    .format(new Date(ts * 1000));
}

/** "Data through <date time>" — dataMaxTs is the offload frontier (newest motion sample). */
function dataThroughLine(payload) {
  const fmt = makeFormatters(payload.tz);
  return el('div', { class: 'data-through' }, [
    isNum(payload.dataMaxTs) ? `Data through ${fmt.date(payload.dataMaxTs)} ${fmt.time(payload.dataMaxTs)}` : 'Data through —',
  ]);
}

function renderSleep(payload) {
  const panel = $('panel-sleep');
  clearNode(panel);
  panel.appendChild(dataThroughLine(payload));
  const sleeps = payload.sleeps || [];
  const night = sleeps.length ? sleeps[sleeps.length - 1] : null;
  const days = payload.days || [];

  if (!night) {
    panel.appendChild(el('p', { class: 'empty-state' }, ['No sleep recorded yet.']));
  } else {
    const fmt = makeFormatters(payload.tz);
    const header = el('div', { class: 'night-header' });
    header.appendChild(el('div', { class: 'night-times' }, [
      el('span', { class: 'night-time' }, [fmt.time(night.effectiveStartTs)]),
      el('span', { class: 'night-arrow' }, [' → ']),
      el('span', { class: 'night-time' }, [fmt.time(night.endTs)]),
    ]));
    if (night.userEdited) header.appendChild(el('span', { class: 'chip chip-edited' }, ['edited']));
    // Provisional night: the offload frontier has not yet passed this night's end + 30 min, so the
    // night may be half-offloaded (a short night is usually the frontier, not a wake).
    if (isNum(payload.dataMaxTs) && payload.dataMaxTs < night.endTs + SYNC_GRACE_S) {
      header.appendChild(el('span', { class: 'chip chip-syncing' }, ['still syncing']));
    }
    panel.appendChild(header);

    // Sleep performance is the dailyMetric/metricSeries figure for the night's wake day (never
    // derived from the session); fall back to the newest day that has one.
    const wakeDay = localDayOf(night.endTs, payload.tz);
    let perfDay = days.find(d => d.day === wakeDay);
    if (!perfDay || !isNum(perfDay.sleepPerformance)) {
      perfDay = days.slice().reverse().find(d => isNum(d.sleepPerformance)) || perfDay || null;
    }
    const perf = perfDay ? perfDay.sleepPerformance : null;
    panel.appendChild(el('div', { class: 'headline-tile' }, [
      el('div', { class: 'tile-label' }, ['Sleep performance']),
      el('div', { class: 'headline-value' }, [fmtScorePct(perf)]),
    ]));

    const inBedMin = isNum(night.effectiveStartTs) && isNum(night.endTs)
      ? (night.endTs - night.effectiveStartTs) / 60 : null;
    const stageSegs = Array.isArray(night.stages) ? night.stages : [];
    const asleepMin = stageSegs.length
      ? stageSegs.reduce((t, s) => t + (s.stage === 'wake' ? 0 : (s.end - s.start)), 0) / 60
      : null;
    const stats = el('div', { class: 'tile-grid' });
    stats.appendChild(statTile('Asleep', fmtHM(asleepMin)));
    stats.appendChild(statTile('Time in bed', fmtHM(inBedMin)));
    panel.appendChild(stats);

    panel.appendChild(buildHypnogram(night, payload.tz));
  }

  // 21-day history
  if (!days.length) return;
  const endDay = days[days.length - 1].day;
  const gridDays = lastNCalendarDays(endDay, WINDOW_DAYS);
  const byDay = new Map(days.map(d => [d.day, d]));
  const grid = gridDays.map(day => byDay.get(day) || null);

  const chartCard = el('div', { class: 'card' });
  chartCard.appendChild(el('h3', { class: 'card-title' }, ['Nightly sleep duration']));
  chartCard.appendChild(buildBarChart(grid.map(d => d ? d.totalSleepMin : null), gridDays, '--rest-color', fmtHM));
  panel.appendChild(chartCard);

  const list = el('div', { class: 'night-list' });
  for (let i = grid.length - 1; i >= 0; i--) {
    const d = grid[i];
    const row = el('div', { class: 'night-row' });
    row.appendChild(el('div', { class: 'night-row-date' }, [dayLabel(gridDays[i])]));
    if (!d || !isNum(d.totalSleepMin)) {
      row.appendChild(el('div', { class: 'night-row-empty' }, ['No data']));
    } else {
      row.appendChild(el('div', { class: 'night-row-detail' }, [
        el('span', {}, [fmtHM(d.totalSleepMin)]),
        el('span', { class: 'dim' }, [' · ']),
        el('span', {}, [`Deep ${fmtHM(d.deepMin)}`]),
        el('span', { class: 'dim' }, [' / ']),
        el('span', {}, [`REM ${fmtHM(d.remMin)}`]),
        el('span', { class: 'dim' }, [' · ']),
        el('span', {}, [fmtPct(d.efficiency)]),
      ]));
    }
    list.appendChild(row);
  }
  panel.appendChild(list);
}

/**
 * Heart-rate-over-time line for one workout. `trace` is integer-mean bpm per `stepS` bucket from
 * the workout start; a null bucket breaks the line (gap), never a zero. Ships with a per-minute
 * table twin behind the usual toggle.
 */
function buildHrTraceChart(trace, stepS, colorVar) {
  const width = 320, height = 150, padL = 30, padR = 6, padT = 10, padB = 20;
  const present = trace.filter(isNum);
  const lo = Math.min(...present), hi = Math.max(...present);
  const yMin = Math.floor((lo - 3) / 5) * 5, yMax = Math.ceil((hi + 3) / 5) * 5;
  const span = (yMax - yMin) || 1;
  const n = trace.length;
  const xAt = i => padL + (n > 1 ? i / (n - 1) : 0) * (width - padL - padR);
  const yAt = v => (height - padB) - ((v - yMin) / span) * (height - padB - padT);
  const svg = svgEl('svg', { viewBox: `0 0 ${width} ${height}`, role: 'img', 'aria-label': 'Heart rate over the workout' });

  [yMin, (yMin + yMax) / 2, yMax].forEach(v => {
    svg.appendChild(svgEl('line', { x1: padL, y1: yAt(v), x2: width - padR, y2: yAt(v), stroke: 'var(--chart-grid)', 'stroke-width': '1' }));
    const t = svgEl('text', { x: padL - 4, y: yAt(v) + 3, 'text-anchor': 'end', 'font-size': '9', fill: 'var(--chart-axis)' });
    t.textContent = String(Math.round(v));
    svg.appendChild(t);
  });
  let d = '', open = false;
  trace.forEach((v, i) => {
    if (!isNum(v)) { open = false; return; }
    d += (open ? 'L' : 'M') + xAt(i).toFixed(1) + ' ' + yAt(v).toFixed(1) + ' ';
    open = true;
  });
  svg.appendChild(svgEl('path', { d: d.trim(), fill: 'none', stroke: `var(${colorVar})`, 'stroke-width': '2', 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }));
  const totalMin = Math.round(n * stepS / 60);
  [[padL, 'start', '0 min'], [width - padR, 'end', `${totalMin} min`]].forEach(([x, anchor, label]) => {
    const t = svgEl('text', { x, y: height - 5, 'text-anchor': anchor, 'font-size': '9', fill: 'var(--chart-axis)' });
    t.textContent = label;
    svg.appendChild(t);
  });

  // Table twin: one row per minute (mean of that minute's present buckets).
  const per = Math.max(1, Math.round(60 / stepS));
  const rows = [];
  for (let i = 0; i < n; i += per) {
    const vals = trace.slice(i, i + per).filter(isNum);
    rows.push([`${Math.round(i * stepS / 60)} min`,
      vals.length ? `${Math.round(vals.reduce((a, b) => a + b, 0) / vals.length)} bpm` : '—']);
  }
  const caption = el('div', { class: 'chart-caption' }, ['Heart rate (bpm) over elapsed time']);
  return withTableToggle(svg, buildDataTable(['Elapsed', 'Avg HR'], rows), caption);
}

let currentWorkoutKey = null;   // set while a workout's detail view is open

function renderWorkouts(payload) {
  const panel = $('panel-workouts');
  clearNode(panel);
  currentWorkoutKey = null;
  panel.appendChild(dataThroughLine(payload));
  const workouts = effectiveWorkouts().sort((a, b) => (b.startTs || 0) - (a.startTs || 0));
  if (!workouts.length) { panel.appendChild(el('p', { class: 'empty-state' }, ['No workouts recorded.'])); return; }

  const fmt = makeFormatters(payload.tz);
  const list = el('div', { class: 'workout-list' });
  // Recent (21-day window) workouts first; the long imported history sits behind a button so the
  // list stays short and the page light.
  const cutoff = isNum(payload.dataMaxTs) ? payload.dataMaxTs - WINDOW_DAYS * 86400 : 0;
  const recent = workouts.filter(w => w.endTs >= cutoff);
  const older = workouts.filter(w => w.endTs < cutoff);
  const addRow = w => {
    // A <button>, so the whole row is keyboard- and screen-reader-operable.
    const row = el('button', { class: 'workout-row', type: 'button' });
    row.addEventListener('click', () => renderWorkoutDetail(payload, w));
    row.appendChild(el('div', { class: 'workout-top' }, [
      el('span', { class: 'workout-date' }, [fmt.date(w.startTs)]),
      el('span', { class: 'workout-time' }, [fmt.time(w.startTs)]),
    ]));
    // `displaySport`, never the raw `sport` (the app's WorkoutSource.displaySport rule).
    const mid = el('div', { class: 'workout-mid' }, [
      el('span', { class: 'workout-sport' }, [w.displaySport || w.sport || 'Workout']),
    ]);
    if (w.hrReconciled) mid.appendChild(el('span', { class: 'chip chip-hr' }, ['HR from strap trace']));
    if (w.edited) mid.appendChild(el('span', { class: 'chip chip-edited' }, ['edited']));
    if (w.pendingEdit) mid.appendChild(el('span', { class: 'chip chip-pending' }, ['pending']));
    row.appendChild(mid);
    const durMin = isNum(w.durationS) ? w.durationS / 60 : null;
    row.appendChild(el('div', { class: 'workout-stats' }, [
      el('span', {}, [`Duration ${fmtHM(durMin)}`]),
      el('span', {}, [`Avg HR ${isNum(w.avgHr) ? Math.round(w.avgHr) + ' bpm' : '—'}`]),
      el('span', {}, [`Max HR ${isNum(w.maxHr) ? Math.round(w.maxHr) + ' bpm' : '—'}`]),
    ]));
    list.appendChild(row);
  };
  recent.forEach(addRow);
  if (!recent.length) list.appendChild(el('p', { class: 'empty-state' }, ['No workouts in the last 21 days.']));
  if (older.length) {
    const more = el('button', { class: 'table-toggle', type: 'button' }, [`Show ${older.length} older workouts`]);
    more.addEventListener('click', () => { older.forEach(addRow); more.remove(); });
    list.appendChild(more);
  }
  panel.appendChild(list);
}

function renderWorkoutDetail(payload, w, editing) {
  const panel = $('panel-workouts');
  clearNode(panel);
  currentWorkoutKey = origKeyOf(w);
  const fmt = makeFormatters(payload.tz);
  const back = el('button', { class: 'back-btn', type: 'button' }, ['‹ Workouts']);
  back.addEventListener('click', () => { renderWorkouts(payload); window.scrollTo(0, 0); });
  panel.appendChild(back);
  panel.appendChild(dataThroughLine(payload));

  const title = el('h2', { class: 'detail-title', tabindex: '-1' }, [w.displaySport || w.sport || 'Workout']);
  panel.appendChild(title);
  if (w.edited || w.pendingEdit) {
    const chips = el('div', { class: 'detail-chips' });
    if (w.edited) chips.appendChild(el('span', { class: 'chip chip-edited' }, ['edited']));
    if (w.pendingEdit) chips.appendChild(el('span', { class: 'chip chip-pending' }, ['pending']));
    panel.appendChild(chips);
  }
  panel.appendChild(el('div', { class: 'section-date' }, [`${fmt.date(w.startTs)} · ${fmt.time(w.startTs)} → ${fmt.time(w.endTs)}`]));

  const durMin = isNum(w.durationS) ? w.durationS / 60 : null;
  const grid = el('div', { class: 'tile-grid' });
  grid.appendChild(statTile('Duration', fmtHM(durMin)));
  grid.appendChild(statTile('Energy', isNum(w.energyKcal) ? `${Math.round(w.energyKcal)} kcal` : '—'));
  grid.appendChild(statTile('Avg HR', isNum(w.avgHr) ? `${Math.round(w.avgHr)} bpm` : '—'));
  grid.appendChild(statTile('Max HR', isNum(w.maxHr) ? `${Math.round(w.maxHr)} bpm` : '—'));
  panel.appendChild(grid);

  const card = el('div', { class: 'card' });
  card.appendChild(el('h3', { class: 'card-title' }, ['Heart rate']));
  const trace = Array.isArray(w.hrTrace) ? w.hrTrace : null;
  if (trace && trace.some(isNum)) {
    card.appendChild(buildHrTraceChart(trace, 5, '--status-critical'));
  } else {
    card.appendChild(el('p', { class: 'empty-state' }, [w.spanPending
      ? 'Heart rate and energy for the new times update after the Mac’s next publish.'
      : 'No heart-rate trace for this workout (only the last 21 days carry one).']));
  }
  panel.appendChild(card);

  if (inboxKeys) {
    if (editing) {
      panel.appendChild(buildWorkoutEditor(payload, w, changed => {
        if (!changed) { renderWorkoutDetail(payload, w, false); return; }
        const fresh = effectiveWorkouts().find(x => origKeyOf(x) === origKeyOf(w));
        if (fresh) renderWorkoutDetail(payload, fresh, false); else renderWorkouts(payload);
      }));
    } else {
      const edit = el('button', { class: 'btn-quiet', type: 'button', id: 'editWorkoutBtn' }, ['Edit workout']);
      edit.addEventListener('click', () => renderWorkoutDetail(payload, w, true));
      panel.appendChild(edit);
    }
  }
  window.scrollTo(0, 0);
  title.focus();
}

const TREND_METRICS = [
  { key: 'avgHrv', label: 'HRV', colorVar: '--metric-cyan', formatter: v => `${v.toFixed(1)} ms` },
  { key: 'restingHr', label: 'Resting HR', colorVar: '--metric-restinghr', formatter: v => `${Math.round(v)} bpm` },
  { key: 'meanHr', label: 'Whole-day mean HR', colorVar: '--rest-color', formatter: v => `${Math.round(v)} bpm` },
];

function renderTrends(payload) {
  const panel = $('panel-trends');
  clearNode(panel);
  panel.appendChild(dataThroughLine(payload));
  const days = payload.days || [];
  if (!days.length) { panel.appendChild(el('p', { class: 'empty-state' }, ['No trend data yet.'])); return; }

  const endDay = days[days.length - 1].day;
  const gridDays = lastNCalendarDays(endDay, WINDOW_DAYS);
  const byDay = new Map(days.map(d => [d.day, d]));

  TREND_METRICS.forEach(m => {
    const values = gridDays.map(day => {
      const d = byDay.get(day);
      if (!d) return null;
      const v = d[m.key];
      return isNum(v) ? v : null;
    });
    let latest = null;
    for (let i = values.length - 1; i >= 0; i--) { if (isNum(values[i])) { latest = values[i]; break; } }

    const card = el('div', { class: 'card' });
    const head = el('div', { class: 'sparkline-head' });
    head.appendChild(el('h3', { class: 'card-title' }, [m.label]));
    head.appendChild(el('div', { class: 'sparkline-value' }, [latest == null ? '—' : m.formatter(latest)]));
    card.appendChild(head);
    card.appendChild(buildSparklineChart(values, gridDays, m.colorVar, m.formatter));
    panel.appendChild(card);
  });
}

// ---------------------------------------------------------------------------
// 5b. Write-back: inbox keys, sealed entry queue, day/time helpers
//
// Contract shared byte for byte with the Mac (Sources/noop-publish/Crypto.swift, InboxCrypto) and the
// receiver (receiver/noop_inbox.py):
//   master    = PBKDF2-HMAC-SHA256(utf8(passphrase), salt "noop-phone-inbox-v1", 600000, 32 bytes)
//   authToken = hex(HMAC-SHA256(master, "inbox-auth"))
//   entryKey  = HMAC-SHA256(master, "entry-enc")                    (AES-256-GCM)
//   payloadKey= HMAC-SHA256(master, "noop-payload-v2:" + envelope saltB64)  (v2 payloads, section 2)
//   entry     = AES-GCM(entryKey, random 12-byte nonce, AAD "noop-inbox-v1:" + id); body = ct || tag
// Every tap is sealed immediately and ONLY the sealed envelope is queued in localStorage, so no
// plaintext answer or workout edit ever sits in browser storage.
// ---------------------------------------------------------------------------

const INBOX_SALT = 'noop-phone-inbox-v1';
const INBOX_ITERATIONS = 600000;
const INBOX_QUEUE_KEY = 'noopInboxQueue_v1';

function hexFromBytes(bytes) {
  return Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
}

/** The passphrase root, returned ONLY as a non-extractable HMAC CryptoKey; the raw bytes are zeroed.
 * The salt and iteration count are constants here, never read from the envelope: this root also
 * produces the server auth token, so a tampered envelope must not be able to weaken it. */
async function deriveMasterKey(passphrase) {
  const base = await crypto.subtle.importKey('raw', utf8(passphrase), 'PBKDF2', false, ['deriveBits']);
  const raw = new Uint8Array(await crypto.subtle.deriveBits(
    { name: 'PBKDF2', salt: utf8(INBOX_SALT), iterations: INBOX_ITERATIONS, hash: 'SHA-256' }, base, 256));
  try {
    return await crypto.subtle.importKey('raw', raw, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  } finally { raw.fill(0); }
}

async function inboxKeysFromMaster(masterKey) {
  const mac = async label => new Uint8Array(await crypto.subtle.sign('HMAC', masterKey, utf8(label)));
  const token = hexFromBytes(await mac('inbox-auth'));
  const entryKey = await crypto.subtle.importKey('raw', await mac('entry-enc'), { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']);
  return { token, entryKey };
}

function entryAad(id) { return utf8('noop-inbox-v1:' + id); }

async function sealEntry(entry, keys) {
  const id = crypto.randomUUID();
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv, additionalData: entryAad(id), tagLength: 128 }, keys.entryKey, utf8(JSON.stringify(entry))));
  return { id, nonceB64: b64FromBytes(iv), ciphertextB64: b64FromBytes(ct) };
}

async function openEntry(env, keys) {
  const pt = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: bytesFromB64(env.nonceB64), additionalData: entryAad(env.id), tagLength: 128 },
    keys.entryKey, bytesFromB64(env.ciphertextB64));
  return JSON.parse(new TextDecoder().decode(pt));
}


function loadQueue() {
  try { const a = JSON.parse(localStorage.getItem(INBOX_QUEUE_KEY) || '[]'); return Array.isArray(a) ? a : []; }
  catch (e) { return []; }
}
function saveQueue(q) {
  try { localStorage.setItem(INBOX_QUEUE_KEY, JSON.stringify(q)); } catch (e) { /* storage unavailable */ }
}

// Unlocked state. `pending` = decoded view of the queued envelopes that the Mac has not yet confirmed
// (their id is not in payload.ingestedEntryIds): [{ id, state: 'unsent'|'sent', entry }].
let inboxKeys = null;
let pending = [];
let flushing = false;
let lastEnteredAt = 0;
let inboxNote = '';

function nextEnteredAt() {
  // Whole seconds, strictly increasing: Yes-then-clear inside one second must not tie.
  lastEnteredAt = Math.max(Math.floor(Date.now() / 1000), lastEnteredAt + 1);
  return lastEnteredAt;
}

/** After unlock: drop everything the Mac has ingested, decrypt the rest for display, then try to send. */
async function initInbox(keys, ingestedIds) {
  inboxKeys = keys;
  const ingested = new Set(ingestedIds || []);
  const queue = loadQueue().filter(q => q && q.id && !ingested.has(q.id));
  const kept = [];
  pending = [];
  for (const q of queue) {
    try {
      const entry = await openEntry(q, keys);
      kept.push(q);
      pending.push({ id: q.id, state: q.state === 'sent' ? 'sent' : 'unsent', entry });
      if (isNum(entry.enteredAt)) lastEnteredAt = Math.max(lastEnteredAt, entry.enteredAt);
    } catch (e) { /* sealed under another passphrase: the Mac would reject it too — drop */ }
  }
  saveQueue(kept);
  flushQueue();
}

async function enqueueEntry(entry) {
  entry.enteredAt = nextEnteredAt();
  const env = await sealEntry(entry, inboxKeys);
  const queue = loadQueue();
  queue.push({ id: env.id, nonceB64: env.nonceB64, ciphertextB64: env.ciphertextB64, state: 'unsent', createdS: entry.enteredAt });
  saveQueue(queue);
  pending.push({ id: env.id, state: 'unsent', entry });
  refreshInboxViews();
  flushQueue();
}

function setQueueState(id, state) {
  const queue = loadQueue();
  const q = queue.find(x => x.id === id);
  if (q) { q.state = state; saveQueue(queue); }
  const p = pending.find(x => x.id === id);
  if (p) p.state = state;
}

function dropQueued(id) {
  saveQueue(loadQueue().filter(x => x.id !== id));
  pending = pending.filter(x => x.id !== id);
}

/** POST every unsent entry to the same-origin receiver. "sent" entries are NEVER re-posted: the Mac
 * deletes them from the server once ingested, and a re-POST would recreate the file. */
async function flushQueue() {
  if (flushing || !inboxKeys) return;
  flushing = true;
  try {
    for (const q of loadQueue().filter(x => x.state !== 'sent')) {
      let resp;
      try {
        resp = await fetch('/inbox', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + inboxKeys.token },
          body: JSON.stringify({ v: 1, id: q.id, nonceB64: q.nonceB64, ciphertextB64: q.ciphertextB64 }),
        });
      } catch (e) { inboxNote = 'Offline — will send when connected.'; break; }
      if (resp.status === 200 || resp.status === 201) { setQueueState(q.id, 'sent'); inboxNote = ''; }
      else if (resp.status === 400 || resp.status === 413) { dropQueued(q.id); inboxNote = 'An entry was refused and discarded.'; }
      else if (resp.status === 401) { inboxNote = 'The server did not accept this passphrase.'; break; }
      else { inboxNote = 'Server busy — will retry.'; break; }
    }
  } finally {
    flushing = false;
    refreshInboxViews();
  }
}

window.addEventListener('online', () => { flushQueue(); });
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') flushQueue(); });

function refreshInboxViews() {
  if (!payload) return;
  renderLifestyle(payload);
  // Keep the workout view in step (pending chips), unless the user is mid-edit in the detail view.
  if (!currentWorkoutKey) renderWorkouts(payload);
}

// --- day helpers (the payload's timezone, never the device's) --------------

function addDays(dayStr, n) {
  const p = dayStr.split('-').map(Number);
  const d = new Date(Date.UTC(p[0], p[1] - 1, p[2] + n));
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`;
}
const LONG_DAY_FMT = new Intl.DateTimeFormat('en-US', { weekday: 'short', month: 'short', day: 'numeric', timeZone: 'UTC' });
function longDayLabel(dayStr) {
  const p = dayStr.split('-').map(Number);
  return LONG_DAY_FMT.format(new Date(Date.UTC(p[0], p[1] - 1, p[2])));
}

function safeTz(tz) {
  let t = tz || 'UTC';
  try { new Intl.DateTimeFormat('en-US', { timeZone: t }); } catch (e) { t = 'UTC'; }
  return t;
}
function tzFields(ts, tz) {
  const f = new Intl.DateTimeFormat('en-CA', { timeZone: safeTz(tz), hourCycle: 'h23', year: 'numeric', month: '2-digit',
    day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' });
  const o = {};
  f.formatToParts(new Date(ts * 1000)).forEach(p => { if (p.type !== 'literal') o[p.type] = Number(p.value); });
  return o;
}
function localAsUtc(ts, tz) {
  const o = tzFields(ts, tz);
  return Date.UTC(o.year, o.month - 1, o.day, o.hour, o.minute, o.second) / 1000;
}
/** unix ts -> "YYYY-MM-DDTHH:mm" in `tz` (a <input type=datetime-local> value). */
function tsToInput(ts, tz) {
  const o = tzFields(ts, tz);
  const z = n => String(n).padStart(2, '0');
  return `${o.year}-${z(o.month)}-${z(o.day)}T${z(o.hour)}:${z(o.minute)}`;
}
/** "YYYY-MM-DDTHH:mm" read as wall-clock time in `tz` -> unix ts (null if unparseable). */
function inputToTs(str, tz) {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(str || '');
  if (!m) return null;
  const asUtc = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]) / 1000;
  let ts = asUtc;
  for (let i = 0; i < 3; i++) ts = asUtc - (localAsUtc(ts, tz) - ts);
  return ts;
}

// --- merged views: payload + unconfirmed local entries ----------------------

/** {day:{item:bool}} from the payload, overlaid with unconfirmed local check-ins in enteredAt order. */
function effectiveAnswers() {
  const out = {};
  const base = (payload.lifestyle && payload.lifestyle.answers) || {};
  Object.keys(base).forEach(d => { out[d] = Object.assign({}, base[d]); });
  pending.filter(p => p.entry.kind === 'checkin').sort((a, b) => a.entry.enteredAt - b.entry.enteredAt).forEach(p => {
    const e = p.entry;
    out[e.day] = out[e.day] || {};
    if (e.value === true || e.value === false) out[e.day][e.item] = e.value; else delete out[e.day][e.item];
  });
  return out;
}
function pendingItem(day, item) {
  return pending.some(p => p.entry.kind === 'checkin' && p.entry.day === day && p.entry.item === item);
}

function origKeyOf(w) {
  const o = w.orig || { startTs: w.startTs, endTs: w.endTs, sport: w.sport };
  return `${o.startTs}|${o.endTs}|${o.sport}`;
}
function displaySportOf(sport) {
  if (sport === 'detected') return 'Activity';
  if (!sport || sport.indexOf(' ') >= 0) return sport || 'Workout';
  return sport.replace(/([a-z])([A-Z])/g, '$1 $2');
}

/** Workouts with unconfirmed local edits applied (newest entry per original span wins). */
function effectiveWorkouts() {
  const latest = new Map();
  pending.filter(p => p.entry.kind === 'workoutOverride').sort((a, b) => a.entry.enteredAt - b.entry.enteredAt)
    .forEach(p => { latest.set(`${p.entry.orig.startTs}|${p.entry.orig.endTs}|${p.entry.orig.sport}`, p.entry); });
  const out = [];
  (payload.workouts || []).forEach(w => {
    const ov = latest.get(origKeyOf(w));
    if (!ov) { out.push(w); return; }
    if (ov.deleted) return;
    const c = Object.assign({}, w, { pendingEdit: true });
    if (!c.orig) c.orig = { startTs: w.startTs, endTs: w.endTs, sport: w.sport };
    if (ov.sport) { c.sport = ov.sport; c.displaySport = displaySportOf(ov.sport); }
    if (isNum(ov.startTs) && isNum(ov.endTs) && (ov.startTs !== w.startTs || ov.endTs !== w.endTs)) {
      c.startTs = ov.startTs; c.endTs = ov.endTs; c.durationS = ov.endTs - ov.startTs;
      // Stats and the trace describe the OLD span; the Mac recomputes them from the strap's samples.
      c.avgHr = null; c.maxHr = null; c.energyKcal = null; c.hrTrace = null; c.spanPending = true;
    }
    out.push(c);
  });
  return out;
}

let lifestyleMode = 'yesterday';   // 'yesterday' (default) | 'tonight'

function inboxUnavailableCard() {
  const c = el('div', { class: 'card' });
  c.appendChild(el('p', { class: 'empty-state' }, ['Answers can’t be filed from this session. Sign in again with your passphrase.']));
  const b = el('button', { class: 'table-toggle', type: 'button' }, ['Sign in again']);
  b.addEventListener('click', async () => { await clearDeviceKey(); location.reload(); });
  c.appendChild(b);
  return c;
}

function renderLifestyle(payload) {
  const panel = $('panel-lifestyle');
  clearNode(panel);
  panel.appendChild(dataThroughLine(payload));
  const life = payload.lifestyle || { items: [], answers: {} };

  // "Yesterday" files under TODAY's morning (about the night + day before it); "Tonight" is about today
  // and files under TOMORROW's morning — the same attribution NOOP's own journal uses.
  const today = localDayOf(Date.now() / 1000, payload.tz);
  const filed = lifestyleMode === 'yesterday' ? today : addDays(today, 1);
  const about = addDays(filed, -1);

  const card = el('div', { class: 'card' });
  card.appendChild(el('h3', { class: 'card-title' }, ['Checklist']));
  const seg = el('div', { class: 'seg seg-wide', role: 'group', 'aria-label': 'Which day' });
  [['yesterday', 'Yesterday'], ['tonight', 'Tonight']].forEach(([mode, label]) => {
    const b = el('button', { class: 'seg-btn', type: 'button', 'aria-pressed': lifestyleMode === mode ? 'true' : 'false', 'data-mode': mode }, [label]);
    b.addEventListener('click', () => { lifestyleMode = mode; renderLifestyle(payload); });
    seg.appendChild(b);
  });
  card.appendChild(seg);
  card.appendChild(el('div', { class: 'checklist-day', id: 'checklistDay' }, [`About ${longDayLabel(about)} · filed under ${longDayLabel(filed)}`]));

  const nPending = pending.length;
  if (nPending) {
    const unsent = pending.filter(p => p.state === 'unsent').length;
    card.appendChild(el('div', { class: 'checklist-status', id: 'pendingSummary' }, [
      el('span', { class: 'chip chip-pending' }, [`${nPending} pending`]),
      ` ${unsent ? unsent + ' waiting to send' : 'sent — waiting for the Mac'}`,
    ]));
  }
  if (inboxNote) card.appendChild(el('div', { class: 'checklist-note' }, [inboxNote]));

  if (!inboxKeys) {
    panel.appendChild(card);
    panel.appendChild(inboxUnavailableCard());
    renderEffectsPlaceholder(panel);
    return;
  }

  const items = life.items || [];
  if (!items.length) {
    card.appendChild(el('p', { class: 'empty-state' }, ['No checklist items are set up on the Mac yet.']));
  }
  const answers = effectiveAnswers();
  const answered = (answers[filed] || {});
  const list = el('div', { class: 'checklist' });
  items.forEach(it => {
    const cur = answered[it.id];
    const row = el('div', { class: 'check-row', 'data-item': it.id });
    const label = el('div', { class: 'check-label' }, [it.label]);
    if (pendingItem(filed, it.id)) label.appendChild(el('span', { class: 'chip chip-pending', 'data-pending': it.id }, ['pending']));
    row.appendChild(label);
    const ctl = el('div', { class: 'seg', role: 'group', 'aria-label': it.label });
    const mk = (text, val) => {
      const pressed = cur === val;
      const b = el('button', { class: 'seg-btn', type: 'button', 'aria-pressed': pressed ? 'true' : 'false',
        'data-answer': val === true ? 'yes' : 'no' }, [text]);
      // Tapping the active answer again clears it (value: null).
      b.addEventListener('click', () => enqueueEntry({ v: 1, kind: 'checkin', day: filed, item: it.id, value: pressed ? null : val }));
      return b;
    };
    ctl.appendChild(mk('Yes', true));
    ctl.appendChild(mk('No', false));
    if (cur === true || cur === false) {
      const clr = el('button', { class: 'seg-btn seg-clear', type: 'button', 'data-answer': 'clear', 'aria-label': `Clear ${it.label}` }, ['Clear']);
      clr.addEventListener('click', () => enqueueEntry({ v: 1, kind: 'checkin', day: filed, item: it.id, value: null }));
      ctl.appendChild(clr);
    }
    row.appendChild(ctl);
    list.appendChild(row);
  });
  card.appendChild(list);
  card.appendChild(el('p', { class: 'checklist-hint' }, ['Unanswered stays blank — it is never counted as “no”.']));
  panel.appendChild(card);
  renderEffects(panel, payload);
}

// Effects: NOOP's own EffectRanker math (computed on the Mac over ALL history, answered days only).
// Wording is deliberately "lined up with", never "caused": ~30 logged days × 17 items × 3 outcomes × 3
// lags is ~150 comparisons, so a handful clear p < 0.05 by chance. Effect size + day counts lead.
function effectSizeWord(d) {
  const a = Math.abs(d);
  return a < 0.2 ? 'negligible' : a < 0.5 ? 'small' : a < 0.8 ? 'medium' : 'large';
}
function lagWord(lag) {
  return lag === 0 ? 'that night' : lag === 1 ? '1 night later' : `${lag} nights later`;
}
function renderEffects(panel, payload) {
  const card = el('div', { class: 'card' });
  card.appendChild(el('h3', { class: 'card-title' }, ['Effects']));
  const L = (payload && payload.lifestyle) || {};
  const effects = Array.isArray(L.effects) ? L.effects : [];
  const items = Array.isArray(L.items) ? L.items : [];
  if (!effects.length) {
    card.appendChild(el('p', { class: 'empty-state' }, ['No effects yet — they appear once an item has at least 5 “yes” and 5 “no” days.']));
    panel.appendChild(card);
    return;
  }
  card.appendChild(el('p', { class: 'checklist-hint' }, [
    'Averages on days you answered yes vs no, using all your history. These show what lined up, not what caused it — with this many comparisons a few will look real by chance. Trust large effects with many days.'
  ]));
  const units = { sleepPerformance: '%', hrv: ' ms', restingHr: ' bpm' };
  const thin = [];
  items.forEach((it) => {
    const rows = effects.filter((e) => e.item === it.id);
    const ok = rows.filter((e) => e.status === 'ok').sort((a, b) => Math.abs(b.cohensD) - Math.abs(a.cohensD));
    if (!ok.length) {
      const best = rows.reduce((m, e) => (Math.min(e.nWith || 0, e.nWithout || 0) > Math.min(m.nWith || 0, m.nWithout || 0) ? e : m), rows[0] || {});
      thin.push(`${it.label} (${best.nWith || 0} yes / ${best.nWithout || 0} no)`);
      return;
    }
    const group = el('div', { class: 'effect-item' });
    group.appendChild(el('div', { class: 'effect-item-label' }, [it.label]));
    ok.forEach((e) => {
      const u = units[e.outcome] || '';
      const sign = e.delta > 0 ? '+' : e.delta < 0 ? '−' : '±';
      const row = el('div', { class: 'effect-row' }, [
        el('span', { class: 'effect-outcome' }, [`${e.outcomeLabel}, ${lagWord(e.lag)}`]),
        el('span', { class: 'effect-value' }, [`${e.meanWith}${u} vs ${e.meanWithout}${u} (${sign}${Math.abs(e.delta)})`]),
      ]);
      group.appendChild(row);
      group.appendChild(el('div', { class: 'effect-meta' }, [
        `${effectSizeWord(e.cohensD)} effect · ${e.nWith} yes vs ${e.nWithout} no days`
      ]));
    });
    card.appendChild(group);
  });
  if (thin.length) {
    card.appendChild(el('p', { class: 'checklist-hint' }, [`Not enough answered days yet (needs 5 yes and 5 no): ${thin.join(', ')}.`]));
  }
  panel.appendChild(card);
}

// --- workout edit -------------------------------------------------------------

const SPORT_CHOICES = ['Running', 'Cycling', 'Walking', 'Hiking', 'Swimming', 'Rowing', 'Yoga', 'CrossFit', 'CrossTraining',
  'FunctionalStrengthTraining', 'TraditionalStrengthTraining', 'HighIntensityIntervalTraining', 'Other'];

function buildWorkoutEditor(payload, w, onDone) {
  const tz = payload.tz;
  const orig = w.orig || { startTs: w.startTs, endTs: w.endTs, sport: w.sport };
  const card = el('div', { class: 'card edit-card', id: 'workoutEditor' });
  card.appendChild(el('h3', { class: 'card-title' }, ['Edit workout']));

  const sportSel = el('select', { id: 'editSport', class: 'field' });
  const choices = SPORT_CHOICES.slice();
  [w.sport, orig.sport].forEach(s => { if (s && choices.indexOf(s) < 0) choices.unshift(s); });
  choices.forEach(s => {
    const o = el('option', { value: s }, [displaySportOf(s)]);
    if (s === w.sport) o.selected = true;
    sportSel.appendChild(o);
  });
  const startIn = el('input', { id: 'editStart', class: 'field', type: 'datetime-local', value: tsToInput(w.startTs, tz) });
  const endIn = el('input', { id: 'editEnd', class: 'field', type: 'datetime-local', value: tsToInput(w.endTs, tz) });
  const lab = (text, node) => el('label', { class: 'field-row' }, [el('span', { class: 'field-label' }, [text]), node]);
  card.appendChild(lab('Sport', sportSel));
  card.appendChild(lab(`Start (${safeTz(tz)})`, startIn));
  card.appendChild(lab('End', endIn));
  const err = el('p', { class: 'gate-error', id: 'editError', role: 'alert' });
  card.appendChild(err);

  const row = el('div', { class: 'edit-actions' });
  const save = el('button', { class: 'btn-primary', type: 'button', id: 'editSave' }, ['Save']);
  const cancel = el('button', { class: 'btn-quiet', type: 'button' }, ['Cancel']);
  const del = el('button', { class: 'btn-danger', type: 'button', id: 'editDelete' }, ['Delete workout']);
  let armed = false;
  cancel.addEventListener('click', () => onDone(false));
  del.addEventListener('click', async () => {
    if (!armed) { armed = true; del.textContent = 'Tap again to delete'; return; }
    await enqueueEntry({ v: 1, kind: 'workoutOverride', orig, deleted: true });
    onDone(true);
  });
  save.addEventListener('click', async () => {
    err.textContent = '';
    // Unchanged fields keep their exact timestamps (the inputs only have minute precision).
    const ns = startIn.value === tsToInput(w.startTs, tz) ? w.startTs : inputToTs(startIn.value, tz);
    const ne = endIn.value === tsToInput(w.endTs, tz) ? w.endTs : inputToTs(endIn.value, tz);
    if (!isNum(ns) || !isNum(ne)) { err.textContent = 'Enter a start and an end time.'; return; }
    if (ne <= ns) { err.textContent = 'The end must be after the start.'; return; }
    if (ne - ns > 24 * 3600) { err.textContent = 'A workout can’t be longer than 24 hours.'; return; }
    // The override REPLACES any earlier one for this workout, so it lists every field that differs from
    // the ORIGINAL (not from what is currently shown) — otherwise a second edit would drop the first.
    const entry = { v: 1, kind: 'workoutOverride', orig };
    if (sportSel.value !== orig.sport) entry.sport = sportSel.value;
    if (ns !== orig.startTs || ne !== orig.endTs) { entry.startTs = ns; entry.endTs = ne; }
    save.disabled = true;
    await enqueueEntry(entry);
    onDone(true);
  });
  row.appendChild(save); row.appendChild(cancel); row.appendChild(del);
  card.appendChild(row);
  return card;
}

// ---------------------------------------------------------------------------
// 6. Bootstrap
// ---------------------------------------------------------------------------

let envelope = null;
let payload = null;

function showFatalError(msg) {
  const gate = $('gate');
  clearNode(gate);
  gate.appendChild(el('p', { class: 'gate-error' }, [msg]));
}

function renderAgeInfo(env) {
  const ageLine = $('ageLine');
  const banner = $('ageBanner');
  const fmt = makeFormatters(env.tz);
  clearNode(ageLine);
  ageLine.appendChild(document.createTextNode(
    `Data through ${fmt.date(env.dataMaxTs)} ${fmt.time(env.dataMaxTs)} · generated ${fmt.time(env.generatedAt)}`
  ));
  const ageHours = (Date.now() / 1000 - env.dataMaxTs) / 3600;
  clearNode(banner);
  if (isNum(ageHours) && ageHours > 30) {
    banner.appendChild(document.createTextNode(
      `Data only reaches ${fmt.date(env.dataMaxTs)} ${fmt.time(env.dataMaxTs)} (${Math.round(ageHours)} hours ago) — NOOP on the Mac is still catching up from the strap, or isn't running.`
    ));
    banner.hidden = false;
  } else {
    banner.hidden = true;
  }
}

async function showApp(masterKey) {
  if (masterKey) {
    try { await initInbox(await inboxKeysFromMaster(masterKey), payload.ingestedEntryIds); }
    catch (e) { console.error('NOOP viewer: inbox init failed', e); inboxKeys = null; }
  }
  $('gate').hidden = true;
  const app = $('app');
  app.hidden = false;
  renderSleep(payload);
  renderWorkouts(payload);
  renderTrends(payload);
  renderLifestyle(payload);
  wireTabs();
}

function wireTabs() {
  const tabs = document.querySelectorAll('#tabs .tab');
  tabs.forEach(btn => {
    btn.addEventListener('click', () => {
      tabs.forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      document.querySelectorAll('#main .panel').forEach(p => p.classList.remove('active'));
      $(`panel-${btn.dataset.tab}`).classList.add('active');
    });
  });
}

function wireForgetButton() {
  const btn = $('forgetBtn');
  btn.hidden = false;
  btn.addEventListener('click', async () => {
    await clearDeviceKey();
    location.reload();
  });
}

function wireGateForm(note) {
  const form = $('gateForm');
  const input = $('passphraseInput');
  const remember = $('rememberCheckbox');
  const errorEl = $('gateError');
  const submitBtn = form.querySelector('button[type="submit"]');
  if (note) errorEl.textContent = note;

  form.addEventListener('submit', async ev => {
    ev.preventDefault();
    errorEl.textContent = '';
    const passphrase = input.value;
    if (!passphrase) return;
    submitBtn.disabled = true;
    try {
      const masterKey = await deriveMasterKey(passphrase);
      payload = await decryptEnvelope(envelope, await envelopeKey(envelope, masterKey, passphrase));
      input.value = '';
      if (remember.checked) {
        if (await saveDeviceKey(masterKey)) wireForgetButton();
      } else {
        await clearDeviceKey();
      }
      await showApp(masterKey);
    } catch (e) {
      // Never leak the raw error object into the DOM — a stack trace can hint at internals to
      // anyone shoulder-surfing. Log it for local debugging only.
      console.error('NOOP viewer: decrypt failed', e);
      errorEl.textContent = 'Could not decrypt — check the passphrase.';
    } finally {
      submitBtn.disabled = false;
    }
  });
}

async function init() {
  let resp;
  try {
    resp = await fetch('noop-data.json', { cache: 'no-store' });
  } catch (e) {
    showFatalError('Could not load noop-data.json.');
    return;
  }
  if (!resp.ok) { showFatalError('Could not load noop-data.json.'); return; }
  try {
    envelope = await resp.json();
  } catch (e) {
    showFatalError('noop-data.json is not valid JSON.');
    return;
  }

  renderAgeInfo(envelope);

  // WebCrypto (crypto.subtle) only exists in a secure context: https://, localhost, or a tunnel
  // like tailscale serve's *.ts.net HTTPS. A bare LAN IP over http:// (a plausible way to reach a
  // "LAN/tailnet" host) has `crypto.subtle === undefined`, which would otherwise throw deep inside
  // deriveKey and surface as the generic "check the passphrase" message — actively misleading,
  // since no passphrase would ever work. Catch it up front with a specific, actionable message.
  if (!window.crypto || !window.crypto.subtle) {
    showFatalError('This page needs a secure connection (HTTPS, or http://localhost) to decrypt data — WebCrypto is unavailable here.');
    return;
  }

  clearLegacySessionKeys();

  // Silent unlock with the key remembered on this phone. A GCM failure means the stored root no longer
  // matches (the passphrase was changed on the Mac): forget it and ask again. A v1 envelope (published
  // before this format) cannot be opened from the root, so it falls through to the form, key kept.
  let note = '';
  const deviceKey = await loadDeviceKey();
  if (deviceKey && envelope.v === 2) {
    let opened = false;
    try {
      payload = await decryptEnvelope(envelope, await payloadKeyV2(deviceKey, envelope.kdf.saltB64));
      opened = true;
    } catch (e) {
      console.error('NOOP viewer: remembered key did not open this payload', e);
      await clearDeviceKey();
      note = 'This phone’s saved key no longer works — the passphrase may have changed. Enter it again.';
    }
    if (opened) {
      await showApp(deviceKey);
      wireForgetButton();
      return;
    }
  }

  wireGateForm(note);
}

document.addEventListener('DOMContentLoaded', init);
