// app.js — fetch/render only; no business logic (the server computes findings)
const $ = (s, el = document) => el.querySelector(s);

const VIEWS = ['today', 'digest', 'duplicates', 'settings'];
const TITLES = { today: 'Today', digest: 'Digest', duplicates: 'Duplicates', settings: 'Settings' };
const SEV_LABEL = { red: 'critical', amber: 'warning', info: 'info' };
const SEV_RANK = { red: 3, amber: 2, info: 1 };
const LINKS = {
  reveal: { label: 'Show in Finder', api: '/api/reveal', body: f => ({ path: f.linkTarget }) },
  open_purge: { label: 'Open Purge', api: '/api/open', body: () => ({ target: 'purge' }) },
  open_activity_monitor: { label: 'Open Activity Monitor', api: '/api/open', body: () => ({ target: 'activity-monitor' }) },
};

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

// renderCard — headline, why-line prefixed by severity badge, optional detail,
// at most ONE link-out. There is never a button that performs the fix.
function renderCard(f) {
  const card = el('article', 'card');
  const h = el('h3', 'card-headline', f.headline);
  const why = el('p', 'card-why');
  const badge = el('span', `badge ${f.severity}`, SEV_LABEL[f.severity] || f.severity);
  why.append(badge, f.why);
  card.append(h, why);
  if (f.detail) card.append(el('p', 'card-detail', f.detail));
  const link = LINKS[f.linkKind];
  if (link) {
    const b = el('button', 'btn ghost', link.label);
    b.addEventListener('click', () => {
      fetch(link.api, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(link.body(f)),
      }).catch(() => {});
    });
    card.append(b);
  }
  return card;
}

function renderToday(f) {
  const heroBox = $('#today-hero');
  const cards = $('#today-cards');
  const empty = $('#empty-state');
  heroBox.replaceChildren();
  cards.replaceChildren();
  const live = f.live || [];
  if (!live.length) {
    empty.hidden = false;
    return;
  }
  empty.hidden = true;
  const n = live.length;
  const worst = live.slice().sort((a, b) => SEV_RANK[b.severity] - SEV_RANK[a.severity])[0];
  const hero = el('div', 'hero');
  hero.append(
    el('p', 'card-title', 'Today'),
    el('h2', '', `${n} thing${n > 1 ? 's' : ''} worth doing this week`),
  );
  const tile = el('div', 'tile');
  tile.append(
    el('h3', 'card-headline', worst.headline),
    el('p', 'card-why', worst.why),
  );
  hero.append(tile);
  heroBox.append(hero);
  for (const item of live.slice().sort((a, b) => SEV_RANK[b.severity] - SEV_RANK[a.severity])) {
    cards.append(renderCard(item));
  }
}

function renderDigest(f, trends) {
  const intro = $('#digest-intro');
  const cards = $('#digest-cards');
  intro.textContent = f.coachIntro || '3 things worth doing this week, biggest first.';
  cards.replaceChildren();
  cards.append(el('p', 'card-why', f.dupScan
    ? `Duplicate scan: last run ${fmtAgo(f.dupScan)}`
    : 'Duplicate scan: never run.'));
  renderSparklines(trends);
  const all = (f.digest || []).slice().sort((a, b) => SEV_RANK[b.severity] - SEV_RANK[a.severity]);
  if (!all.length) {
    cards.append(el('p', 'card-why', 'Nothing worth doing — Performac is watching.'));
    return;
  }
  for (const item of all) cards.append(renderCard(item));
}

