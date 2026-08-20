// collectors tests — fixtures are real output captured from this machine 2026-08-20.
// Copy them verbatim; do not "clean up" or regenerate.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  parsePs, parseDf, parseFrontAppName, parseTherm, parseThermlogLine, parseBattery,
  parseTmDestinations, parseTmLatest, parseResolveConfig, parseDiskutilActivity, parseLoginItems,
  parseDiskutilInfo, parsePower,
} from '../collectors.js';

const PS = `  PID  %CPU    RSS COMM
  693  98.2  73072 RobloxPlayer
  172  47.5 171392 WindowServer
54509  28.1 615328 Claude Helper (Renderer)`;

const DF = `Filesystem     1024-blocks      Used Available Capacity iused     ifree %iused  Mounted on
/dev/disk3s1s1   971298980  15833916  64775288    20%  458734 647752880    0%   /
devfs                  199       199         0   100%     690         0  100%   /dev`;

const FRONT = `"LSDisplayName"="Zen"`;

const THERM_EMPTY = `Note: No thermal warning level has been recorded
Note: No performance warning level has been recorded
Note: No CPU power status has been recorded`;

const THERM_LIMIT = `CPU_Speed_Limit \t= 70`;

const THERMLOG = `2026-08-20 13:11:08 +0700 Thermal Warning Level = 1`;

const BATT = `      "NominalChargeCapacity" = 6024
      "DesignCapacity" = 6249
      "CycleCount" = 78`;

const TM_NONE = `tmutil: No destinations configured.`;

const TM_ONE = `====================================================
Name          : T7 Backup
Kind          : Local
Mount Point   : /Volumes/T7 Backup
ID            : 12345678-ABCD-1234-ABCD-1234567890AB`;

const RESOLVE_CFG = `Site.1.FS.1.Root = /Users/you/Movies
Site.1.FS.2.Root = /Volumes
RenderCaching.CacheDir = CacheClip`;

// real lines captured live from `diskutil activity` on this machine 2026-08-20 (no drive attached):
const DU_REAL_VM = `***DiskAppeared ('disk3s6', DAVolumePath = 'file:///System/Volumes/VM/', DAVolumeKind = 'apfs', DAVolumeName = 'VM') Time=20260820-18:07:36.1557`;
const DU_REAL_NULL = `***DiskAppeared ('disk0', DAVolumePath = '<null>', DAVolumeKind = '<null>', DAVolumeName = '<null>') Time=20260820-18:07:36.1554`;
// same format for external volumes (DAVolumeName = '<null>' is the literal string, not a JSON null):
const DU_APPEAR = `***DiskAppeared ('disk4s2', DAVolumePath = 'file:///Volumes/T7/', DAVolumeKind = 'apfs', DAVolumeName = 'T7') Time=20260820-18:07:36.1551`;
const DU_GONE   = `***DiskDisappeared ('disk4s2', DAVolumePath = 'file:///Volumes/T7/', DAVolumeKind = 'apfs', DAVolumeName = 'T7') Time=20260820-18:07:40.0001`;

// real `diskutil info -plist` shape (booleans as XML tags), captured on this machine:
const DU_INFO_INTERNAL = `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>BusProtocol</key>
	<string>Apple Fabric</string>
	<key>Ejectable</key>
	<false/>
	<key>Internal</key>
	<true/>
	<key>VolumeName</key>
	<string>Macintosh HD</string>
</dict>
</plist>`;
const DU_INFO_EXTERNAL = `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>BusProtocol</key>
	<string>Disk Image</string>
	<key>Ejectable</key>
	<true/>
	<key>Internal</key>
	<false/>
	<key>VolumeName</key>
	<string>PerformacTest</string>
</dict>
</plist>`;

const POWER_AC = `Now drawing from 'AC Power'`;
const POWER_BATT = `Now drawing from 'Battery Power'`;

test('parsePs: header skipped, numeric fields split, name = rest (spaces/parens)', () => {
  const rows = parsePs(PS);
  assert.equal(rows.length, 3);
  assert.deepEqual(rows[0], { pid: 693, cpu: 98.2, rssMb: 71, name: 'RobloxPlayer' });
  assert.deepEqual(rows[1], { pid: 172, cpu: 47.5, rssMb: 167, name: 'WindowServer' });
  assert.equal(rows[2].name, 'Claude Helper (Renderer)');
  assert.equal(rows[2].rssMb, 601);
});

test('parseDf: /dev/disk rows only; devfs dropped; mount joined tail; GB conversion', () => {
  const rows = parseDf(DF);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].mount, '/');
  assert.ok(Math.abs(rows[0].freeGb - 61.77) < 0.01, `freeGb ${rows[0].freeGb}`);
  assert.ok(Math.abs(rows[0].totalGb - 926.3) < 0.05, `totalGb ${rows[0].totalGb}`);
});

test('parseDf: mount point containing spaces is the joined tail', () => {
  const rows = parseDf(`Filesystem     1024-blocks      Used Available Capacity iused     ifree %iused  Mounted on
/dev/disk9s2     10485760   1048576   2097152    90%   1000    100000    1%   /Volumes/T7 Backup`);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].mount, '/Volumes/T7 Backup');
});

