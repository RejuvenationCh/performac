// rules.js — pure functions: history rows → Finding[]. Card copy lives here.
// Finding = {id, kind, severity:'info'|'amber'|'red', headline, why, detail,
//            linkKind:'reveal'|'open_purge'|'open_activity_monitor'|null, linkTarget}
import { CACHE_META } from './paths.js';

const DAY = 86400000;
const LR_META = { app: 'Lightroom Classic', media: true, clearing: 'Lightroom Classic: Catalog Settings → Previews.' };

function cacheMeta(id) {
  return CACHE_META[id] ?? (id.startsWith('lr-') ? LR_META : { app: id, media: false, clearing: '' });
}

function ageText(ageDays) {
  if (ageDays == null) return 'a while';
  if (ageDays < 1) return 'today';
  if (ageDays < 2) return 'yesterday';
  return `${Math.round(ageDays)} days`;
}

// one Finding per cache id over the amber threshold; red/amber when stale, info when active
export function cacheGrowth(cacheSamples, cfg, now) {
  const byId = new Map();
  for (const s of cacheSamples) {
    if (!byId.has(s.cache_id)) byId.set(s.cache_id, []);
    byId.get(s.cache_id).push(s);
  }
  const out = [];
  for (const [id, rows] of byId) {
    rows.sort((a, b) => a.ts - b.ts);
    const latest = rows[rows.length - 1];
    const m = cacheMeta(id);
    const sizeGb = latest.size_mb / 1024;
    if (sizeGb < cfg.cacheRules.amberGb) continue;
    const ageDays = latest.newest_mtime == null ? null : (now - latest.newest_mtime) / DAY;
    const stale = ageDays !== null && ageDays >= cfg.cacheRules.staleDays;
    const media = m.media ? 'media cache' : 'cache';
    let severity, headline, why;
    if (!stale) {
      severity = 'info';
      const fresh = ageDays < 2;
      headline = fresh
        ? `${m.app}'s ${media} is ${sizeGb.toFixed(1)} GB and in active use`
        : `${m.app}'s ${media} is ${sizeGb.toFixed(1)} GB`;
      why = fresh
        ? `Last written ${ageText(ageDays)}; in active use — leave it.`
        : `Last written ${ageText(ageDays)} and still under your ${cfg.cacheRules.staleDays}-day staleness line — leave it.`;
    } else {
      severity = sizeGb >= cfg.cacheRules.redGb ? 'red' : 'amber';
      headline = `${m.app}'s ${media} is ${sizeGb.toFixed(1)} GB and hasn't been written to in ${Math.round(ageDays)} days`;
      const weekAgo = rows.filter(s => s.ts <= now - 7 * DAY).pop();
      if (weekAgo && latest.size_mb > weekAgo.size_mb) {
        const grew = (latest.size_mb - weekAgo.size_mb) / 1024;
        why = `It grew ${grew.toFixed(1)} GB in the last 7 days and hasn't been touched in ${Math.round(ageDays)} days — stale render data your current work no longer needs.`;
      } else {
        why = `It hasn't been touched in ${Math.round(ageDays)} days — stale render data your current work no longer needs.`;
      }
    }
    out.push({
      id: `cache-${id}`,
      kind: 'cache',
      severity,
      headline,
      why,
      detail: m.clearing ? `Safest route: clear it from inside the app — ${m.clearing}` : '',
      linkKind: 'reveal',
      linkTarget: latest.path,
    });
  }
  return out;
}
