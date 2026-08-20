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
    cb.checked = true;
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
setInterval(() => {
  if (view === 'today' || view === 'digest') refresh();
}, 60000);