// 90px-tall inline-SVG sparklines per volume, straight from /api/trends (no library)
function renderSparklines(trends) {
  const box = $('#digest-sparklines');
  box.replaceChildren();
  const byVol = new Map();
  for (const p of trends?.disk ?? []) {
    if (!byVol.has(p.volume)) byVol.set(p.volume, []);
    byVol.get(p.volume).push(p);
  }
  for (const [volume, points] of byVol) {
    if (points.length < 2) continue;
    const tile = el('div', 'tile');
    const w = 120;
    const h = 90;
    const min = Math.min(...points.map(p => p.freeGb));
    const max = Math.max(...points.map(p => p.freeGb));
    const span = max - min || 1;
    const d = points
      .map((p, i) => `${i === 0 ? 'M' : 'L'}${((i / (points.length - 1)) * w).toFixed(1)},${(h - ((p.freeGb - min) / span) * h).toFixed(1)}`)
      .join(' ');
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', `0 0 ${w} ${h}`);
    svg.style.width = `${w}px`;
    svg.style.height = `${h}px`;
    svg.setAttribute('aria-label', `${volume} free space over time`);
    const pathEl = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    pathEl.setAttribute('d', d);
    pathEl.setAttribute('fill', 'none');
    pathEl.setAttribute('stroke', 'var(--primary)');
    pathEl.setAttribute('stroke-width', '1.8');
    pathEl.setAttribute('stroke-linecap', 'round');
    svg.append(pathEl);
    const latest = points[points.length - 1].freeGb;
    tile.append(
      el('p', 'card-title', volume),
      svg,
      el('p', 'card-why num', `${latest.toFixed(0)} GB free`),
    );
    box.append(tile);
  }
}

function fmtAgo(ts) {
  const days = (Date.now() - ts) / 86400000;
  if (days < 1) return 'today';
  if (days < 7) return `${Math.round(days)} days ago`;
  if (days < 60) return `${Math.round(days / 7)} weeks ago`;
  return `${Math.round(days / 30)} months ago`;
}

// Duplicates view — roots picker, Start, progress, groups with per-path reveal
let dupePoll = null;

async function refreshDuplicates() {
  let d;
  try {
    d = await (await fetch('/api/dedupe')).json();
  } catch {
    return;
  }
  $('#dupe-hint').textContent = d.lastScan
    ? `Duplicate scan: last run ${fmtAgo(d.lastScan)}`
    : 'Duplicate scan: never run.';
  const controls = $('#dupe-controls');
  controls.replaceChildren();
  for (const root of d.roots) {
    const label = el('label', 'check-row');
    label.style.marginBottom = '6px';
    const cb = document.createElement('input');
    cb.type = 'checkbox';
    cb.value = root;
    cb.checked = !savedCfg || (savedCfg.dupRoots ?? ['~']).includes(root);
    label.append(cb, root === '~' ? 'Home folder' : root);
    controls.append(label);
  }
  const start = el('button', 'btn', 'Start scan');
  start.addEventListener('click', () => {
    const roots = [...controls.querySelectorAll('input:checked')].map(i => i.value);
    fetch('/api/dedupe', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ roots }),
    }).then(r => {
      if (r.status === 409) $('#dupe-hint').textContent = 'A scan is already running.';
    }).catch(() => {});
    if (dupePoll) clearInterval(dupePoll);
    dupePoll = setInterval(pollDuplicates, 2000);
  });
  controls.append(start);
  renderDupGroups(d);
  if (d.state === 'running' && !dupePoll) {
    dupePoll = setInterval(pollDuplicates, 2000);
  }
}

async function pollDuplicates() {
  let d;
  try {
    d = await (await fetch('/api/dedupe')).json();
  } catch {
    return;
  }
  renderDupGroups(d);
  $('#dupe-hint').textContent = d.state === 'running'
    ? `Scanning… ${d.scanned} files checked so far`
    : `Duplicate scan: last run ${fmtAgo(d.lastScan)}`;
  if (d.state !== 'running' && dupePoll) {
    clearInterval(dupePoll);
    dupePoll = null;
  }
}

function renderDupGroups(d) {
  const box = $('#dupe-groups');
  box.replaceChildren();
  for (const g of d.groups ?? []) {
    const sizeText = g.sizeMb >= 1024 ? `${(g.sizeMb / 1024).toFixed(1)} GB` : `${g.sizeMb} MB`;
    const card = el('div', 'tile');
    card.append(el('h3', 'card-headline', `The same ${sizeText} file exists in ${g.paths.length} places`));
    for (const p of g.paths) {
      const row = el('div', 'check-row');
      row.style.marginTop = '6px';
      const b = el('button', 'btn ghost', 'Show in Finder');
      b.style.marginTop = '0';
      b.addEventListener('click', () => {
        fetch('/api/reveal', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ path: p }),
        }).catch(() => {});
      });
      row.append(el('span', 'num', p), b);
      card.append(row);
    }
    box.append(card);
  }
}

