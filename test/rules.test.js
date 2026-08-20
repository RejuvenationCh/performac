// rules tests — cacheGrowth, thermalDuringExport (further rules arrive per-feature)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cacheGrowth, thermalDuringExport, driveInstability, backupStaleness, dupFindings } from '../rules.js';

const DAY = 86400000;
const NOW = 1756000000000;
const cfg = { cacheRules: { amberGb: 5, redGb: 20, staleDays: 21 } };
const tcfg = {
  exportProcs: ['Adobe Premiere Pro', 'Adobe Media Encoder', 'PProHeadless', 'Resolve', 'Compressor', 'Blackmagic Proxy Generator'],
  export: { cpuPct: 150, minMinutes: 10 },
  thermal: { minElevatedMinutes: 10 },
};

// proc samples every 30s from T0 for `minutes`, cpu alternating between lo and hi
function exportSamples(name, t0, minutes, lo, hi) {
  const rows = [];
  for (let i = 0; i * 30000 < minutes * 60000; i++) {
    rows.push({ ts: t0 + i * 30000, pid: 1, name, cpu: i % 2 ? hi : lo, rss_mb: 500 });
  }
  return rows;
}

function thermEvent(t0, level) {
  return { ts: t0, kind: 'thermal', key: 'thermlog', detail: String(level) };
}

function samples(...specs) {
  return specs.map(([daysAgo, sizeGb, mtimeDaysAgo]) => ({
    ts: NOW - daysAgo * DAY,
    cache_id: 'premiere-media',
    path: '/test/Media Cache Files',
    size_mb: Math.round(sizeGb * 1024),
    newest_mtime: NOW - mtimeDaysAgo * DAY,
    file_count: 100,
  }));
}

test('stale 38 GB cache → one red finding, exact headline, growth why, reveal link, in-app route', () => {
  const fs = cacheGrowth(samples([30, 32, 30], [7, 36, 30], [0, 38, 24]), cfg, NOW);
  assert.equal(fs.length, 1);
  const f = fs[0];
  assert.equal(f.severity, 'red');
  assert.equal(f.headline, `Premiere's media cache is 38.0 GB and hasn't been written to in 24 days`);
  assert.ok(f.why.includes('grew 2.0 GB in the last 7 days'), f.why);
  assert.equal(f.linkKind, 'reveal');
  assert.equal(f.linkTarget, '/test/Media Cache Files');
  assert.ok(f.detail.includes('Settings → Media Cache'), f.detail);
});

test('2 GB fresh cache → no finding', () => {
  assert.deepEqual(cacheGrowth(samples([0, 2, 0]), cfg, NOW), []);
});

test('6 GB written yesterday → info, in active use', () => {
  const fs = cacheGrowth(samples([0, 6, 1]), cfg, NOW);
  assert.equal(fs.length, 1);
  assert.equal(fs[0].severity, 'info');
  assert.ok(fs[0].why.includes('in active use — leave it'), fs[0].why);
});

test('cache 15 days old, under the stale line → info but honest about age', () => {
  const fs = cacheGrowth(samples([0, 6, 15]), cfg, NOW);
  assert.equal(fs.length, 1);
  assert.equal(fs[0].severity, 'info');
  assert.ok(fs[0].why.includes('still under your 21-day staleness line'), fs[0].why);
  assert.ok(!fs[0].why.includes('in active use'), fs[0].why);
});

test('stale mid-size cache → amber', () => {
  const fs = cacheGrowth(samples([0, 8, 30]), cfg, NOW);
  assert.equal(fs.length, 1);
  assert.equal(fs[0].severity, 'amber');
  assert.ok(fs[0].headline.includes("hasn't been written to in 30 days"));
});

test('no growth sample a week ago → why falls back to age-only', () => {
  const fs = cacheGrowth(samples([0, 38, 24]), cfg, NOW);
  assert.equal(fs.length, 1);
  assert.ok(!fs[0].why.includes('grew'), fs[0].why);
});

