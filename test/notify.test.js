// notify tests — cooldown logic, kind allowlist, argv (no shell), quote stripping
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { openDb } from '../db.js';
import { maybeNotify } from '../notify.js';

const cfg = { notifyCooldownHours: 24 };

function insertFinding(db, over = {}) {
  const f = {
    id: 'f1', kind: 'backup', severity: 'red', headline: 'Head "quoted"', why: 'Why "quoted"',
    detail: '', link_kind: null, link_target: null,
    ...over,
  };
  db.prepare(
    'INSERT INTO findings(id, kind, severity, headline, why, detail, link_kind, link_target, first_seen, updated, last_notified) VALUES(?,?,?,?,?,?,?,?,?,?,?)'
  ).run(f.id, f.kind, f.severity, f.headline, f.why, f.detail, f.link_kind, f.link_target, 0, 0, null);
  return f;
}

function fakeExec() {
  const calls = [];
  return { calls, exec: async (file, args) => { calls.push([file, args]); } };
}

test('red finding fires osascript once with argv array and stripped quotes', async () => {
  const db = openDb(':memory:');
  const { calls, exec } = fakeExec();
  const f = insertFinding(db);
  const fired = await maybeNotify(db, f, cfg, 1000, exec);
  assert.equal(fired, true);
  assert.equal(calls.length, 1);
  const [file, args] = calls[0];
  assert.equal(file, 'osascript');
  assert.ok(Array.isArray(args));
  assert.deepEqual(args, [
    '-e',
    'display notification "Why quoted" with title "Performac" subtitle "Head quoted"',
  ]);
});

test('cooldown 24h: second call within window skipped, fires again after', async () => {
  const db = openDb(':memory:');
  const { calls, exec } = fakeExec();
  const f = insertFinding(db);
  await maybeNotify(db, f, cfg, 1000, exec);
  assert.equal(calls.length, 1);
  await maybeNotify(db, f, cfg, 1000 + 3600000, exec);   // +1h → still cooling
  assert.equal(calls.length, 1);
  await maybeNotify(db, f, cfg, 1000 + 25 * 3600000, exec); // +25h → fires
  assert.equal(calls.length, 2);
  const row = db.prepare('SELECT last_notified FROM findings WHERE id = ?').get('f1');
  assert.equal(row.last_notified, 1000 + 25 * 3600000);
});

test('info severity never notifies', async () => {
  const db = openDb(':memory:');
  const { calls, exec } = fakeExec();
  insertFinding(db, { severity: 'info' });
  const fired = await maybeNotify(db, insertFinding(db, { id: 'f2', severity: 'info' }), cfg, 1000, exec);
  assert.equal(fired, false);
  assert.equal(calls.length, 0);
});

test('kind allowlist: drive/thermal/backup/digest notify, storage red-only, others never', async () => {
  for (const kind of ['drive', 'thermal', 'backup', 'digest']) {
    const db = openDb(':memory:');
    const { calls, exec } = fakeExec();
    const f = insertFinding(db, { id: kind, kind, severity: 'amber' });
    await maybeNotify(db, f, cfg, 1000, exec);
    assert.equal(calls.length, 1, `amber ${kind} should notify`);
  }
  {
    const db = openDb(':memory:');
    const { calls, exec } = fakeExec();
    await maybeNotify(db, insertFinding(db, { id: 's1', kind: 'storage', severity: 'amber' }), cfg, 1000, exec);
    assert.equal(calls.length, 0, 'amber storage must not notify');
    await maybeNotify(db, insertFinding(db, { id: 's2', kind: 'storage', severity: 'red' }), cfg, 1000, exec);
    assert.equal(calls.length, 1, 'red storage notifies');
  }
  {
    const db = openDb(':memory:');
    const { calls, exec } = fakeExec();
    await maybeNotify(db, insertFinding(db, { id: 'c1', kind: 'cache', severity: 'red' }), cfg, 1000, exec);
    assert.equal(calls.length, 0, 'red cache must not notify');
  }
});
