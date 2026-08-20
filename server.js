// server.js — HTTP on 127.0.0.1:7420: static + /api/*. Advisory-only app; never the LAN, never *.db*.
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { execFile, spawn } from 'node:child_process';
import { openDb } from './db.js';
import { loadConfig } from './config.js';
import { startSampler, lastTick, findingsGeneratedAt } from './sampler.js';
import { startScan, scanStatus } from './dedupe.js';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const PORT = 7420;
const db = openDb(path.join(ROOT, 'performac.db'));
const startedAt = Date.now();

const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.png': 'image/png', '.svg': 'image/svg+xml', '.webmanifest': 'application/manifest+json; charset=utf-8',
};

function json(res, code, obj) {
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-cache' });
  res.end(JSON.stringify(obj));
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', c => {
      body += c;
      if (body.length > 1e6) { reject(new Error('body too large')); req.destroy(); }
    });
    req.on('end', () => {
      try { resolve(body ? JSON.parse(body) : {}); } catch { reject(new Error('bad json')); }
    });
    req.on('error', reject);
  });
}

function rowCount(table) {
  return db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n; // table names are literals here
}

function serveStatic(req, res, pathname) {
  if (pathname.includes('.db')) return json(res, 404, { error: 'not found' });
  const publicDir = path.join(ROOT, 'public');
  const file = path.normalize(path.join(publicDir, pathname));
  if (!file.startsWith(publicDir + path.sep)) return json(res, 404, { error: 'not found' });
  fs.readFile(file, (err, data) => {
    if (err) return json(res, 404, { error: 'not found' });
    res.writeHead(200, {
      'Content-Type': MIME[path.extname(file)] || 'application/octet-stream',
      'Cache-Control': 'no-cache',
    });
    res.end(data);
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const p = decodeURIComponent(url.pathname);
  try {
    if (req.method === 'GET' && p === '/api/health') {
      return json(res, 200, {
        ok: true,
        uptimeSec: Math.floor((Date.now() - startedAt) / 1000),
        lastTick: lastTick(),
        dbRows: {
          proc_samples: rowCount('proc_samples'),
          disk_samples: rowCount('disk_samples'),
          cache_samples: rowCount('cache_samples'),
          events: rowCount('events'),
          findings: rowCount('findings'),
          dup_groups: rowCount('dup_groups'),
          settings: rowCount('settings'),
        },
      });
    }
    if (req.method === 'GET' && p === '/api/findings') {
      const rows = db.prepare('SELECT * FROM findings ORDER BY updated DESC').all()
        .map(r => ({
          id: r.id, kind: r.kind, severity: r.severity, headline: r.headline, why: r.why,
          detail: r.detail, linkKind: r.link_kind, linkTarget: r.link_target, updated: r.updated,
        }));
      const liveKinds = new Set(['drive', 'thermal', 'backup']);
      return json(res, 200, {
        live: rows.filter(r => liveKinds.has(r.kind)),
        digest: rows,
        generatedAt: findingsGeneratedAt(),
        coachIntro: null,
        dupScan: db.prepare('SELECT MAX(scan_ts) m FROM dup_groups').get().m ?? null,
      });
    }
    if (req.method === 'GET' && p === '/api/trends') {
      const days = Math.min(Math.max(parseInt(url.searchParams.get('days') || '30', 10) || 30, 1), 365);
      const since = Date.now() - days * 86400000;
      return json(res, 200, {
        disk: db.prepare('SELECT ts, volume, free_gb FROM disk_samples WHERE ts > ? ORDER BY ts').all(since)
          .map(r => ({ ts: r.ts, volume: r.volume, freeGb: r.free_gb })),
        caches: db.prepare('SELECT ts, cache_id, size_mb FROM cache_samples WHERE ts > ? ORDER BY ts').all(since)
          .map(r => ({ ts: r.ts, cacheId: r.cache_id, sizeMb: r.size_mb })),
      });
    }
    if (req.method === 'GET' && p === '/api/dedupe') {
      const st = scanStatus();
      const rows = st.state === 'idle'
        ? db.prepare('SELECT hash, size_mb, paths FROM dup_groups').all()
        : null;
      return json(res, 200, {
        state: st.state,
        scanned: st.scanned,
        groups: rows ? rows.map(r => ({ hash: r.hash, sizeMb: r.size_mb, paths: JSON.parse(r.paths) })) : st.groups,
        startedAt: st.startedAt,
        lastScan: db.prepare('SELECT MAX(scan_ts) m FROM dup_groups').get().m ?? null,
        roots: ['~', ...(fs.existsSync('/Volumes') ? fs.readdirSync('/Volumes').map(v => `/Volumes/${v}`) : [])],
      });
    }
    if (req.method === 'POST' && p === '/api/dedupe') {
      const origin = req.headers.origin;
      if (origin && !['http://localhost:7420', 'http://127.0.0.1:7420'].includes(origin)) {
        return json(res, 403, { error: 'bad origin' });
      }
      if (!(req.headers['content-type'] || '').includes('application/json')) {
        return json(res, 415, { error: 'expected application/json' });
      }
      let body;
      try {
        body = await readJson(req);
      } catch (err) {
        return json(res, 400, { error: err.message });
      }
      if (!Array.isArray(body.roots) || !body.roots.length) {
        return json(res, 400, { error: 'roots must be a non-empty array' });
      }
      const roots = [];
      for (let r of body.roots) {
        if (typeof r !== 'string' || !r.trim()) return json(res, 400, { error: 'bad root' });
        if (r.startsWith('~')) r = path.join(os.homedir(), r.slice(1));
        if (!path.isAbsolute(r)) return json(res, 400, { error: 'root must be absolute' });
        try {
          fs.statSync(r);
        } catch {
          return json(res, 400, { error: `not found: ${r}` });
        }
        roots.push(r);
      }
      try {
        const jobId = startScan(roots, cfg, { db });
        return json(res, 200, { started: true, jobId });
      } catch (err) {
        return json(res, 409, { error: err.message });
      }
    }
    if (req.method === 'POST' && (p === '/api/reveal' || p === '/api/open')) {
      const origin = req.headers.origin;
      if (origin && !['http://localhost:7420', 'http://127.0.0.1:7420'].includes(origin)) {
        return json(res, 403, { error: 'bad origin' });
      }
      if (!(req.headers['content-type'] || '').includes('application/json')) {
        return json(res, 415, { error: 'expected application/json' });
      }
      let body;
      try {
        body = await readJson(req);
      } catch (err) {
        return json(res, 400, { error: err.message });
      }
      if (p === '/api/open') {
        const args = { purge: ['-b', 'io.getpurge.app'], 'activity-monitor': ['-a', 'Activity Monitor'] }[body.target];
        if (!args) return json(res, 400, { error: 'unknown target' });
        execFile('open', args, err => { if (err) console.error('[open]', err.message); });
        return json(res, 200, { ok: true });
      }
      // /api/reveal — Attention Dashboard's pattern: same-origin JSON, ~ expansion, statSync, no shell
      let target = String(body.path || '');
      try {
        if (target.startsWith('~')) target = path.join(os.homedir(), target.slice(1));
        if (!path.isAbsolute(target)) throw new Error('path must be absolute');
        const st = fs.statSync(target);   // throws if missing
        execFile('open', st.isDirectory() ? [target] : ['-R', target], err => {
          if (err) console.error('[reveal]', err.message);
        });
        return json(res, 200, { ok: true });
      } catch (err) {
        return json(res, 400, { error: err.code === 'ENOENT' ? `not found: ${target}` : err.message });
      }
    }
    if (req.method === 'GET') return serveStatic(req, res, p === '/' ? 'index.html' : p.slice(1));
    return json(res, 404, { error: 'not found' });
  } catch (err) {
    json(res, 500, { error: String(err && err.message || err) });
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`performac on http://127.0.0.1:${PORT}`);
});

const cfg = loadConfig(db);
const sampler = startSampler(db, cfg, {
  execFile: promisify(execFile),
  spawn,
  statfs: promisify(fs.statfs),
  listVolumes: () => { try { return fs.readdirSync('/Volumes'); } catch { return []; } },
  realpath: fs.realpathSync,
});
for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => { sampler.stop(); process.exit(0); });
}