test('thermal overlapping an export window → amber finding, export length + peak CPU cited', () => {
  const T0 = NOW;
  const procs = exportSamples('Adobe Media Encoder 2026', T0, 40, 320, 480);
  const therm = [thermEvent(T0 + 10 * 60000, 1), thermEvent(T0 + 28 * 60000, 0)];
  const fs = thermalDuringExport(procs, therm, tcfg, T0 + 40 * 60000);
  assert.equal(fs.length, 1);
  const f = fs[0];
  assert.equal(f.severity, 'amber');
  assert.equal(f.headline, 'Thermal pressure ran elevated for 18 min during your Adobe Media Encoder 2026 export');
  assert.ok(f.why.includes('40 min') && f.why.includes('480%'), f.why);
  assert.equal(f.linkKind, null);
  assert.ok(f.detail.includes('fan'), f.detail);
});

test('elevated ≥ 30 min → red', () => {
  const T0 = NOW;
  const procs = exportSamples('Adobe Media Encoder 2026', T0, 40, 400, 400);
  const therm = [thermEvent(T0 + 2 * 60000, 1), thermEvent(T0 + 38 * 60000, 0)];
  const fs = thermalDuringExport(procs, therm, tcfg, T0 + 40 * 60000);
  assert.equal(fs.length, 1);
  assert.equal(fs[0].severity, 'red');
});

test('level ≥ 2 → red even when short', () => {
  const T0 = NOW;
  const procs = exportSamples('Adobe Media Encoder 2026', T0, 40, 400, 400);
  const therm = [thermEvent(T0 + 2 * 60000, 2), thermEvent(T0 + 14 * 60000, 0)];
  const fs = thermalDuringExport(procs, therm, tcfg, T0 + 40 * 60000);
  assert.equal(fs.length, 1);
  assert.equal(fs[0].severity, 'red');
});

test('no thermal events during an export → no finding (absence of data ≠ finding)', () => {
  const T0 = NOW;
  const procs = exportSamples('Adobe Media Encoder 2026', T0, 40, 400, 400);
  assert.deepEqual(thermalDuringExport(procs, [], tcfg, T0 + 40 * 60000), []);
});

test('thermal with no export window → no finding (ambient throttling, not workflow-tied)', () => {
  const T0 = NOW;
  const procs = exportSamples('Zen', T0, 40, 10, 20);
  const therm = [thermEvent(T0 + 2 * 60000, 1), thermEvent(T0 + 38 * 60000, 0)];
  assert.deepEqual(thermalDuringExport(procs, therm, tcfg, T0 + 40 * 60000), []);
});

test('gap ≥ 2 min splits windows; sub-10-min segments produce nothing', () => {
  const T0 = NOW;
  const a = exportSamples('Adobe Media Encoder 2026', T0, 9, 400, 400);
  const b = exportSamples('Adobe Media Encoder 2026', T0 + 11.5 * 60000, 9, 400, 400); // 2.5 min gap
  const therm = [thermEvent(T0, 1), thermEvent(T0 + 25 * 60000, 0)];
  assert.deepEqual(thermalDuringExport([...a, ...b], therm, tcfg, T0 + 25 * 60000), []);
});

test('gap < 2 min merges segments into one window', () => {
  const T0 = NOW;
  const a = exportSamples('Adobe Media Encoder 2026', T0, 9, 400, 400);          // ends at +8.5 min
  const b = exportSamples('Adobe Media Encoder 2026', T0 + 10 * 60000, 9, 400, 400); // 1.5 min gap
  const therm = [thermEvent(T0 + 1 * 60000, 1), thermEvent(T0 + 19 * 60000, 0)];
  const fs = thermalDuringExport([...a, ...b], therm, tcfg, T0 + 25 * 60000);
  assert.equal(fs.length, 1);
  assert.ok(fs[0].headline.includes('18 min'), fs[0].headline);
});

const dcfg = { drive: { cycles24h: 2, cycles7d: 3 } };
const H = 3600000;

function driveEvent(ts, kind, vol) {
  return { ts, kind, key: vol, detail: '' };
}

function pair(ts, vol = 'T7', gapMin = 5) {
  return [driveEvent(ts, 'unmount', vol), driveEvent(ts + gapMin * 60000, 'mount', vol)];
}

