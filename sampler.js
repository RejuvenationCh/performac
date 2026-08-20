// sampler.js — 30s tick loop + two long-running event streams. Writes samples/events;
// no parsing logic here (that lives in collectors.js). All spawns via injected deps
// so tests never touch real binaries. deps.execFile resolves {stdout}; deps.statfs
// resolves the fs.statfs object; deps.now() returns ms.
import fs from 'node:fs';
import {
  parsePs, parseFrontAppName, parseTherm, parseThermlogLine, parseDiskutilActivity,
} from './collectors.js';
import { sweep } from './db.js';

let lastTickAt = null;
export function lastTick() {
  return lastTickAt;
}

// rules arrive per-feature (Task 6+). Task 5 keeps the shell.
export async function refreshFindings() {
  return [];
}

const GB = 1073741824;
const RECENT_MS = 5000;   // reconcile dedupes against stream events newer than this

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
    await refreshFindings(db, cfg, t).catch(err => console.error('refreshFindings', err));
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
    await refreshFindings(db, cfg, t).catch(err => console.error('refreshFindings', err));
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
  setInterval(() => {
    try { sweep(db, cfg, now()); } catch (err) { console.error('sweep', err); }
    refreshFindings(db, cfg, now()).catch(err => console.error('refreshFindings', err));
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

  return { tick, diskTick, stop };
}