function fmtTick(ts) {
  if (!ts) return '—';
  const sec = Math.max(0, Math.round((Date.now() - ts) / 1000));
  return sec < 120 ? `${sec}s ago` : `${Math.round(sec / 60)}m ago`;
}

async function refresh() {
  let findings = { live: [], digest: [], coachIntro: null };
  let trends = { disk: [] };
  try {
    const r = await fetch('/api/findings');
    if (r.ok) findings = await r.json();
  } catch {}
  try {
    const r = await fetch('/api/trends?days=30');
    if (r.ok) trends = await r.json();
  } catch {}
  try {
    const r = await fetch('/api/health');
    if (r.ok) {
      const h = await r.json();
      $('#tick-line').textContent = `sampler last tick: ${fmtTick(h.lastTick)}`;
    }
  } catch {}
  renderToday(findings);
  renderDigest(findings, trends);
}

let view = 'today';
function router() {
  view = location.hash.slice(1) || 'today';
  if (!VIEWS.includes(view)) view = 'today';
  for (const v of VIEWS) {
    const section = $(`#view-${v}`);
    if (section) section.hidden = v !== view;
  }
  document.querySelectorAll('.rail a').forEach(a => a.classList.toggle('active', a.dataset.view === view));
  $('#page-title').textContent = TITLES[view];
  if (view === 'duplicates') refreshDuplicates();
}
window.addEventListener('hashchange', router);

router();
refresh();
renderSettings();
setInterval(() => {
  if (view === 'today' || view === 'digest') refresh();
}, 60000);

// Settings — thresholds grouped by feature, tier-3 toggles (off by default), watch paths,
// dedupe roots, notification master switch, and the on-demand login-items scan.
let savedCfg = null;

const SETTING_GROUPS = [
  ['Cache rules', { 'cacheRules.amberGb': 'Amber at (GB)', 'cacheRules.redGb': 'Red at (GB)', 'cacheRules.staleDays': 'Stale after (days)' }],
  ['Sustained hogs', { 'hog.cpuPct': 'CPU %', 'hog.minMinutes': 'Minutes' }],
  ['Idle-but-loaded', { 'idle.rssMb': 'RSS (MB)', 'idle.hours': 'Hours' }],
  ['Backup', { 'backup.maxAgeDays': 'Max age (days)' }],
  ['Storage trend', { 'storage.fitDays': 'Fit window (days)', 'storage.warnWeeksLeft': 'Amber at (weeks left)', 'storage.redWeeksLeft': 'Red at (weeks left)' }],
  ['Drive cycles', { 'drive.cycles24h': 'Cycles / 24h', 'drive.cycles7d': 'Cycles / 7d' }],
  ['Thermal', { 'thermal.minElevatedMinutes': 'Min elevated (min)' }],
  ['Exports', { 'export.cpuPct': 'CPU %', 'export.minMinutes': 'Minutes' }],
  ['Dedupe', { 'dup.minMb': 'Min file (MB)' }],
  ['Drift', { 'drift.minAgeDays': 'Min age (days)', 'drift.minMb': 'Min size (MB)' }],
  ['Notifications', { 'notifyCooldownHours': 'Cooldown (hours)' }],
];

function getNested(obj, key) {
  return key.split('.').reduce((o, k) => (o == null ? o : o[k]), obj);
}

function setNested(obj, key, value) {
  const parts = key.split('.');
  let o = obj;
  for (const k of parts.slice(0, -1)) o = o[k] ?? (o[k] = {});
  o[parts[parts.length - 1]] = value;
}

