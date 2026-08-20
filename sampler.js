// sampler.js — 30s tick loop + two long-running event streams. Writes samples/events;
// no parsing logic here (that lives in collectors.js). All spawns via injected deps
// so tests never touch real binaries. deps.execFile resolves {stdout}; deps.statfs
// resolves the fs.statfs object; deps.now() returns ms.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  parsePs, parseFrontAppName, parseTherm, parseThermlogLine, parseDiskutilActivity,
  parseTmDestinations, parseTmLatest, parseBattery,
} from './collectors.js';
import { sweep, getSetting, setSetting } from './db.js';
import { loadConfig } from './config.js';
import { cacheTargets, measure } from './paths.js';
import { cacheGrowth, thermalDuringExport, driveInstability, backupStaleness, sustainedHogs, idleLoaded, storageTrend, drift, loginItemsAudit, batteryTrend, browserBloat } from './rules.js';
import { maybeNotify } from './notify.js';

let lastTickAt = null;
export function lastTick() {
  return lastTickAt;
}

let lastFindingsAt = null;
export function findingsGeneratedAt() {
  return lastFindingsAt;
}

// run all rules, upsert findings by id, delete ids no longer produced, notify.
// exec is the injected execFile ({stdout} contract) used by maybeNotify.
export async function refreshFindings(db, cfg, now, exec) {
  const findings = [
    ...cacheGrowth(db.prepare('SELECT * FROM cache_samples').all(), cfg, now),
    ...thermalDuringExport(
      db.prepare('SELECT * FROM proc_samples ORDER BY ts').all(),
      db.prepare("SELECT * FROM events WHERE kind = 'thermal' ORDER BY ts").all(),
      cfg, now
    ),
    ...driveInstability(
      db.prepare("SELECT * FROM events WHERE kind IN ('mount','unmount') ORDER BY ts").all(),
      cfg, now
    ),
    ...backupStaleness(
      getSetting(db, 'tmState') ?? { configured: false, names: [], backupISO: null },
      getSetting(db, 'watchStats') ?? [],
      cfg, now
    ),
    ...sustainedHogs(
      db.prepare('SELECT * FROM proc_samples WHERE ts > ?').all(now - cfg.hog.lookbackHours * 3600000),
      cfg, now
    ),
    ...idleLoaded(
      db.prepare('SELECT * FROM proc_samples WHERE ts > ?').all(now - 3600000),
      db.prepare("SELECT * FROM events WHERE kind = 'front_app'").all(),
      cfg, now
    ),
    ...storageTrend(db.prepare('SELECT * FROM disk_samples').all(), cfg, now),
    ...drift(getSetting(db, 'driftEntries') ?? [], cfg, now),
    ...loginItemsAudit(
      getSetting(db, 'loginItems')?.items ?? [],
      getSetting(db, 'loginAgents')?.agents ?? [],
      db.prepare('SELECT DISTINCT name FROM proc_samples WHERE ts > ?').all(now - 30 * 86400000).map(r => r.name),
      cfg, now
    ),
    ...batteryTrend(
      db.prepare("SELECT * FROM events WHERE kind = 'battery' ORDER BY ts").all()
        .map(r => { try { return { ts: r.ts, ...JSON.parse(r.detail) }; } catch { return null; } })
        .filter(Boolean),
      cfg, now
    ),
    ...browserBloat(
      db.prepare('SELECT * FROM proc_samples WHERE ts > ?').all(now - 24 * 3600000),
      cfg, now
    ),
  ];
  const eperm = getSetting(db, 'driftEperm') ?? [];
  if (eperm.length) {
    findings.push({
      id: 'perm-drift', kind: 'perm', severity: 'info',
      headline: 'macOS blocked Performac from checking some folders',
      why: `Performac could not read ${eperm.join(', ')} — grant Files & Folders access in System Settings → Privacy & Security, then restart Performac.`,
      detail: '',
      linkKind: null,
      linkTarget: null,
    });
  }
  if (getSetting(db, 'premiere-sidebyside') === '1') {
    findings.push({
      id: 'cache-premiere-sidebyside', kind: 'cache', severity: 'info',
      headline: 'Premiere keeps its media cache next to your media',
      why: "Side-by-side caching is on in Premiere's prefs, so the cache grows wherever your footage lives.",
      detail: 'Size and clear it from Premiere: Settings → Media Cache.',
      linkKind: null, linkTarget: null,
    });
  }
  const upsert = db.prepare(
    `INSERT INTO findings(id, kind, severity, headline, why, detail, link_kind, link_target, first_seen, updated, last_notified)
     VALUES(?,?,?,?,?,?,?,?,?,?,NULL)
     ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, severity=excluded.severity, headline=excluded.headline,
       why=excluded.why, detail=excluded.detail, link_kind=excluded.link_kind, link_target=excluded.link_target,
       updated=excluded.updated`
  );
  for (const f of findings) {
    upsert.run(f.id, f.kind, f.severity, f.headline, f.why, f.detail, f.linkKind ?? null, f.linkTarget ?? null, now, now);
  }
  if (findings.length) {
    const marks = findings.map(() => '?').join(',');
    db.prepare(`DELETE FROM findings WHERE id NOT IN (${marks})`).run(...findings.map(f => f.id));
  } else {
    db.prepare('DELETE FROM findings').run();
  }
  if (exec) {
    for (const f of findings) await maybeNotify(db, f, cfg, now, exec);
  }
  lastFindingsAt = now;
}

