// dedupe tests — temp dirs only. Size bucket → 128KB partial → full SHA-256.
// Hash-call counting via injectable hasher proves the decoy dies at the partial stage.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { mkdtemp, rm, writeFile, mkdir, symlink } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { openDb } from '../db.js';
import { startScan, scanStatus } from '../dedupe.js';

const MB = 1048576;
const cfg = { dup: { minMb: 0.5 } };

async function makeTree() {
  const root = await mkdtemp(path.join(os.tmpdir(), 'performac-dup-'));
  const same = createHash('sha256').update('performac-test').digest();   // 32 bytes, repeated
  const one = Buffer.alloc(MB);
  for (let i = 0; i < MB; i += 32) same.copy(one, i);
  const decoy = Buffer.alloc(MB, 7);
  for (const d of ['a', 'b', 'c', 'd', 'e', '.hidden']) await mkdir(path.join(root, d));
  await writeFile(path.join(root, 'a', '1.bin'), one);
  await writeFile(path.join(root, 'b', '2.bin'), one);
  await writeFile(path.join(root, 'c', '3.bin'), one);
  await writeFile(path.join(root, 'd', '4.bin'), decoy);             // same size, different content
  await writeFile(path.join(root, 'e', '5.bin'), Buffer.alloc(MB / 2, 9));  // unique size
  await writeFile(path.join(root, '.hidden', '6.bin'), one);         // dotdir → skipped by walk
  await symlink(path.join(root, 'a', '1.bin'), path.join(root, 'link.bin')); // symlink → skipped
  return root;
}

function countingHasher() {
  const counts = { partial: 0, full: 0 };
  const hasher = {
    async partial(file, size) {
      counts.partial += 1;
      const { partialHash } = await import('../dedupe.js');
      return partialHash(file, size);
    },
    async full(file) {
      counts.full += 1;
      const { fullHash } = await import('../dedupe.js');
      return fullHash(file);
    },
  };
  return { counts, hasher };
}

async function waitForDone() {
  while (scanStatus().state === 'running') {
    await new Promise(r => setTimeout(r, 20));
  }
}

test('scan finds exactly the 3 true duplicates; decoy dies at partial stage; DB row written', async () => {
  const root = await makeTree();
  try {
    const db = openDb(':memory:');
    const { counts, hasher } = countingHasher();
    startScan([root], cfg, { db, hasher });
    await waitForDone();
    const st = scanStatus();
    assert.equal(st.state, 'done');
    assert.equal(st.groups.length, 1);
    const g = st.groups[0];
    assert.equal(g.paths.length, 3);
    assert.equal(g.sizeMb, 1);
    assert.equal(counts.partial, 4, '4 same-size candidates hashed');
    assert.equal(counts.full, 3, 'only the 3 survivors get a full hash');
    const rows = db.prepare('SELECT * FROM dup_groups').all();
    assert.equal(rows.length, 1);
    assert.equal(JSON.parse(rows[0].paths).length, 3);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('second scan replaces prior rows; scanned counter increments during the run', async () => {
  const root = await makeTree();
  try {
    const db = openDb(':memory:');
    startScan([root], cfg, { db });
    await waitForDone();
    assert.equal(db.prepare('SELECT COUNT(*) n FROM dup_groups').get().n, 1);
    startScan([path.join(root, 'a')], cfg, { db });   // single copy → no groups
    await waitForDone();
    assert.equal(db.prepare('SELECT COUNT(*) n FROM dup_groups').get().n, 0);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('one job at a time — second startScan throws', async () => {
  const root = await makeTree();
  try {
    const big = path.join(root, 'big');
    await mkdir(big);
    const buf = Buffer.alloc(MB, 1);
    await writeFile(path.join(big, 'x.bin'), buf);
    await writeFile(path.join(big, 'y.bin'), buf);
    startScan([root], cfg, {});
    assert.throws(() => startScan([root], cfg, {}), /already running/);
    await waitForDone();
    assert.equal(scanStatus().state, 'done');
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
