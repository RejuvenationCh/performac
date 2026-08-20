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

function renderDigest(f) {
  const intro = $('#digest-intro');
  const cards = $('#digest-cards');
  intro.textContent = f.coachIntro || '3 things worth doing this week, biggest first.';
  cards.replaceChildren();
  const all = (f.digest || []).slice().sort((a, b) => SEV_RANK[b.severity] - SEV_RANK[a.severity]);
  if (!all.length) {
    cards.append(el('p', 'card-why', 'Nothing worth doing — Performac is watching.'));
    return;
  }
  for (const item of all) cards.append(renderCard(item));
}

function fmtTick(ts) {
  if (!ts) return '—';
  const sec = Math.max(0, Math.round((Date.now() - ts) / 1000));
  return sec < 120 ? `${sec}s ago` : `${Math.round(sec / 60)}m ago`;
}

async function refresh() {
  let findings = { live: [], digest: [], coachIntro: null };
  try {
    const r = await fetch('/api/findings');
    if (r.ok) findings = await r.json();
  } catch {}
  try {
    const r = await fetch('/api/health');
    if (r.ok) {
      const h = await r.json();
      $('#tick-line').textContent = `sampler last tick: ${fmtTick(h.lastTick)}`;
    }
  } catch {}
  renderToday(findings);
  renderDigest(findings);
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
}
window.addEventListener('hashchange', router);

router();
refresh();
setInterval(() => {
  if (view === 'today' || view === 'digest') refresh();
}, 60000);