test('parseFrontAppName', () => {
  assert.equal(parseFrontAppName(FRONT), 'Zen');
  assert.equal(parseFrontAppName('not lsappinfo'), null);
});

test('parseTherm: empty → unavailable; CPU_Speed_Limit → available + value', () => {
  assert.deepEqual(parseTherm(THERM_EMPTY), { available: false, cpuSpeedLimit: null });
  assert.deepEqual(parseTherm(THERM_LIMIT), { available: true, cpuSpeedLimit: 70 });
});

test('parseThermlogLine: warning level parsed; non-matching → null; level 0 counts', () => {
  assert.deepEqual(parseThermlogLine(THERMLOG), { level: 1 });
  assert.deepEqual(parseThermlogLine('2026-08-20 13:11:08 +0700 Thermal Warning Level = 0'), { level: 0 });
  assert.equal(parseThermlogLine('some unrelated line'), null);
});

test('parseBattery: real ioreg fixture → cycleCount/designCap/nominalCap/healthPct', () => {
  assert.deepEqual(parseBattery(BATT), { cycleCount: 78, designCap: 6249, nominalCap: 6024, healthPct: 96.4 });
  assert.equal(parseBattery('garbage'), null);
});

test('parseTmDestinations: none configured → {configured:false, names:[]}', () => {
  assert.deepEqual(parseTmDestinations(TM_NONE), { configured: false, names: [] });
  assert.deepEqual(parseTmDestinations(TM_ONE), { configured: true, names: ['T7 Backup'] });
});

test('parseTmLatest: backup path → ISO from trailing timestamp; error text → null', () => {
  assert.deepEqual(parseTmLatest('/Volumes/T7 Backup/2026-08-19-221408.backup'),
    { backupISO: '2026-08-19T22:14:08' });
  assert.equal(parseTmLatest('Failed to mount backup destination: No such file or directory'), null);
});

test('parseResolveConfig: FS.1.Root + CacheDir', () => {
  assert.deepEqual(parseResolveConfig(RESOLVE_CFG),
    { fsRoot: '/Users/you/Movies', cacheDir: 'CacheClip' });
});

test('parseDiskutilActivity: real lines — kind/volume/ts; <null> and nameless → null', () => {
  const local = (...a) => new Date(...a).getTime();
  assert.deepEqual(parseDiskutilActivity(DU_APPEAR),
    { kind: 'appeared', volume: 'T7', ts: local(2026, 7, 20, 18, 7, 36) });
  assert.deepEqual(parseDiskutilActivity(DU_GONE),
    { kind: 'disappeared', volume: 'T7', ts: local(2026, 7, 20, 18, 7, 40) });
  assert.deepEqual(parseDiskutilActivity(DU_REAL_VM),
    { kind: 'appeared', volume: 'VM', ts: local(2026, 7, 20, 18, 7, 36) });
  // DAVolumeName = '<null>' is what real diskutil prints for unnamed disks — must not become a key
  assert.equal(parseDiskutilActivity(DU_REAL_NULL), null);
  assert.equal(parseDiskutilActivity(`***DiskAppeared ('disk4s2', DAVolumeKind = 'apfs', DAVolumeName = '')`), null);
  assert.equal(parseDiskutilActivity('***StorageAttached (...)'), null);
});

test('parseDiskutilInfo: real plist — Internal/Ejectable booleans', () => {
  assert.deepEqual(parseDiskutilInfo(DU_INFO_INTERNAL), { internal: true, ejectable: false });
  assert.deepEqual(parseDiskutilInfo(DU_INFO_EXTERNAL), { internal: false, ejectable: true });
  assert.equal(parseDiskutilInfo('garbage'), null);
});

test('parsePower: AC / battery / garbage', () => {
  assert.equal(parsePower(POWER_AC), 'AC Power');
  assert.equal(parsePower(POWER_BATT), 'Battery Power');
  assert.equal(parsePower('nonsense'), null);
});

test('parseLoginItems: comma list → names', () => {
  assert.deepEqual(parseLoginItems('Ice, AltTab, OneDrive'), ['Ice', 'AltTab', 'OneDrive']);
  assert.deepEqual(parseLoginItems(''), []);
});

test('parsers never throw on garbage', () => {
  assert.deepEqual(parsePs(undefined), []);
  assert.deepEqual(parseDf(null), []);
  assert.equal(parseFrontAppName(undefined), null);
  assert.deepEqual(parseTherm(undefined), { available: false, cpuSpeedLimit: null });
  assert.equal(parseThermlogLine(undefined), null);
  assert.equal(parseBattery(undefined), null);
  assert.deepEqual(parseTmDestinations(undefined), { configured: false, names: [] });
  assert.equal(parseTmLatest(undefined), null);
  assert.deepEqual(parseResolveConfig(undefined), { fsRoot: null, cacheDir: null });
  assert.equal(parseDiskutilActivity(undefined), null);
  assert.deepEqual(parseLoginItems(undefined), []);
});
