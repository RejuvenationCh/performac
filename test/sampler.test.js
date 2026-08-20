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

const DU_APPEAR = `***DiskAppeared ('disk4s2', DAVolumePath = 'file:///Volumes/T7/', DAVolumeKind = 'apfs', DAVolumeName = 'T7') Time=20260820-18:07:36.1551`;

// real diskutil info -plist shapes (booleans as XML tags)
const PLIST_INTERNAL = `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>Ejectable</key>
	<false/>
	<key>Internal</key>
	<true/>
	<key>VolumeName</key>
	<string>Macintosh HD</string>
</dict>
</plist>`;
const PLIST_EXTERNAL = `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>Ejectable</key>
	<true/>
	<key>Internal</key>
	<false/>
	<key>VolumeName</key>
	<string>T7</string>
</dict>
</plist>`;

const NOW = 1755000000000;

// local YYYYMMDD-HH:MM:SS stamp matching diskutil activity's Time= field
function timeStamp(ms) {
  const d = new Date(ms);
  const p = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

function makeDeps({ ps = PS, volumes = () => [], diskutilInfo = () => PLIST_EXTERNAL, now = () => NOW, power = () => null } = {}) {
  const calls = [];
  const execFile = async (bin, args) => {
    calls.push([bin, args]);
    if (bin === 'ps') return { stdout: ps };
    if (bin === 'lsappinfo') {
      if (args[0] === 'front') return { stdout: '{"LSASN"={0x0-0x17017}; }' };
      return { stdout: FRONT };
    }
    if (bin === 'pmset') {
      if (args[0] === '-g' && args[1] === 'batt') return { stdout: power() };
      return { stdout: 'Note: No CPU power status has been recorded' };
    }
    if (bin === 'diskutil' && args[0] === 'info') return { stdout: diskutilInfo(args) };
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
    now,
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
  let vols = [];   // boot state: the reconcile seeds from whatever is mounted at start
  const s = startSampler(db, { ...DEFAULTS }, makeDeps({ volumes: () => vols }));
  vols = ['T7'];   // drive plugged in after boot
  await s.tick();
  assert.equal(db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'mount'").get().n, 1);
  vols = [];
  await s.tick();
  assert.equal(db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'unmount'").get().n, 1);
  s.stop();
});

test('stream line with DAVolumeName <null> → no event row (real diskutil emits the literal <null>)', async () => {
  const db = openDb(':memory:');
  const deps = makeDeps();
  const s = startSampler(db, { ...DEFAULTS }, deps);
  const duStream = deps.spawned.find(c => c.bin === 'diskutil');
  duStream.stdout.emit('data', `***DiskAppeared ('disk0', DAVolumePath = '<null>', DAVolumeKind = '<null>', DAVolumeName = '<null>') Time=20260820-18:07:36.1554\n`);
  assert.equal(db.prepare('SELECT COUNT(*) n FROM events').get().n, 0, 'nameless disk event must never write a row');
  s.stop();
});

test('stream: internal APFS system volumes → zero events (real boot-dump noise)', async () => {
  const db = openDb(':memory:');
  const info = () => PLIST_INTERNAL;
  const deps = makeDeps({ diskutilInfo: info });
  const s = startSampler(db, { ...DEFAULTS }, deps);
  const duStream = deps.spawned.find(c => c.bin === 'diskutil');
  for (const name of ['Recovery', 'Update', 'VM', 'Preboot', 'Macintosh HD']) {
    duStream.stdout.emit('data',
      `***DiskAppeared ('x', DAVolumePath = 'file:///System/Volumes/x/', DAVolumeKind = 'apfs', DAVolumeName = '${name}') Time=20260820-18:07:36.1551\n`);
  }
  await s.tick();   // settle async verdicts
  assert.equal(db.prepare("SELECT COUNT(*) n FROM events WHERE kind IN ('mount','unmount')").get().n, 0,
    'internal volumes must never produce drive events');
  s.stop();
});

test('stream: external volume → one mount; verdict cached (no second diskutil call)', async () => {
  const db = openDb(':memory:');
  const deps = makeDeps();
  const s = startSampler(db, { ...DEFAULTS }, deps);
  const duStream = deps.spawned.find(c => c.bin === 'diskutil');
  // the initial dump can carry the same name twice (volume + its snapshot) — both must dedupe
  duStream.stdout.emit('data', DU_APPEAR + '\n');
  duStream.stdout.emit('data', DU_APPEAR + '\n');
  await s.tick();
  assert.equal(db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'mount'").get().n, 1);
  const infoCalls = deps.calls.filter(([bin, args]) => bin === 'diskutil' && args[0] === 'info');
  assert.equal(infoCalls.length, 1, 'verdict must be cached per volume name');
  s.stop();
});

test('reconcile: internal volume in set diff → no event (external still emits)', async () => {
  const db = openDb(':memory:');
  // the sampler queries the full mount path — the fake must compare paths
  const info = args => args.some(a => a.includes('Macintosh HD')) ? PLIST_INTERNAL : PLIST_EXTERNAL;
  let vols = [];
  const deps = makeDeps({ volumes: () => vols, diskutilInfo: info });
  const s = startSampler(db, { ...DEFAULTS }, deps);
  vols = ['Macintosh HD', 'T7'];
  await s.tick();
  const mounts = db.prepare("SELECT key FROM events WHERE kind = 'mount'").all().map(r => r.key);
  assert.deepEqual(mounts, ['T7'], 'only external volumes pass the reconcile');
  s.stop();
});

test('stream mount event deduped against reconcile within the dedupe window', async () => {
  const db = openDb(':memory:');
  let vols = [];
  const deps = makeDeps({ volumes: () => vols });
  const s = startSampler(db, { ...DEFAULTS }, deps);
  const duStream = deps.spawned.find(c => c.bin === 'diskutil');
  duStream.stdout.emit('data', DU_APPEAR + '\n');
  await s.tick();   // the stream insert is async (external verdict) — settle it first
  assert.equal(db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'mount'").get().n, 1);
  vols = ['T7'];
  await s.tick();   // reconcile sees T7 already reported by the stream → no duplicate
  assert.equal(db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'mount'").get().n, 1);
  s.stop();
});

test('tick records power source events only on change', async () => {
  const db = openDb(':memory:');
  let p = `Now drawing from 'AC Power'`;
  const deps = makeDeps({ power: () => p });
  const s = startSampler(db, { ...DEFAULTS }, deps);
  await s.tick();
  await s.tick();   // unchanged → still one event
  p = `Now drawing from 'Battery Power'`;
  await s.tick();
  const powers = db.prepare("SELECT key FROM events WHERE kind = 'power' ORDER BY ts").all().map(r => r.key);
  assert.deepEqual(powers, ['AC Power', 'Battery Power']);
  // regression: refreshFindings must actually run (an early TDZ bug threw before this)
  assert.ok(db.prepare('SELECT COUNT(*) n FROM findings').get().n >= 1, 'findings pipeline ran');
  s.stop();
});

test('wall-clock gap ≥ 3× tickSec between ticks → sleep_gap event (implicit sleep detection)', async () => {
  const db = openDb(':memory:');
  let t = NOW;
  const deps = makeDeps({ now: () => t });
  const s = startSampler(db, { ...DEFAULTS }, deps);
  await s.tick();
  assert.equal(db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'sleep_gap'").get().n, 0);
  t += 3 * 30000;   // 90 s at tickSec 30 — the machine slept
  await s.tick();
  const gaps = db.prepare("SELECT * FROM events WHERE kind = 'sleep_gap'").all();
  assert.equal(gaps.length, 1);
  assert.equal(gaps[0].key, 'sleep_gap');
  assert.equal(Number(gaps[0].detail), NOW, 'detail carries the pre-sleep tick time');
  assert.equal(gaps[0].ts, NOW + 90000, 'recorded at the wake tick');
  s.stop();
});

test('short tick gap (< 3× tickSec) → no sleep_gap', async () => {
  const db = openDb(':memory:');
  let t = NOW;
  const deps = makeDeps({ now: () => t });
  const s = startSampler(db, { ...DEFAULTS }, deps);
  await s.tick();
  t += 60000;   // 2 ticks — slow tick, not sleep
  await s.tick();
  assert.equal(db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'sleep_gap'").get().n, 0);
  s.stop();
});

test('dedupe mirrors real timing: stream event, reconcile 30 s later → still one row', async () => {
  const db = openDb(':memory:');
  let t = NOW;
  let vols = [];
  const deps = makeDeps({ volumes: () => vols, now: () => t });
  const s = startSampler(db, { ...DEFAULTS }, deps);
  const duStream = deps.spawned.find(c => c.bin === 'diskutil');
  // line carries its own Time= stamp ≈ now, exactly like the real stream
  const line = DU_APPEAR.replace(/Time=\d+-\d\d:\d\d:\d\d/, 'Time=' + timeStamp(t));
  duStream.stdout.emit('data', line + '\n');
  await s.tick();          // settle the stream insert
  assert.equal(db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'mount'").get().n, 1);
  t += 30000;              // real offset: stream line lands up to one tick before the reconcile
  vols = ['T7'];
  await s.tick();          // the 5 s window missed exactly this pair live
  assert.equal(db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'mount'").get().n, 1);
  s.stop();
});

// A drive with a loose connector is the most likely to be slow to enumerate — i.e. the
// exact drive this feature exists to watch is the one whose probe fails. A failed probe
// must never write the volume off permanently.
test('stream: a failed diskutil probe must not poison the verdict cache', async () => {
  const db = openDb(':memory:');
  let attempts = 0;
  const info = () => {
    attempts++;
    if (attempts === 1) throw new Error('Could not find disk: /Volumes/T7');
    return PLIST_EXTERNAL;
  };
  const deps = makeDeps({ diskutilInfo: info });
  const s = startSampler(db, { ...DEFAULTS }, deps);
  const duStream = deps.spawned.find(c => c.bin === 'diskutil');

  duStream.stdout.emit('data', DU_APPEAR + '\n');   // probe #1 fails → no event, correctly
  await s.tick();
  assert.equal(db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'mount'").get().n, 0);

  // the same drive reappears — it must be re-probed, not treated as internal forever
  duStream.stdout.emit('data', DU_APPEAR + '\n');
  await s.tick();
  assert.equal(db.prepare("SELECT COUNT(*) n FROM events WHERE kind = 'mount'").get().n, 1,
    'a transient probe failure must not make the drive permanently invisible');
  s.stop();
});
