// db.js — node:sqlite open, exact schema, retention sweep, settings helpers
import { DatabaseSync } from 'node:sqlite';

const SCHEMA = `
CREATE TABLE IF NOT EXISTS proc_samples(
  ts INTEGER NOT NULL, pid INTEGER NOT NULL, name TEXT NOT NULL,
  cpu REAL NOT NULL, rss_mb INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS idx_proc_ts ON proc_samples(ts);
CREATE INDEX IF NOT EXISTS idx_proc_name ON proc_samples(name, ts);
CREATE TABLE IF NOT EXISTS disk_samples(
  ts INTEGER NOT NULL, volume TEXT NOT NULL, free_gb REAL NOT NULL, total_gb REAL NOT NULL);
CREATE INDEX IF NOT EXISTS idx_disk ON disk_samples(volume, ts);
CREATE TABLE IF NOT EXISTS cache_samples(
  ts INTEGER NOT NULL, cache_id TEXT NOT NULL, path TEXT NOT NULL,
  size_mb INTEGER NOT NULL, newest_mtime INTEGER, file_count INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS idx_cache ON cache_samples(cache_id, ts);
CREATE TABLE IF NOT EXISTS events(
  ts INTEGER NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '');
CREATE INDEX IF NOT EXISTS idx_events ON events(kind, ts);
CREATE TABLE IF NOT EXISTS findings(
  id TEXT PRIMARY KEY, kind TEXT NOT NULL,
  severity TEXT NOT NULL CHECK(severity IN ('info','amber','red')),
  headline TEXT NOT NULL, why TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '',
  link_kind TEXT, link_target TEXT,
  first_seen INTEGER NOT NULL, updated INTEGER NOT NULL, last_notified INTEGER);
CREATE TABLE IF NOT EXISTS dup_groups(
  scan_ts INTEGER NOT NULL, hash TEXT NOT NULL, size_mb INTEGER NOT NULL, paths TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
`;

export function openDb(path) {
  const db = new DatabaseSync(path);
  db.exec('PRAGMA journal_mode = WAL;');
  db.exec(SCHEMA);
  return db;
}

// retention deletes; dup_groups keeps the latest scan only
export function sweep(db, cfg, now) {
  const day = 86400000;
  const del = (table, days) => db.prepare(`DELETE FROM ${table} WHERE ts < ?`).run(now - days * day);
  del('proc_samples', cfg.retentionDays.proc);
  del('disk_samples', cfg.retentionDays.disk);
  del('cache_samples', cfg.retentionDays.cache);
  del('events', cfg.retentionDays.events);
  db.prepare('DELETE FROM dup_groups WHERE scan_ts < (SELECT MAX(scan_ts) FROM dup_groups)').run();
}

export function getSetting(db, k) {
  const row = db.prepare('SELECT value FROM settings WHERE key = ?').get(k);
  return row === undefined ? undefined : JSON.parse(row.value);
}
export function setSetting(db, k, v) {
  db.prepare(
    'INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value'
  ).run(k, JSON.stringify(v));
}
export function allSettings(db) {
  return Object.fromEntries(
    db.prepare('SELECT key, value FROM settings').all().map(r => [r.key, JSON.parse(r.value)])
  );
}