const GB = 1073741824;
const RECENT_MS = 5000;   // reconcile dedupes against stream events newer than this

// hourly: measure every cache target (D2 registry) into cache_samples, then refresh findings
export async function cacheTick(db, cfg, deps) {
  const t = deps.now();
  const home = os.homedir();

  let lrcats;
  const cached = getSetting(db, 'lrcatCache');
  if (cached && t - cached.ts < 86400000) {
    lrcats = cached.paths;
  } else {
    try {
      const { stdout } = await deps.execFile('mdfind', ['kMDItemFSName == "*.lrcat"']);
      lrcats = String(stdout).split('\n').map(s => s.trim()).filter(Boolean);
      setSetting(db, 'lrcatCache', { ts: t, paths: lrcats });
    } catch {
      lrcats = cached?.paths ?? [];
    }
  }

  const readText = async (...parts) => {
    try { return await fs.promises.readFile(path.join(home, ...parts), 'utf8'); } catch { return ''; }
  };
  const resolveCfg = await readText('Library/Preferences/Blackmagic Design/DaVinci Resolve/config.dat');
  const prefs = await readPremierePrefs(home);

  // discover big per-bundle cache dirs in ~/Library/Caches (fixed registry entries skipped here)
  const FIXED_CACHE_NAMES = new Set(['com.apple.dt.Xcode', 'Google', 'BraveSoftware', 'zen']);
  const cacheDirs = [];
  try {
    for (const name of await fs.promises.readdir(path.join(home, 'Library/Caches'))) {
      if (name.startsWith('.') || FIXED_CACHE_NAMES.has(name)) continue;
      const p = path.join(home, 'Library/Caches', name);
      let st;
      try { st = await fs.promises.stat(p); } catch { continue; }
      if (!st.isDirectory()) continue;
      const m = await measure(p);
      // ponytail: 500 MB discovery line is plan-literal; calibrate if cards get noisy
      if (m.sizeMb > 500) cacheDirs.push({ name, sizeMb: Math.round(m.sizeMb), newestMtime: m.newestMtime, fileCount: m.fileCount });
    }
  } catch { /* no caches dir */ }

  const targets = cacheTargets(cfg, { resolveCfg, prefs, lrcatPaths: lrcats, cacheDirs });
  const sideBySide = targets.find(t => t.id === 'premiere-media')?.note === 'side-by-side';
  if (sideBySide) setSetting(db, 'premiere-sidebyside', '1');
  else db.prepare('DELETE FROM settings WHERE key = ?').run('premiere-sidebyside');

  const ins = db.prepare(
    'INSERT INTO cache_samples(ts, cache_id, path, size_mb, newest_mtime, file_count) VALUES(?,?,?,?,?,?)'
  );
  for (const tg of targets) {
    if (tg.note === 'side-by-side') continue;    // say so on the card instead of measuring
    if (!tg.measurement && !fs.existsSync(tg.path)) continue;   // optional/absent → skip silently
    const m = tg.measurement ?? await measure(tg.path);
    ins.run(t, tg.id, tg.path, Math.round(m.sizeMb), m.newestMtime, m.fileCount);
  }
  await refreshFindings(db, loadConfig(db), t, deps.execFile).catch(err => console.error('refreshFindings', err));
}