test('3 reconnect cycles in 24h → red, exact headline and why', () => {
  const events = [
    driveEvent(NOW - 26 * H, 'mount', 'Macintosh HD'),   // boot noise, no unmount → ignored
    ...pair(NOW - 20 * H), ...pair(NOW - 6 * H), ...pair(NOW - 1 * H),
  ];
  const fs = driveInstability(events, dcfg, NOW);
  assert.equal(fs.length, 1);
  assert.equal(fs[0].severity, 'red');
  assert.equal(fs[0].headline, 'T7 disconnected and reconnected 3 times in the last 24 hours');
  assert.equal(fs[0].why, 'A loose cable, failing port, or failing drive shows up as surprise unmount cycles — check the connection before your next shoot');
  assert.equal(fs[0].linkKind, null);
});

test('2 cycles spread over 7 days → no finding (under cycles7d)', () => {
  const events = [...pair(NOW - 6 * 86400000), ...pair(NOW - 3 * 86400000)];
  assert.deepEqual(driveInstability(events, dcfg, NOW), []);
});

test('single unmount, no remount → no finding (user ejected and left)', () => {
  const events = [driveEvent(NOW - 2 * H, 'unmount', 'T7')];
  assert.deepEqual(driveInstability(events, dcfg, NOW), []);
});

test('unmount + mount 40 min later → not a cycle (reappearance must be within 30 min)', () => {
  const events = [driveEvent(NOW - 2 * H, 'unmount', 'T7'), driveEvent(NOW - 2 * H + 40 * 60000, 'mount', 'T7')];
  assert.deepEqual(driveInstability(events, dcfg, NOW), []);
});

test('4+ cycles over 7 days (≤ 24h threshold) → amber', () => {
  const events = [
    ...pair(NOW - 6 * 86400000), ...pair(NOW - 5 * 86400000),
    ...pair(NOW - 4 * 86400000), ...pair(NOW - 3 * 86400000),
  ];
  const fs = driveInstability(events, dcfg, NOW);
  assert.equal(fs.length, 1);
  assert.equal(fs[0].severity, 'amber');
  assert.ok(fs[0].headline.includes('in the last 7 days'));
});

const bcfg = { backup: { maxAgeDays: 7 } };

test('no TM destination → red, the machine\'s real day-one card', () => {
  const fs = backupStaleness({ configured: false, names: [], backupISO: null }, [], bcfg, NOW);
  assert.equal(fs.length, 1);
  assert.equal(fs[0].severity, 'red');
  assert.equal(fs[0].headline, 'No Time Machine destination is configured on this Mac');
  assert.equal(fs[0].why, 'Your event and campus footage has no re-shoot option — a Mac that has never been backed up is one drive failure from losing all of it');
  assert.equal(fs[0].linkKind, null);
  assert.ok(fs[0].detail.includes('System Settings'), fs[0].detail);
});

test('last backup 12 days old → red with destination cited', () => {
  const iso = new Date(NOW - 12 * DAY).toISOString();
  const fs = backupStaleness({ configured: true, names: ['T7 Backup'], backupISO: iso }, [], bcfg, NOW);
  assert.equal(fs.length, 1);
  assert.equal(fs[0].severity, 'red');
  assert.equal(fs[0].headline, 'Your last Time Machine backup is 12 days old');
  assert.ok(fs[0].why.includes('T7 Backup'), fs[0].why);
});

test('backup 3 days old → no finding', () => {
  const iso = new Date(NOW - 3 * DAY).toISOString();
  assert.deepEqual(backupStaleness({ configured: true, names: ['T7 Backup'], backupISO: iso }, [], bcfg, NOW), []);
});

test('destination exists but history unreadable → honest info card with manual check', () => {
  const fs = backupStaleness({ configured: true, names: ['T7 Backup'], backupISO: null }, [], bcfg, NOW);
  assert.equal(fs.length, 1);
  assert.equal(fs[0].severity, 'info');
  assert.ok(fs[0].detail.includes('tmutil latestbackup'), fs[0].detail);
  assert.ok(fs[0].detail.includes('does not request'), fs[0].detail);
});