async function renderSettings() {
  const box = $('#settings-form');
  box.replaceChildren();
  let cfg;
  try {
    cfg = await (await fetch('/api/settings')).json();
  } catch {
    return;
  }
  savedCfg = cfg;

  const toggles = el('div', 'form-grid');
  const toggle = (key, label) => {
    const row = el('label', 'check-row');
    const cb = document.createElement('input');
    cb.type = 'checkbox';
    cb.dataset.key = key;
    cb.checked = !!getNested(cfg, key);
    row.append(cb, label);
    toggles.append(row);
  };
  toggle('notifyEnabled', 'Notifications on');
  toggle('tier3.battery', 'Battery health tracking (Tier 3)');
  toggle('tier3.browserBloat', 'Browser RAM bloat (Tier 3)');
  box.append(toggles);

  for (const [title, fields] of SETTING_GROUPS) {
    box.append(el('p', 'section-label', title));
    const grid = el('div', 'form-grid');
    for (const [key, label] of Object.entries(fields)) {
      const field = el('div', 'field');
      field.append(el('label', '', label));
      const input = document.createElement('input');
      input.type = 'number';
      input.step = 'any';
      input.dataset.key = key;
      input.value = getNested(cfg, key) ?? '';
      field.append(input);
      grid.append(field);
    }
    box.append(grid);
  }

  box.append(el('p', 'section-label', 'Backup watch paths'));
  box.append(el('p', 'card-why', 'One per line: path|maxDays. Any file older than maxDays in that folder triggers an amber card.'));
  const watch = document.createElement('textarea');
  watch.id = 'watch-paths';
  watch.style.width = '100%';
  watch.rows = 3;
  watch.style.font = 'inherit';
  watch.style.padding = '6px 8px';
  watch.style.border = '1px solid var(--line)';
  watch.style.borderRadius = '8px';
  watch.value = (cfg.backup?.watchPaths ?? []).map(w => `${w.path}|${w.maxAgeDays}`).join('\n');
  box.append(watch);

  box.append(el('p', 'section-label', 'Dedupe roots'));
  box.append(el('p', 'card-why', 'Comma-separated. These pre-check in the Duplicates view; new volumes appear there automatically.'));
  const roots = document.createElement('input');
  roots.type = 'text';
  roots.id = 'dup-roots';
  roots.style.width = '100%';
  roots.style.padding = '6px 8px';
  roots.style.font = 'inherit';
  roots.style.border = '1px solid var(--line)';
  roots.style.borderRadius = '8px';
  roots.value = (cfg.dupRoots ?? ['~']).join(', ');
  box.append(roots);

  const row = el('div', 'check-row');
  row.style.marginTop = '14px';
  row.style.gap = '10px';
  const save = el('button', 'btn', 'Save settings');
  save.addEventListener('click', () => saveSettings(box, save));
  const status = el('span', 'card-why', '');
  row.append(save, status);
  box.append(row);

  const scan = el('button', 'btn ghost', 'Scan login items');
  scan.style.marginLeft = '0';
  scan.addEventListener('click', () => {
    fetch('/api/login-scan', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: '{}',
    }).then(r => {
      if (!r.ok) alert('Scan failed — macOS may have denied the one-time Automation permission.');
    }).catch(() => {});
  });
  box.append(scan, el('p', 'card-why', 'On-demand only: asks macOS for a one-time Automation permission, cross-checks login items against a month of process samples.'));
}

async function saveSettings(box, button) {
  const body = {};
  for (const input of box.querySelectorAll('input[data-key]')) {
    const v = input.type === 'checkbox' ? input.checked : Number(input.value);
    setNested(body, input.dataset.key, v);
  }
  const watchPaths = $('#watch-paths').value.split('\n').map(l => l.trim()).filter(Boolean).map(l => {
    const [p, d] = l.split('|').map(s => s.trim());
    return { path: p, maxAgeDays: Number(d) || 7 };
  });
  body.backup = { ...(body.backup ?? {}), watchPaths };
  const roots = $('#dup-roots').value.split(',').map(s => s.trim()).filter(Boolean);
  body.dupRoots = roots.length ? roots : ['~'];
  const r = await fetch('/api/settings', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  }).catch(() => null);
  const err = r && !r.ok ? await r.json().catch(() => null) : null;
  const prev = button.textContent;
  button.textContent = err ? `Save failed: ${err.error}` : 'Saved';
  if (err) button.style.borderColor = 'var(--red)';
  setTimeout(() => {
    button.textContent = prev;
    button.style.borderColor = '';
  }, 3000);
  savedCfg = { ...(await (await fetch('/api/settings')).json()) };
}
