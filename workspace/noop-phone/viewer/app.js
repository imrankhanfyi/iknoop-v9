'use strict';
/*
 * NOOP phone viewer — vanilla JS, no build step, no network beyond the same-origin
 * fetch('noop-data.json'). Everything below is organized top-to-bottom as:
 *   1. Tiny DOM helpers (createElement/textContent only — never innerHTML with data)
 *   2. Base64 / UTF-8 / gzip / WebCrypto helpers (the decrypt pipeline)
 *   3. Formatting helpers (timezone-aware, null-safe: a missing value is ALWAYS "—", never 0)
 *   4. Chart primitives (sparkline, bar chart, hypnogram) — SVG + a hidden <table> twin
 *   5. Screen renderers (Today / Last night / Sleep history / Workouts / Trends)
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

/** Derive an AES-256-GCM key from a passphrase via PBKDF2-HMAC-SHA256, per the envelope's kdf params. */
async function deriveKey(passphrase, saltB64, iterations) {
  const baseKey = await crypto.subtle.importKey('raw', utf8(passphrase), 'PBKDF2', false, ['deriveKey']);
  const salt = bytesFromB64(saltB64);
  // extractable: true — needed so "Remember on this device" can export the raw key into sessionStorage.
  return crypto.subtle.deriveKey(
    { name: 'PBKDF2', salt, iterations, hash: 'SHA-256' },
    baseKey,
    { name: 'AES-GCM', length: 256 },
    true,
    ['decrypt']
  );
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

// "Remember on this device" — stores ONLY the derived AES key (never the passphrase) in
// sessionStorage, tagged with the salt/iterations it was derived from. sessionStorage clears when
// the tab closes, and a stale key (from a previous publish's salt) is simply ignored, not reused.
const REMEMBER_KEYS = { key: 'noopViewerKeyB64', salt: 'noopViewerKeySalt', iter: 'noopViewerKeyIter' };

function saveRememberedKey(keyB64, saltB64, iterations) {
  try {
    sessionStorage.setItem(REMEMBER_KEYS.key, keyB64);
    sessionStorage.setItem(REMEMBER_KEYS.salt, saltB64);
    sessionStorage.setItem(REMEMBER_KEYS.iter, String(iterations));
  } catch (e) { /* sessionStorage unavailable (private mode etc.) — silently skip remembering */ }
}

function loadRememberedKey() {
  try {
    const keyB64 = sessionStorage.getItem(REMEMBER_KEYS.key);
    const saltB64 = sessionStorage.getItem(REMEMBER_KEYS.salt);
    const iter = sessionStorage.getItem(REMEMBER_KEYS.iter);
    if (!keyB64 || !saltB64 || !iter) return null;
    return { keyB64, saltB64, iterations: Number(iter) };
  } catch (e) { return null; }
}

function clearRememberedKey() {
  try {
    sessionStorage.removeItem(REMEMBER_KEYS.key);
    sessionStorage.removeItem(REMEMBER_KEYS.salt);
    sessionStorage.removeItem(REMEMBER_KEYS.iter);
  } catch (e) { /* ignore */ }
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

function renderToday(payload) {
  const panel = $('panel-today');
  clearNode(panel);
  const days = payload.days || [];
  const today = days.length ? days[days.length - 1] : null;
  if (!today) { panel.appendChild(el('p', { class: 'empty-state' }, ['No daily data available yet.'])); return; }

  panel.appendChild(el('div', { class: 'section-date' }, [dayLabel(today.day)]));
  const grid = el('div', { class: 'tile-grid' });
  grid.appendChild(statTile('Recovery', isNum(today.recovery) ? `${Math.round(today.recovery)}%` : '—', recoveryBandVar(today.recovery)));
  grid.appendChild(statTile('Effort (Strain)', fmtNum(today.strain, 1)));
  grid.appendChild(statTile('Resting HR', isNum(today.restingHr) ? `${Math.round(today.restingHr)} bpm` : '—'));
  grid.appendChild(statTile('HRV', isNum(today.avgHrv) ? `${today.avgHrv.toFixed(1)} ms` : '—'));
  grid.appendChild(statTile('Sleep duration', fmtHM(today.totalSleepMin)));
  grid.appendChild(statTile('Sleep performance', fmtScorePct(today.sleepPerformance)));
  panel.appendChild(grid);
}

function renderLastNight(payload) {
  const panel = $('panel-lastnight');
  clearNode(panel);
  const sleeps = payload.sleeps || [];
  const night = sleeps.length ? sleeps[sleeps.length - 1] : null;
  if (!night) { panel.appendChild(el('p', { class: 'empty-state' }, ['No sleep recorded yet.'])); return; }

  const fmt = makeFormatters(payload.tz);
  const header = el('div', { class: 'night-header' });
  header.appendChild(el('div', { class: 'night-times' }, [
    el('span', { class: 'night-time' }, [fmt.time(night.effectiveStartTs)]),
    el('span', { class: 'night-arrow' }, [' → ']),
    el('span', { class: 'night-time' }, [fmt.time(night.endTs)]),
  ]));
  if (night.userEdited) header.appendChild(el('span', { class: 'chip chip-edited' }, ['edited']));
  panel.appendChild(header);

  // Two DIFFERENT durations, and they must be labelled as such. `endTs - effectiveStartTs` is time
  // IN BED (485 min on 2026-07-27); the asleep total is the sum of the non-wake stage segments
  // (463.32 min = 7h 43m), which is what `dailyMetric.totalSleepMin` holds and what the Today tile
  // shows. Showing the in-bed span under a bare "Duration" label next to Today's "Sleep duration"
  // makes the same night look like two different nights.
  const inBedMin = isNum(night.effectiveStartTs) && isNum(night.endTs)
    ? (night.endTs - night.effectiveStartTs) / 60 : null;
  const stageSegs = Array.isArray(night.stages) ? night.stages : [];
  const asleepMin = stageSegs.length
    ? stageSegs.reduce((t, s) => t + (s.stage === 'wake' ? 0 : (s.end - s.start)), 0) / 60
    : null;
  const stats = el('div', { class: 'tile-grid' });
  stats.appendChild(statTile('Asleep', fmtHM(asleepMin)));
  stats.appendChild(statTile('Time in bed', fmtHM(inBedMin)));
  stats.appendChild(statTile('Efficiency', fmtPct(night.efficiency)));
  stats.appendChild(statTile('Resting HR', isNum(night.restingHr) ? `${Math.round(night.restingHr)} bpm` : '—'));
  stats.appendChild(statTile('HRV', isNum(night.avgHrv) ? `${night.avgHrv.toFixed(1)} ms` : '—'));
  panel.appendChild(stats);

  panel.appendChild(buildHypnogram(night, payload.tz));
}

function renderHistory(payload) {
  const panel = $('panel-history');
  clearNode(panel);
  const days = payload.days || [];
  if (!days.length) { panel.appendChild(el('p', { class: 'empty-state' }, ['No history yet.'])); return; }

  const endDay = days[days.length - 1].day;
  const gridDays = lastNCalendarDays(endDay, 30);
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
    if (!d) {
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

function renderWorkouts(payload) {
  const panel = $('panel-workouts');
  clearNode(panel);
  const workouts = (payload.workouts || []).slice().sort((a, b) => (b.startTs || 0) - (a.startTs || 0));
  if (!workouts.length) { panel.appendChild(el('p', { class: 'empty-state' }, ['No workouts recorded.'])); return; }

  const fmt = makeFormatters(payload.tz);
  const list = el('div', { class: 'workout-list' });
  workouts.forEach(w => {
    const row = el('div', { class: 'workout-row' });
    row.appendChild(el('div', { class: 'workout-top' }, [
      el('span', { class: 'workout-date' }, [fmt.date(w.startTs)]),
      el('span', { class: 'workout-time' }, [fmt.time(w.startTs)]),
    ]));
    const mid = el('div', { class: 'workout-mid' }, [
      // `displaySport`, never the raw `sport`. The publisher pre-applies the app's own
      // WorkoutSource.displaySport(): the auto-detector stores the machine token "detected", which the
      // app deliberately shows as "Activity" ("we don't claim a sport we didn't actually classify"),
      // and it splits WHOOP's camelCase tokens ("TraditionalStrengthTraining" -> "Traditional
      // Strength Training"). Rendering `w.sport` puts "detected" on screen and disagrees with the app.
      el('span', { class: 'workout-sport' }, [w.displaySport || w.sport || 'Workout']),
    ]);
    if (w.hrReconciled) mid.appendChild(el('span', { class: 'chip chip-hr' }, ['HR from strap trace']));
    row.appendChild(mid);

    const durMin = isNum(w.durationS) ? w.durationS / 60 : null;
    row.appendChild(el('div', { class: 'workout-stats' }, [
      el('span', {}, [`Duration ${fmtHM(durMin)}`]),
      el('span', {}, [`Avg HR ${isNum(w.avgHr) ? Math.round(w.avgHr) + ' bpm' : '—'}`]),
      el('span', {}, [`Max HR ${isNum(w.maxHr) ? Math.round(w.maxHr) + ' bpm' : '—'}`]),
      el('span', {}, [`Strain ${fmtNum(w.strain, 1)}`]),
    ]));
    list.appendChild(row);
  });
  panel.appendChild(list);
}

const TREND_METRICS = [
  { key: 'recovery', label: 'Recovery', colorVar: '--recovery-100', formatter: v => `${Math.round(v)}%` },
  { key: 'strain', label: 'Strain', colorVar: '--strain-100', formatter: v => fmtNum(v, 1) },
  { key: 'restingHr', label: 'Resting HR', colorVar: '--metric-restinghr', formatter: v => `${Math.round(v)} bpm` },
  { key: 'avgHrv', label: 'HRV', colorVar: '--metric-cyan', formatter: v => `${v.toFixed(1)} ms` },
  { key: 'totalSleepMin', label: 'Sleep duration', colorVar: '--rest-color', formatter: fmtHM },
  { key: 'sleepPerformance', label: 'Sleep performance', colorVar: '--accent', formatter: v => `${Math.round(v)}%` },
];

function renderTrends(payload) {
  const panel = $('panel-trends');
  clearNode(panel);
  const days = payload.days || [];
  if (!days.length) { panel.appendChild(el('p', { class: 'empty-state' }, ['No trend data yet.'])); return; }

  const endDay = days[days.length - 1].day;
  const gridDays = lastNCalendarDays(endDay, 30);
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
    `Data as of ${fmt.date(env.dataMaxTs)} ${fmt.time(env.dataMaxTs)} · generated ${fmt.time(env.generatedAt)}`
  ));
  const ageHours = (Date.now() / 1000 - env.dataMaxTs) / 3600;
  clearNode(banner);
  if (isNum(ageHours) && ageHours > 30) {
    banner.appendChild(document.createTextNode(
      `Data is ${Math.round(ageHours)} hours old — the Mac hasn't published since ${fmt.date(env.dataMaxTs)} ${fmt.time(env.dataMaxTs)}.`
    ));
    banner.hidden = false;
  } else {
    banner.hidden = true;
  }
}

function showApp() {
  $('gate').hidden = true;
  const app = $('app');
  app.hidden = false;
  renderToday(payload);
  renderLastNight(payload);
  renderHistory(payload);
  renderWorkouts(payload);
  renderTrends(payload);
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
  btn.addEventListener('click', () => {
    clearRememberedKey();
    location.reload();
  });
}

function wireGateForm() {
  const form = $('gateForm');
  const input = $('passphraseInput');
  const remember = $('rememberCheckbox');
  const errorEl = $('gateError');
  const submitBtn = form.querySelector('button[type="submit"]');

  form.addEventListener('submit', async ev => {
    ev.preventDefault();
    errorEl.textContent = '';
    const passphrase = input.value;
    if (!passphrase) return;
    submitBtn.disabled = true;
    try {
      const key = await deriveKey(passphrase, envelope.kdf.saltB64, envelope.kdf.iterations);
      payload = await decryptEnvelope(envelope, key);
      if (remember.checked) {
        const raw = await crypto.subtle.exportKey('raw', key);
        saveRememberedKey(b64FromBytes(new Uint8Array(raw)), envelope.kdf.saltB64, envelope.kdf.iterations);
        wireForgetButton();
      } else {
        clearRememberedKey();
      }
      input.value = '';
      showApp();
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

  // Try a silent unlock via a key remembered earlier THIS session, but only if it was derived from
  // the exact salt/iteration count this envelope carries (a fresh publish always mints a new salt,
  // so a stale remembered key harmlessly falls through to the passphrase form).
  const remembered = loadRememberedKey();
  if (remembered && envelope.kdf && remembered.saltB64 === envelope.kdf.saltB64 && remembered.iterations === envelope.kdf.iterations) {
    try {
      const key = await crypto.subtle.importKey('raw', bytesFromB64(remembered.keyB64), { name: 'AES-GCM' }, true, ['decrypt']);
      payload = await decryptEnvelope(envelope, key);
      showApp();
      wireForgetButton();
      return;
    } catch (e) {
      clearRememberedKey();
    }
  }

  wireGateForm();
}

document.addEventListener('DOMContentLoaded', init);
