// sampler tests — everything through injected deps; tests never touch real binaries.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { openDb } from '../db.js';
import { DEFAULTS } from '../config.js';
import { startSampler } from '../sampler.js';

const PS = `  PID  %CPU    RSS COMM
  693  98.2  73072 RobloxPlayer
  172  47.5 171392 WindowServer
54509  28.1 615328 Claude Helper (Renderer)`;

const FRONT = `"LSDisplayName"="Zen"`;

const THERMLOG = `2026-08-20 13:11:08 +0700 Thermal Warning Level = 1`;

const DU_APPEAR = `***DiskAppeared ('disk4s2', DAVolumeKind = 'apfs', DAVolumeName = 'T7')`;

const NOW = 1755000000000;

function makeDeps({ ps = PS, volumes = () => [] } = {}) {
  const calls = [];
  const execFile = async (bin, args) => {
    calls.push([bin, args]);
    if (bin === 'ps') return { stdout: ps };
    if (bin === 'lsappinfo') {
      if (args[0] === 'front') return { stdout: '{"LSASN"={0x0-0x17017}; }' };
      return { stdout: FRONT };
    }
    if (bin === 'pmset') return { stdout: 'Note: No CPU power status has been recorded' };
    throw new Error(`unexpected execFile ${bin}`);
  };
  const spawned = [];
  const spawn = (bin, args) => {
    const child = {
      bin, args,
      stdout: new EventEmitter(),
      on(ev, cb) { this[`_${ev}`] = cb; },
      kill() {},
    };
    child.stdout.setEncoding = () => {};
    spawned.push(child);
    return child;
  };
  return {
    calls, spawned, execFile, spawn,
    statfs: async () => ({ bsize: 4096, blocks: 1000000, bavail: 500000 }),
    listVolumes: volumes,
    realpath: p => p,
    now: () => NOW,
  };
}

test('two ticks: filtered ps rows, single front_app event (unchanged), thermlog line → thermal event', async () => {
  const db = openDb(':memory:');
  const deps = makeDeps();
  const s = startSampler(db, { ...DEFAULTS }, deps);
  await s.tick();

  const procs = db.prepare('SELECT * FROM proc_samples ORDER BY cpu DESC').all();
  assert.equal(procs.length, 3);
  assert.equal(procs[0].name, 'RobloxPlayer');
  assert.equal(procs[0].ts, NOW);

  await s.tick();   // second tick: front app unchanged → still one event

  const fronts = db.prepare("SELECT * FROM events WHERE kind = 'front_app'").all();
  assert.equal(fronts.length, 1, 'second identical tick must not re-emit');
  assert.equal(fronts[0].key, 'Zen');

  const thermStream = deps.spawned.find(c => c.bin === 'pmset');
  thermStream.stdout.emit('data', THERMLOG + '\n');
  const therm = db.prepare("SELECT * FROM events WHERE kind = 'thermal'").all();
  assert.equal(therm.length, 1);
  assert.equal(therm[0].key, 'thermlog');
  assert.equal(therm[0].detail, '1');
  s.stop();
});

test('ps filter: below both thresholds dropped; low-cpu big-rss kept; top-by-cpu kept', async () => {
  const ps = `  PID  %CPU    RSS COMM
  111  0.5   1000 TinyHelper
  222  2.0 900000 Sleeper
  333  47.5 171392 WindowServer`;
  const db = openDb(':memory:');
  const s = startSampler(db, { ...DEFAULTS }, makeDeps({ ps }));
  await s.tick();
  const names = db.prepare('SELECT name FROM proc_samples ORDER BY name').all().map(r => r.name);
  assert.deepEqual(names, ['Sleeper', 'WindowServer']);
  s.stop();
});

test('diskTick writes one row per volume (root + each external)', async () => {
  const db = openDb(':memory:');
  const s = startSampler(db, { ...DEFAULTS }, makeDeps({ volumes: () => ['T7'] }));
  await s.diskTick();
  const rows = db.prepare('SELECT * FROM disk_samples ORDER BY volume').all();
  assert.equal(rows.length, 2);
  assert.deepEqual(rows.map(r => r.volume), ['Macintosh HD', 'T7']);
  const expectedGb = 500000 * 4096 / 1073741824;
  assert.ok(Math.abs(rows[0].free_gb - expectedGb) < 1e-9);
  assert.equal(rows[0].ts, NOW);
  s.stop();
});

test('volumes reconcile emits mount/unmount on set diff', async () => {
  const db = openDb(':memory:');
  let vols = ['T7'];
  const s = startSampler(db, { ...DEFAULTS }, makeDeps({ volumes: () => vols }));
  await s.tick();
  assert.equal(db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'mount'").get().n, 1);
  vols = [];
  await s.tick();
  assert.equal(db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'unmount'").get().n, 1);
  s.stop();
});

test('stream mount event deduped against reconcile within 5s', async () => {
  const db = openDb(':memory:');
  let vols = [];
  const deps = makeDeps({ volumes: () => vols });
  const s = startSampler(db, { ...DEFAULTS }, deps);
  const duStream = deps.spawned.find(c => c.bin === 'diskutil');
  duStream.stdout.emit('data', DU_APPEAR + '\n');
  assert.equal(db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'mount'").get().n, 1);
  vols = ['T7'];
  await s.tick();   // reconcile sees T7 already reported by the stream → no duplicate
  assert.equal(db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'mount'").get().n, 1);
  s.stop();
});
