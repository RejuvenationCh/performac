// rules tests — cacheGrowth (further rules arrive per-feature)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cacheGrowth } from '../rules.js';

const DAY = 86400000;
const NOW = 1756000000000;
const cfg = { cacheRules: { amberGb: 5, redGb: 20, staleDays: 21 } };

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
