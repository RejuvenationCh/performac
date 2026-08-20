// rules tests — cacheGrowth, thermalDuringExport (further rules arrive per-feature)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cacheGrowth, thermalDuringExport, driveInstability, backupStaleness, dupFindings, sustainedHogs, idleLoaded, storageTrend, drift, loginItemsAudit, batteryTrend, browserBloat } from '../rules.js';

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

// sleep/wake: a nap makes the volume disappear and reappear — byte-for-byte the same
// pattern as a failing cable. The sampler records a sleep_gap event {ts: wake tick,
// detail: pre-sleep tick ms} when the wall clock jumps ≥ 3× tickSec between ticks.
function sleepGap(start, end) {
  return { ts: end, kind: 'sleep_gap', key: 'sleep_gap', detail: String(start) };
}

test('3 pairs straddling sleep gaps → all suppressed (MacBook nap, not a failing cable)', () => {
  const gapStarts = [NOW - 20 * H, NOW - 6 * H, NOW - H];
  const events = [
    ...pair(gapStarts[0] + 1000, 'T7', 10),          // 10-min nap: fits the 30-min cycle window
    sleepGap(gapStarts[0], gapStarts[0] + 10 * 60000 + 30000),
    ...pair(gapStarts[1] + 1000, 'T7', 10),
    sleepGap(gapStarts[1], gapStarts[1] + 10 * 60000 + 30000),
    ...pair(gapStarts[2] + 1000, 'T7', 10),
    sleepGap(gapStarts[2], gapStarts[2] + 10 * 60000 + 30000),
  ];
  assert.deepEqual(driveInstability(events, dcfg, NOW), []);
});