// daily, tier3-gated: one ioreg read → battery event (detail = JSON {cycleCount, healthPct})
export async function batteryTick(db, cfg, deps) {
  if (!cfg.tier3 || !cfg.tier3.battery) return;
  const t = deps.now();
  try {
    const { stdout } = await deps.execFile('ioreg', ['-rn', 'AppleSmartBattery']);
    const b = parseBattery(String(stdout));
    if (b) {
      db.prepare('INSERT INTO events(ts, kind, key, detail) VALUES(?,?,?,?)')
        .run(t, 'battery', 'battery', JSON.stringify({ cycleCount: b.cycleCount, healthPct: b.healthPct }));
    }
  } catch { /* no battery, or ioreg failed */ }
  await refreshFindings(db, loadConfig(db), t, deps.execFile).catch(err => console.error('refreshFindings', err));
}

// hourly: depth-2 walk of drift.paths → settings; EPERM → permission-explainer card path
export async function driftTick(db, cfg, deps) {
  const t = deps.now();
  const entries = [];
  const eperm = [];
  for (const p of cfg.drift.paths) {
    const dir = p.startsWith('~/') ? path.join(os.homedir(), p.slice(2)) : p;
    try {
      for (const top of await fs.promises.readdir(dir, { withFileTypes: true })) {
        if (top.isFile()) {
          try {
            const st = await fs.promises.stat(path.join(dir, top.name));
            entries.push({ path: path.join(dir, top.name), folder: dir, sizeMb: st.size / 1048576, mtime: Math.round(st.mtimeMs) });
          } catch { /* raced */ }
        } else if (top.isDirectory()) {
          try {
            for (const f of await fs.promises.readdir(path.join(dir, top.name), { withFileTypes: true })) {
              if (!f.isFile()) continue;
              try {
                const st = await fs.promises.stat(path.join(dir, top.name, f.name));
                entries.push({ path: path.join(dir, top.name, f.name), folder: dir, sizeMb: st.size / 1048576, mtime: Math.round(st.mtimeMs) });
              } catch { /* raced */ }
            }
          } catch (err) {
            if (err.code === 'EPERM' || err.code === 'EACCES') eperm.push(path.join(dir, top.name));
          }
        }
      }
    } catch (err) {
      if (err.code === 'EPERM' || err.code === 'EACCES') eperm.push(dir);
    }
  }
  setSetting(db, 'driftEntries', entries);
  setSetting(db, 'driftEperm', eperm);
  await refreshFindings(db, loadConfig(db), t, deps.execFile).catch(err => console.error('refreshFindings', err));
}

