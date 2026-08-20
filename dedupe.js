// dedupe.js — on-demand exact-duplicate scan. One job at a time.
// Stream hashing only — never readFileSync on media files (candidates can be GBs).
// Pipeline: walk → size buckets (≥ cfg.dup.minMb) → 128 KB head+tail partial SHA-256
// → full-stream SHA-256 for survivors. Results replace the prior scan in dup_groups.
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { stat, open, readdir } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';

const MB = 1048576;
const PARTIAL = 128 * 1024;   // head + tail each

let job = null;   // {id, state:'running'|'done'|'error', scanned, groups, startedAt, error}

export function startScan(roots, cfg, deps = {}) {
  if (job && job.state === 'running') throw new Error('scan already running');
  const db = deps.db ?? null;
  const hasher = deps.hasher ?? { partial: partialHash, full: fullHash };
  const current = { id: `scan-${Date.now()}`, state: 'running', scanned: 0, groups: [], startedAt: Date.now(), error: null };
  job = current;
  runScan(roots, cfg, current, db, hasher).catch(err => {
    current.state = 'error';
    current.error = String(err && err.message || err);
  });
  return current.id;
}

export function scanStatus() {
  return job ?? { state: 'idle', scanned: 0, groups: [], startedAt: null, error: null };
}

export async function partialHash(file, size) {
  const h = createHash('sha256');
  const fh = await open(file, 'r');
  try {
    const headLen = Math.min(PARTIAL, size);
    const head = Buffer.alloc(headLen);
    await fh.read(head, 0, headLen, 0);
    h.update(head);
    if (size > headLen) {
      const tailLen = Math.min(PARTIAL, size - headLen);
      const tail = Buffer.alloc(tailLen);
      await fh.read(tail, 0, tailLen, size - tailLen);
      h.update(tail);
    }
  } finally {
    await fh.close();
  }
  return h.digest('hex');
}

export async function fullHash(file) {
  const h = createHash('sha256');
  await new Promise((resolve, reject) => {
    const s = createReadStream(file);
    s.on('data', c => h.update(c));
    s.on('end', resolve);
    s.on('error', reject);
  });
  return h.digest('hex');
}

async function runScan(roots, cfg, current, db, hasher) {
  const minBytes = cfg.dup.minMb * MB;
  const bySize = new Map();
  for (const root of roots) {
    for await (const f of walk(root, minBytes)) {
      if (!bySize.has(f.size)) bySize.set(f.size, []);
      bySize.get(f.size).push(f.path);
    }
  }

  const partialGroups = new Map();
  for (const [size, files] of bySize) {
    if (files.length < 2) continue;
    for (const file of files) {
      current.scanned += 1;
      const h = await hasher.partial(file, size);
      if (!partialGroups.has(h)) partialGroups.set(h, { files: [], size });
      partialGroups.get(h).files.push(file);
    }
  }

  const groups = [];
  for (const g of partialGroups.values()) {
    if (g.files.length < 2) continue;
    const byFull = new Map();
    for (const file of g.files) {
      const h = await hasher.full(file);
      if (!byFull.has(h)) byFull.set(h, []);
      byFull.get(h).push(file);
    }
    for (const [hash, paths] of byFull) {
      if (paths.length >= 2) {
        groups.push({ hash, sizeMb: Math.round(g.size / MB), paths: paths.sort() });
      }
    }
  }
  current.groups = groups.sort((a, b) => wasted(b) - wasted(a));
  if (db) {
    db.prepare('DELETE FROM dup_groups').run();
    const ins = db.prepare('INSERT INTO dup_groups(scan_ts, hash, size_mb, paths) VALUES(?,?,?,?)');
    for (const g of current.groups) ins.run(current.startedAt, g.hash, g.sizeMb, JSON.stringify(g.paths));
  }
  current.state = 'done';
}

function wasted(g) {
  return g.sizeMb * (g.paths.length - 1);
}

async function* walk(root, minBytes) {
  const home = os.homedir();
  const username = home.split('/').filter(Boolean).pop();
  const stack = [root];
  while (stack.length) {
    const dir = stack.pop();
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      continue;   // unreadable → skip
    }
    for (const e of entries) {
      const p = path.join(dir, e.name);
      if (e.name.startsWith('.')) continue;      // dotfiles/dirs
      if (e.isSymbolicLink()) continue;
      if (e.isDirectory()) {
        if (skipDir(p, home, username)) continue;
        stack.push(p);
      } else if (e.isFile()) {
        try {
          const st = await stat(p);
          if (st.size >= minBytes) yield { path: p, size: st.size };
        } catch {
          // raced: file vanished mid-walk
        }
      }
    }
  }
}

function skipDir(p, home, username) {
  if (p === path.join(home, 'Library')) return true;   // caches/plists — outside the cache registry
  const parts = p.split(path.sep).filter(Boolean);
  if (parts[0] === 'Users' && parts[1] && parts[1] !== username) return true;   // other users' homes
  if (parts.length === 1 && (parts[0] === 'System' || parts[0] === 'private')) return true;
  return false;
}
