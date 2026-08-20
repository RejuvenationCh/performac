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

// tmState = {configured, names, backupISO|null}; watchStats = [{path, newestMtime, maxAgeDays}]
export function backupStaleness(tmState, watchStats, cfg, now) {
  const out = [];
  if (!tmState.configured) {
    out.push({
      id: 'backup-no-destination',
      kind: 'backup',
      severity: 'red',
      headline: 'No Time Machine destination is configured on this Mac',
      why: 'Your event and campus footage has no re-shoot option — a Mac that has never been backed up is one drive failure from losing all of it',
      detail: 'Set one up in System Settings → General → Time Machine.',
      linkKind: null,
      linkTarget: null,
    });
  } else if (tmState.backupISO) {
    const ageDays = (now - Date.parse(tmState.backupISO)) / DAY;
    if (ageDays > cfg.backup.maxAgeDays) {
      const dest = tmState.names[0] ?? 'your backup destination';
      out.push({
        id: 'backup-stale',
        kind: 'backup',
        severity: 'red',
        headline: `Your last Time Machine backup is ${Math.round(ageDays)} days old`,
        why: `The newest backup on ${dest} is from ${tmState.backupISO.slice(0, 10)} — everything shot since then has no copy anywhere.`,
        detail: '',
        linkKind: null,
        linkTarget: null,
      });
    }
  } else {
    out.push({
      id: 'backup-unreadable',
      kind: 'backup',
      severity: 'info',
      headline: 'A Time Machine destination exists, but its backup history is unreadable',
      why: `Performac can see ${tmState.names[0] ?? 'the destination'} but could not read the latest backup timestamp.`,
      detail: `If this persists with the drive attached, tmutil latestbackup may need Full Disk Access — which Performac deliberately does not request. Check manually: run 'tmutil latestbackup' in Terminal.`,
      linkKind: null,
      linkTarget: null,
    });
  }
  for (const w of watchStats) {
    if (w.newestMtime == null) continue;
    const ageDays = (now - w.newestMtime) / DAY;
    if (ageDays > w.maxAgeDays) {
      out.push({
        id: `backup-watch-${slug(w.path)}`,
        kind: 'backup',
        severity: 'amber',
        headline: `${w.path.split('/').filter(Boolean).pop() ?? w.path} hasn't seen a new backup in ${Math.round(ageDays)} days`,
        why: `The newest file there is ${Math.round(ageDays)} days old and you set a ${w.maxAgeDays}-day limit.`,
        detail: '',
        linkKind: 'reveal',
        linkTarget: w.path,
      });
    }
  }
  return out;
}

// a "cycle" = unmount followed by reappearance (mount) within 30 min; user ejects don't count
export function driveInstability(events, cfg, now) {
  const byVol = new Map();
  for (const e of events) {
    if (e.kind !== 'mount' && e.kind !== 'unmount') continue;
    if (!byVol.has(e.key)) byVol.set(e.key, []);
    byVol.get(e.key).push(e);
  }
  const out = [];
  for (const [vol, list] of byVol) {
    list.sort((a, b) => a.ts - b.ts);
    const cycles = [];
    let i = 0;
    while (i < list.length) {
      if (list[i].kind !== 'unmount') { i += 1; continue; }
      const u = list[i].ts;
      let j = i + 1;
      let paired = false;
      while (j < list.length && list[j].ts - u <= 30 * 60000) {
        if (list[j].kind === 'mount') { cycles.push(u); paired = true; break; }
        j += 1;
      }
      i = paired ? j + 1 : i + 1;
    }
    const in24 = cycles.filter(u => now - u <= 24 * 3600000).length;
    const in7 = cycles.filter(u => now - u <= 7 * 86400000).length;
    if (in24 > cfg.drive.cycles24h) {
      out.push({
        id: `drive-${slug(vol)}`,
        kind: 'drive',
        severity: 'red',
        headline: `${vol} disconnected and reconnected ${in24} times in the last 24 hours`,
        why: 'A loose cable, failing port, or failing drive shows up as surprise unmount cycles — check the connection before your next shoot',
        detail: '',
        linkKind: null,
        linkTarget: null,
      });
    } else if (in7 > cfg.drive.cycles7d) {
      out.push({
        id: `drive-${slug(vol)}`,
        kind: 'drive',
        severity: 'amber',
        headline: `${vol} disconnected and reconnected ${in7} times in the last 7 days`,
        why: 'Repeated disconnects spread over the week point at a loose cable or a failing port — keep an eye on it before your next shoot.',
        detail: '',
        linkKind: null,
        linkTarget: null,
      });
    }
  }
  return out;
}