// hourly: tmutil state + measured watch paths into settings, then refresh findings
export async function backupTick(db, cfg, deps) {
  const t = deps.now();
  let tmState = { ts: t, configured: false, names: [], backupISO: null };
  try {
    const { stdout } = await deps.execFile('tmutil', ['destinationinfo']);
    const d = parseTmDestinations(String(stdout));
    tmState.configured = d.configured;
    tmState.names = d.names;
    if (d.configured) {
      try {
        const { stdout: out } = await deps.execFile('tmutil', ['latestbackup', '-t']);
        tmState.backupISO = parseTmLatest(String(out))?.backupISO ?? null;
      } catch {
        tmState.backupISO = null;   // error text → history unreadable
      }
    }
  } catch {
    // tmutil unavailable → configured:false (the machine's true state today)
  }
  setSetting(db, 'tmState', tmState);

  const stats = [];
  for (const w of cfg.backup.watchPaths) {
    const p = w.path.startsWith('~/') ? path.join(os.homedir(), w.path.slice(2)) : w.path;
    const m = await measure(p);
    stats.push({ path: p, newestMtime: m.newestMtime, maxAgeDays: w.maxAgeDays });
  }
  setSetting(db, 'watchStats', stats);
  await refreshFindings(db, loadConfig(db), t, deps.execFile).catch(err => console.error('refreshFindings', err));
}

async function readPremierePrefs(home) {
  try {
    const versions = await fs.promises.readdir(path.join(home, 'Documents/Adobe/Premiere Pro'));
    for (const v of versions) {
      try {
        const profiles = await fs.promises.readdir(path.join(home, 'Documents/Adobe/Premiere Pro', v));
        for (const prof of profiles) {
          if (!prof.startsWith('Profile-')) continue;
          return await fs.promises.readFile(
            path.join(home, 'Documents/Adobe/Premiere Pro', v, prof, 'Adobe Premiere Pro Prefs'), 'utf8'
          );
        }
      } catch { /* try next version dir */ }
    }
  } catch { /* no Premiere on this machine */ }
  return '';
}