test('awake pair with a gap far in the past → still fires (gap only suppresses straddlers)', () => {
  const oldGap = NOW - 24 * H;
  const events = [
    sleepGap(oldGap, oldGap + 600000),
    ...pair(NOW - 20 * H), ...pair(NOW - 6 * H), ...pair(NOW - H),
  ];
  const fs = driveInstability(events, dcfg, NOW);
  assert.equal(fs.length, 1, 'cable-jostle cycles while awake must still alarm');
  assert.equal(fs[0].severity, 'red');
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

const hcfg = {
  tickSec: 30,
  hog: { cpuPct: 80, minMinutes: 30, lookbackHours: 24,
         ignore: ['kernel_task', 'WindowServer', 'launchd', 'mds_stores', 'backupd'] },
  exportProcs: ['Adobe Premiere Pro', 'Adobe Media Encoder', 'PProHeadless', 'Resolve', 'Compressor', 'Blackmagic Proxy Generator'],
  export: { cpuPct: 150, minMinutes: 10 },
  idle: { rssMb: 800, hours: 12 },
};

function hogSamples(name, minutes, lo, hi, t0 = NOW) {
  const rows = [];
  for (let i = 0; i * 30000 <= minutes * 60000; i++) {
    rows.push({ ts: t0 + i * 30000, pid: 1, name, cpu: i % 2 ? hi : lo, rss_mb: 500 });
  }
  return rows;
}

test('35 min at ~92% CPU → amber hog with Activity Monitor link', () => {
  const fs = sustainedHogs(hogSamples('RobloxPlayer', 35, 88, 96), hcfg, NOW);
  assert.equal(fs.length, 1);
  assert.equal(fs[0].severity, 'amber');
  assert.equal(fs[0].headline, 'RobloxPlayer has averaged 92% CPU for 35 minutes');
  assert.ok(fs[0].why.includes('not a momentary spike'), fs[0].why);
  assert.equal(fs[0].linkKind, 'open_activity_monitor');
});

test('20 min → no hog finding', () => {
  assert.deepEqual(sustainedHogs(hogSamples('RobloxPlayer', 20, 88, 96), hcfg, NOW), []);
});

test('ignore list respected', () => {
  assert.deepEqual(sustainedHogs(hogSamples('kernel_task', 40, 90, 90), hcfg, NOW), []);
});

test('export-class proc during an export window → excluded (an export is supposed to eat CPU)', () => {
  const fs = sustainedHogs(hogSamples('Adobe Media Encoder 2026', 40, 300, 400), hcfg, NOW);
  assert.deepEqual(fs, []);
});

test('export-class proc below export.cpuPct → still flagged as hog', () => {
  const fs = sustainedHogs(hogSamples('Resolve', 35, 88, 96), hcfg, NOW);
  assert.equal(fs.length, 1);
  assert.equal(fs[0].headline.includes('Resolve'), true);
});

test('idle-loaded: 6 GB RSS, no front event in 12h → info with anti-placebo detail', () => {
  const procs = [{ ts: NOW - 60000, pid: 1, name: 'Adobe Premiere Pro 2026', cpu: 5, rss_mb: 6144 }];
  const fronts = [{ ts: NOW - 30 * 3600000, kind: 'front_app', key: 'Adobe Premiere Pro 2026', detail: '' }];
  const fs = idleLoaded(procs, fronts, hcfg, NOW);
  assert.equal(fs.length, 1);
  assert.equal(fs[0].severity, 'info');
  assert.ok(fs[0].headline.includes('6.0 GB of RAM'), fs[0].headline);
  assert.ok(fs[0].headline.includes("hasn't been in front since yesterday"), fs[0].headline);
  assert.ok(fs[0].why.toLowerCase().includes('pressure'), fs[0].why);
  assert.equal(fs[0].linkKind, null);
});

test('idle-loaded: recent front event → no finding', () => {
  const procs = [{ ts: NOW - 60000, pid: 1, name: 'Adobe Premiere Pro 2026', cpu: 5, rss_mb: 6144 }];
  const fronts = [{ ts: NOW - 2 * 3600000, kind: 'front_app', key: 'Adobe Premiere Pro 2026', detail: '' }];
  assert.deepEqual(idleLoaded(procs, fronts, hcfg, NOW), []);
});

test('idle-loaded: below RSS threshold → no finding', () => {
  const procs = [{ ts: NOW - 60000, pid: 1, name: 'Zen', cpu: 5, rss_mb: 500 }];
  assert.deepEqual(idleLoaded(procs, [], hcfg, NOW), []);
});

test('idle-loaded: stale samples ignored', () => {
  const procs = [{ ts: NOW - 3 * 3600000, pid: 1, name: 'Zen', cpu: 5, rss_mb: 9000 }];
  assert.deepEqual(idleLoaded(procs, [], hcfg, NOW), []);
});

test('idle-loaded: no front event ever → plain fallback copy (the live bug: "since the last 12 hours")', () => {
  const procs = [{ ts: NOW - 60000, pid: 1, name: 'Adobe Premiere Pro 2026', cpu: 5, rss_mb: 6144 }];
  const fs = idleLoaded(procs, [], hcfg, NOW);
  assert.equal(fs.length, 1);
  assert.ok(fs[0].headline.includes("hasn't been in front in the last 12 hours"), fs[0].headline);
  assert.ok(!fs[0].headline.includes('since the last'), fs[0].headline);
});

test('idle-loaded: browser helper processes are not apps → no card (plugin-container, * Helper)', () => {
  const procs = [
    { ts: NOW - 60000, pid: 1, name: 'plugin-container', cpu: 5, rss_mb: 900 },
    { ts: NOW - 60000, pid: 2, name: 'Zen Helper (Renderer)', cpu: 5, rss_mb: 1200 },
    { ts: NOW - 60000, pid: 3, name: 'Zen', cpu: 5, rss_mb: 2500 },
  ];
  const fs = idleLoaded(procs, [], hcfg, NOW);
  assert.equal(fs.length, 1, 'only the parent app may produce a card');
  assert.ok(fs[0].headline.includes('Zen'), fs[0].headline);
});

const scfg = { storage: { fitDays: 14, warnWeeksLeft: 8, redWeeksLeft: 3 } };

// daily samples over nDays; free_gb = f(dayIndex)
function diskSamples(vol, nDays, f) {
  const rows = [];
  for (let d = 0; d < nDays; d++) {
    rows.push({ ts: NOW - (nDays - 1 - d) * DAY, volume: vol, free_gb: f(d), total_gb: 1000 });
  }
  return rows;
}

test('storage: 80→62 GB over 14 days (9 GB/week) → amber, weeks-left math', () => {
  const rows = diskSamples('Macintosh HD', 15, d => 80 - d * (18 / 14));
  const fs = storageTrend(rows, scfg, NOW);
  assert.equal(fs.length, 1);
  assert.equal(fs[0].severity, 'amber');
  assert.equal(fs[0].headline, 'Macintosh HD is losing ~9 GB a week — full in about 7 weeks at this rate');
  assert.ok(fs[0].why.includes('14') && fs[0].why.includes('62'), fs[0].why);
});

test('storage: under redWeeksLeft → red', () => {
  const rows = diskSamples('Macintosh HD', 15, d => 100 - d * (60 / 14));   // ~30 GB/week
  const fs = storageTrend(rows, scfg, NOW);
  assert.equal(fs.length, 1);
  assert.equal(fs[0].severity, 'red');
});

test('storage: growing → no finding', () => {
  const rows = diskSamples('Macintosh HD', 15, d => 50 + d);
  assert.deepEqual(storageTrend(rows, scfg, NOW), []);
});

test('storage: flat → no finding', () => {
  const rows = diskSamples('Macintosh HD', 15, () => 62);
  assert.deepEqual(storageTrend(rows, scfg, NOW), []);
});

test('storage: < 4 days of history → insufficient fit, no finding', () => {
  const rows = diskSamples('Macintosh HD', 4, d => 80 - d * 3);
  assert.deepEqual(storageTrend(rows, scfg, NOW), []);
});

test('storage: slow drain under warnWeeksLeft → no finding', () => {
  const rows = diskSamples('Macintosh HD', 15, d => 500 - d * 0.1);   // ~0.05 GB/week
  assert.deepEqual(storageTrend(rows, scfg, NOW), []);
});

const dcfg2 = { drift: { paths: ['~/Downloads', '~/Desktop'], minAgeDays: 60, minMb: 100, maxItems: 8 } };

function driftEntry(folder, name, sizeMb, ageDays) {
  return { path: `${folder}/${name}`, folder, sizeMb, mtime: NOW - ageDays * DAY };
}

test('drift: 4 old big files → info card with per-item why, reveal on the folder', () => {
  const DL = '/Users/testuser/Downloads';
  const entries = [
    driftEntry(DL, 'Setup.dmg', 5325, 180),
    driftEntry(DL, 'Export_v1.mp4', 3072, 190),
    driftEntry(DL, 'Footage.mov', 2048, 200),
    driftEntry(DL, 'Installer.pkg', 1024, 150),
    driftEntry(DL, 'fresh.zip', 2048, 2),   // fresh → excluded
    driftEntry(DL, 'tiny.txt', 1, 300),     // small → excluded
  ];
  const fs = drift(entries, dcfg2, NOW);
  assert.equal(fs.length, 1);
  assert.equal(fs[0].severity, 'info');
  assert.equal(fs[0].headline, '4 old installers and exports are sitting in Downloads (11.2 GB)');
  assert.ok(fs[0].why.includes('Setup.dmg') && fs[0].why.includes('untouched 6 months'), fs[0].why);
  assert.equal(fs[0].linkKind, 'reveal');
  assert.equal(fs[0].linkTarget, DL);
});

test('drift: one card per folder; empty → none', () => {
  const DL = '/Users/testuser/Downloads';
  const DT = '/Users/testuser/Desktop';
  const entries = [driftEntry(DL, 'a.dmg', 500, 100), driftEntry(DT, 'b.zip', 600, 100)];
  assert.equal(drift(entries, dcfg2, NOW).length, 2);
  assert.deepEqual(drift([], dcfg2, NOW), []);
  assert.deepEqual(drift([driftEntry(DL, 'fresh.zip', 500, 2)], dcfg2, NOW), []);
});

test('loginItemsAudit: unmatched items and agents → info findings with honest caveat', () => {
  const fs = loginItemsAudit(['Ice', 'AltTab', 'OneDrive'], ['com.ice.menu'], ['AltTab', 'OneDrive'], {}, NOW);
  assert.equal(fs.length, 2);
  assert.equal(fs[0].severity, 'info');
  assert.ok(fs[0].headline.includes('Ice') && fs[0].headline.includes('hasn'), fs[0].headline);
  assert.ok(fs[0].detail.includes('System Settings'), fs[0].detail);
  assert.ok(fs[0].detail.includes('30-second'), fs[0].detail);
  assert.ok(fs[1].headline.includes('com.ice.menu'), fs[1].headline);
});

test('loginItemsAudit: all matched → empty', () => {
  assert.deepEqual(loginItemsAudit(['AltTab'], [], ['AltTab'], {}, NOW), []);
});

const b16cfg = {
  tier3: { battery: true, browserBloat: true },
  browser: { procs: ['Zen', 'Google Chrome', 'Brave Browser', 'Safari', 'Chromium'], rssGb: 4, minMinutes: 60 },
  tickSec: 30,
};

test('battery: gated off → []', () => {
  const rows = [{ ts: NOW, cycleCount: 78, healthPct: 96.4 }];
  assert.deepEqual(batteryTrend(rows, { tier3: { battery: false } }, NOW), []);
});

test('battery: single sample → info card with real fixture values', () => {
  const rows = [{ ts: NOW, cycleCount: 78, healthPct: 96.4 }];
  const fs = batteryTrend(rows, b16cfg, NOW);
  assert.equal(fs.length, 1);
  assert.equal(fs[0].severity, 'info');
  assert.equal(fs[0].headline, 'Battery health 96.4% after 78 cycles');
});

test('battery: 60 days apart → trend sentence; >1.5%/month decline → amber', () => {
  const slow = [
    { ts: NOW - 60 * DAY, cycleCount: 40, healthPct: 98 },
    { ts: NOW, cycleCount: 78, healthPct: 96.4 },
  ];
  const f1 = batteryTrend(slow, b16cfg, NOW)[0];
  assert.equal(f1.severity, 'info');
  assert.ok(f1.why.includes('0.8% per month'), f1.why);
  const fast = [
    { ts: NOW - 60 * DAY, cycleCount: 40, healthPct: 100 },
    { ts: NOW, cycleCount: 78, healthPct: 96 },
  ];
  assert.equal(batteryTrend(fast, b16cfg, NOW)[0].severity, 'amber');
});

test('battery: health below 85 → amber', () => {
  const rows = [{ ts: NOW, cycleCount: 200, healthPct: 80 }];
  assert.equal(batteryTrend(rows, b16cfg, NOW)[0].severity, 'amber');
});

test('browserBloat: gated off → []', () => {
  const rows = [{ ts: NOW, pid: 1, name: 'Zen', cpu: 5, rss_mb: 5000 }];
  assert.deepEqual(browserBloat(rows, { tier3: { browserBloat: false }, browser: b16cfg.browser, tickSec: 30 }, NOW), []);
});

test('browserBloat: 5.5 GB across Zen + helpers for 60 min → info, mostly-Zen', () => {
  const rows = [];
  for (let i = 0; i * 30000 <= 60 * 60000; i++) {
    const ts = NOW - 60 * 60000 + i * 30000;
    rows.push({ ts, pid: 1, name: 'Zen', cpu: 5, rss_mb: 3072 });
    rows.push({ ts, pid: 2, name: 'Google Chrome Helper (Renderer)', cpu: 5, rss_mb: 2560 });
  }
  const fs = browserBloat(rows, b16cfg, NOW);
  assert.equal(fs.length, 1);
  assert.equal(fs[0].severity, 'info');
  assert.ok(fs[0].headline.includes('5.5 GB'), fs[0].headline);
  assert.ok(fs[0].headline.includes('mostly Zen'), fs[0].headline);
  assert.equal(fs[0].linkKind, null);
  assert.ok(fs[0].detail.toLowerCase().includes('tab'), fs[0].detail);
});

test('browserBloat: under threshold or too short → []', () => {
  const small = [{ ts: NOW, pid: 1, name: 'Zen', cpu: 5, rss_mb: 2000 }];
  assert.deepEqual(browserBloat(small, b16cfg, NOW), []);
  const short = [];
  for (let i = 0; i * 30000 <= 30 * 60000; i++) {
    short.push({ ts: NOW - 30 * 60000 + i * 30000, pid: 1, name: 'Zen', cpu: 5, rss_mb: 5000 });
  }
  assert.deepEqual(browserBloat(short, b16cfg, NOW), []);
});
