// server.js — HTTP on 127.0.0.1:7420: static + /api/*. Advisory-only app; never the LAN, never *.db*.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { openDb } from './db.js';

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
    if (req.method === 'GET') return serveStatic(req, res, p === '/' ? 'index.html' : p.slice(1));
    return json(res, 404, { error: 'not found' });
  } catch (err) {
    json(res, 500, { error: String(err && err.message || err) });
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`performac on http://127.0.0.1:${PORT}`);
});
