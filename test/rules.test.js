// rules tests — cacheGrowth, thermalDuringExport (further rules arrive per-feature)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cacheGrowth, thermalDuringExport } from '../rules.js';

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