// export windows (≥ export.cpuPct sustained ≥ export.minMinutes, gaps < 2 min merged)
// × elevated intervals from thermlog level events (1/2 opens, 0 closes, open at now stays open)
export function thermalDuringExport(procSamples, thermalEvents, cfg, now) {
  const therm = thermalEvents
    .filter(e => e.kind === 'thermal' && e.key === 'thermlog')
    .sort((a, b) => a.ts - b.ts);
  const intervals = [];
  let open = null;
  let maxLevel = 0;
  for (const e of therm) {
    const level = Number(e.detail);
    if (level >= 1) {
      if (open === null) open = e.ts;
      maxLevel = Math.max(maxLevel, level);
    } else if (open !== null) {
      intervals.push({ start: open, end: e.ts, maxLevel });
      open = null;
      maxLevel = 0;
    }
  }
  if (open !== null) intervals.push({ start: open, end: now, maxLevel });

  const byPrefix = new Map();
  for (const s of procSamples) {
    const prefix = cfg.exportProcs.find(p => s.name.startsWith(p));
    if (!prefix || s.cpu < cfg.export.cpuPct) continue;
    if (!byPrefix.has(prefix)) byPrefix.set(prefix, []);
    byPrefix.get(prefix).push(s);
  }

  const out = [];
  for (const samples of byPrefix.values()) {
    samples.sort((a, b) => a.ts - b.ts);
    let winStart = null;
    let lastTs = null;
    let peak = 0;
    let winName = null;
    const closeWindow = () => {
      if (winStart === null) return;
      if (lastTs - winStart < cfg.export.minMinutes * 60000) return;
      for (const iv of intervals) {
        const overlap = Math.min(lastTs, iv.end) - Math.max(winStart, iv.start);
        if (overlap < cfg.thermal.minElevatedMinutes * 60000) continue;
        // ponytail: 30-min red line is plan-literal (not a DEFAULTS knob); calibrate in rules if it bites
        const red = overlap >= 30 * 60000 || iv.maxLevel >= 2;
        out.push({
          id: `thermal-export-${slug(winName)}`,
          kind: 'thermal',
          severity: red ? 'red' : 'amber',
          headline: `Thermal pressure ran elevated for ${Math.round(overlap / 60000)} min during your ${winName} export`,
          why: `Your export ran ~${Math.round((lastTs - winStart) / 60000)} min with a peak of ${Math.round(peak)}% CPU, and thermal warning level ${iv.maxLevel} overlapped for ${Math.round(overlap / 60000)} of those minutes — sustained encode heat, not a spike.`,
          detail: 'Check fan intakes for dust and consider a stand that improves airflow under load.',
          linkKind: null,
          linkTarget: null,
        });
        break;   // one card per export window
      }
    };
    for (const s of samples) {
      if (winStart === null) {
        winStart = s.ts;
        lastTs = s.ts;
        peak = s.cpu;
        winName = s.name;
      } else if (s.ts - lastTs >= 2 * 60000) {
        closeWindow();
        winStart = s.ts;
        lastTs = s.ts;
        peak = s.cpu;
        winName = s.name;
      } else {
        lastTs = s.ts;
        peak = Math.max(peak, s.cpu);
      }
    }
    closeWindow();
  }
  return out;
}

function slug(s) {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
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