export function startSampler(db, cfg, deps) {
  const { execFile, spawn, statfs } = deps;
  const listVolumes = deps.listVolumes
    || (() => { try { return fs.readdirSync('/Volumes'); } catch { return []; } });
  const realpath = deps.realpath || fs.realpathSync;
  const now = deps.now || Date.now;

  let stopped = false;
  let lastFront = null;
  let lastCpuLimit = null;
  let lastVolumes = new Set();
  const streams = [];

  const insertEvent = db.prepare('INSERT INTO events(ts, kind, key, detail) VALUES(?,?,?,?)');
  const insertProc = db.prepare('INSERT INTO proc_samples(ts, pid, name, cpu, rss_mb) VALUES(?,?,?,?,?)');
  const insertDisk = db.prepare('INSERT INTO disk_samples(ts, volume, free_gb, total_gb) VALUES(?,?,?,?)');

  function addEvent(kind, key, detail) {
    insertEvent.run(now(), kind, key, detail);
  }

  // a reconcile event is skipped if the stream already reported it moments ago
  function recentEvent(kind, key) {
    return db.prepare('SELECT 1 FROM events WHERE kind = ? AND key = ? AND ts > ?').get(kind, key, now() - RECENT_MS) !== undefined;
  }

  async function tick() {
    const t = now();
    const { stdout: psText } = await execFile('ps', ['-Aceo', 'pid,pcpu,rss,comm', '-r']);
    const rows = parsePs(psText).sort((a, b) => b.cpu - a.cpu);
    for (const [i, r] of rows.entries()) {
      const kept = (i < cfg.procKeepTop || r.rssMb >= cfg.procMinRssMb)
                && (r.cpu >= cfg.procMinCpu || r.rssMb >= cfg.procMinRssMb);
      if (kept) insertProc.run(t, r.pid, r.name, r.cpu, r.rssMb);
    }

    const { stdout: frontText } = await execFile('lsappinfo', ['front']);
    const asn = String(frontText).match(/0x[0-9a-f]+-[0-9a-f]+/i)?.[0];
    let frontName = null;
    if (asn) {
      const { stdout: infoText } = await execFile('lsappinfo', ['info', '-only', 'name', asn]);
      frontName = parseFrontAppName(infoText);
    }
    if (frontName && frontName !== lastFront) addEvent('front_app', frontName, '');
    lastFront = frontName;

    const { stdout: thermText } = await execFile('pmset', ['-g', 'therm']);
    const therm = parseTherm(thermText);
    if (therm.cpuSpeedLimit !== null && therm.cpuSpeedLimit !== lastCpuLimit) {
      addEvent('thermal', 'cpu_limit', String(therm.cpuSpeedLimit));
    }
    if (therm.cpuSpeedLimit !== null) lastCpuLimit = therm.cpuSpeedLimit;

    const vols = new Set(listVolumes());
    for (const v of vols) if (!lastVolumes.has(v) && !recentEvent('mount', v)) addEvent('mount', v, '');
    for (const v of lastVolumes) if (!vols.has(v) && !recentEvent('unmount', v)) addEvent('unmount', v, '');
    lastVolumes = vols;

    lastTickAt = t;
    await refreshFindings(db, loadConfig(db), t, execFile).catch(err => console.error('refreshFindings', err));
  }

  async function diskTick() {
    const t = now();
    const vols = [['Macintosh HD', '/']];
    for (const v of listVolumes()) {
      const p = `/Volumes/${v}`;
      try { if (realpath(p) !== '/') vols.push([v, p]); } catch { /* not mounted */ }
    }
    for (const [name, p] of vols) {
      const st = await statfs(p);
      insertDisk.run(t, name, st.bavail * st.bsize / GB, st.blocks * st.bsize / GB);
    }
    await refreshFindings(db, loadConfig(db), t, execFile).catch(err => console.error('refreshFindings', err));
  }

  function startStream(bin, args, onLine) {
    const respawn = () => { if (!stopped) setTimeout(() => startStream(bin, args, onLine), 60000); };
    let child;
    try {
      child = spawn(bin, args);
      child.stdout.setEncoding('utf8');
      let buf = '';
      child.stdout.on('data', c => {
        buf += c;
        let i;
        while ((i = buf.indexOf('\n')) >= 0) {
          onLine(buf.slice(0, i));
          buf = buf.slice(i + 1);
        }
      });
      child.on('error', respawn);
      child.on('exit', respawn);
      streams.push(child);
    } catch {
      respawn();
    }
  }

  // intervals only (unref'd so the HTTP server owns the process lifetime) — first data 30s after boot
  setInterval(() => tick().catch(err => console.error('tick', err)), cfg.tickSec * 1000).unref();
  setInterval(() => diskTick().catch(err => console.error('diskTick', err)), cfg.diskTickSec * 1000).unref();
  setInterval(() => cacheTick(db, cfg, deps).catch(err => console.error('cacheTick', err)), cfg.cacheTickSec * 1000).unref();
  setInterval(() => backupTick(db, cfg, deps).catch(err => console.error('backupTick', err)), 3600000).unref();
  setInterval(() => driftTick(db, cfg, deps).catch(err => console.error('driftTick', err)), 3600000).unref();
  setInterval(() => batteryTick(db, cfg, deps).catch(err => console.error('batteryTick', err)), 86400000).unref();
  setInterval(() => {
    try { sweep(db, cfg, now()); } catch (err) { console.error('sweep', err); }
    refreshFindings(db, loadConfig(db), now(), execFile).catch(err => console.error('refreshFindings', err));
  }, 3600000).unref();

  startStream('diskutil', ['activity'], line => {
    const p = parseDiskutilActivity(line);
    if (p) addEvent(p.kind === 'appeared' ? 'mount' : 'unmount', p.volume, '');
  });
  startStream('pmset', ['-g', 'thermlog'], line => {
    const p = parseThermlogLine(line);
    if (p) addEvent('thermal', 'thermlog', String(p.level));
  });

  function stop() {
    stopped = true;
    for (const c of streams) { try { c.kill(); } catch { /* already gone */ } }
  }

  return { tick, diskTick, cacheTick: () => cacheTick(db, cfg, deps), backupTick: () => backupTick(db, cfg, deps), driftTick: () => driftTick(db, cfg, deps), batteryTick: () => batteryTick(db, cfg, deps), stop };
}