test('watched backup path over its age limit → amber with reveal link', () => {
  const watchStats = [{
    path: '/Users/you/Movies/Resolve Project Backups',
    newestMtime: NOW - 20 * DAY,
    maxAgeDays: 14,
  }];
  const fs = backupStaleness({ configured: true, names: ['T7 Backup'], backupISO: new Date(NOW - 3 * DAY).toISOString() }, watchStats, bcfg, NOW);
  assert.equal(fs.length, 1);
  assert.equal(fs[0].severity, 'amber');
  assert.ok(fs[0].headline.includes('Resolve Project Backups') && fs[0].headline.includes('20 days'), fs[0].headline);
  assert.equal(fs[0].linkKind, 'reveal');
  assert.equal(fs[0].linkTarget, '/Users/you/Movies/Resolve Project Backups');
});

test('watched path fresh → no finding', () => {
  const watchStats = [{ path: '/x', newestMtime: NOW - DAY, maxAgeDays: 14 }];
  assert.deepEqual(backupStaleness({ configured: true, names: [], backupISO: new Date(NOW).toISOString() }, watchStats, bcfg, NOW), []);
});

test('dupFindings: 2 copies → info; 3 copies → amber; sorted by wasted bytes', () => {
  const groups = [
    { hash: 'a'.repeat(64), sizeMb: 300, paths: ['/x/1', '/y/2'] },
    { hash: 'b'.repeat(64), sizeMb: 4301, paths: ['/x/a', '/y/b', '/z/c'] },   // 4.2 GB × 3
    { hash: 'c'.repeat(64), sizeMb: 50, paths: ['/x/i', '/y/j'] },
  ];
  const fs = dupFindings(groups, { dup: { minMb: 100 } });
  assert.equal(fs.length, 3);
  assert.ok(fs[0].headline.includes('4.2 GB file exists in 3 places'), fs[0].headline);
  assert.equal(fs[0].severity, 'amber');
  assert.ok(fs[0].why.includes('byte-for-byte match (SHA-256)'), fs[0].why);
  assert.equal(fs[0].linkKind, 'reveal');
  assert.equal(fs[0].linkTarget, '/x/a');
  assert.equal(fs[1].headline, 'The same 300 MB file exists in 2 places');
  assert.equal(fs[1].severity, 'info');
  assert.ok(fs[0].detail.includes('/z/c'), fs[0].detail);
});

test('dupFindings: empty → empty', () => {
  assert.deepEqual(dupFindings([], { dup: { minMb: 100 } }), []);
});

test('generic safe cache stale 30 d → amber with Open Purge link-out', () => {
  const genCfg = { cacheRules: { amberGb: 2, redGb: 20, staleDays: 21 } };
  const rows = [{
    ts: NOW, cache_id: 'gen-npm', path: '/x/npm',
    size_mb: 3072, newest_mtime: NOW - 30 * DAY, file_count: 10,
  }];
  const fs = cacheGrowth(rows, genCfg, NOW);
  assert.equal(fs.length, 1);
  assert.equal(fs[0].severity, 'amber');
  assert.equal(fs[0].linkKind, 'open_purge');
  assert.ok(fs[0].headline.includes("npm's cache"), fs[0].headline);
  assert.ok(fs[0].headline.includes('30 days'), fs[0].headline);
});

test('generic check-first cache → reveal link, browser rebuild note', () => {
  const genCfg = { cacheRules: { amberGb: 2, redGb: 20, staleDays: 21 } };
  const rows = [{
    ts: NOW, cache_id: 'gen-zen', path: '/x/zen',
    size_mb: 3072, newest_mtime: NOW - 40 * DAY, file_count: 10,
  }];
  const fs = cacheGrowth(rows, genCfg, NOW);
  assert.equal(fs.length, 1);
  assert.equal(fs[0].severity, 'amber');
  assert.equal(fs[0].linkKind, 'reveal');
  assert.ok(fs[0].detail.toLowerCase().includes('rebuild'), fs[0].detail);
});
