// paths tests — D2 cache registry (detected targets) + measure() walker
import { test } from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';
import { mkdtemp, rm, writeFile, mkdir, symlink, utimes, chmod } from 'node:fs/promises';
import { cacheTargets, measure } from '../paths.js';

const HOME = '/Users/testuser';
const DAY = 86400000;

test('resolve targets: config wiring → cache, gallery, proxy (optional)', () => {
  const cfg = `Site.1.FS.1.Root = ${HOME}/Movies
RenderCaching.CacheDir = CacheClip`;
  const byId = Object.fromEntries(cacheTargets({}, { home: HOME, resolveCfg: cfg }).map(t => [t.id, t]));
  assert.equal(byId['resolve-cache'].path, `${HOME}/Movies/CacheClip`);
  assert.equal(byId['resolve-gallery'].path, `${HOME}/Movies/.gallery`);
  assert.equal(byId['resolve-proxy'].path, `${HOME}/Movies/ProxyMedia`);
  assert.equal(byId['resolve-proxy'].optional, true);
});

test('resolve fallback when config unparsable → ~/Movies/CacheClip', () => {
  const targets = cacheTargets({}, { home: HOME, resolveCfg: 'garbage' });
  assert.equal(targets.find(t => t.id === 'resolve-cache').path, `${HOME}/Movies/CacheClip`);
});

test('premiere: the four Adobe/Common subdirs; side-by-side prefs → note on media target', () => {
  const targets = cacheTargets({}, { home: HOME, prefs: '' });
  const ids = targets.filter(t => t.id.startsWith('premiere-')).map(t => t.id).sort();
  assert.deepEqual(ids, ['premiere-analyzer', 'premiere-db', 'premiere-media', 'premiere-peaks']);
  const media = targets.find(t => t.id === 'premiere-media');
  assert.equal(media.path, `${HOME}/Library/Application Support/Adobe/Common/Media Cache Files`);
  assert.equal(media.note, undefined);
  const sb = cacheTargets({}, {
    home: HOME,
    prefs: '<BE.Prefs.MediaCache.FilesSideBySide>true</BE.Prefs.MediaCache.FilesSideBySide>',
  });
  assert.equal(sb.find(t => t.id === 'premiere-media').note, 'side-by-side');
});

test('lightroom: sibling lrdata targets per catalog, deduped, default always included', () => {
  const lrcats = ['/Volumes/Photo/Catalog.lrcat', `${HOME}/Documents/Old Catalog.lrcat`, '/Volumes/Photo/Catalog.lrcat'];
  const targets = cacheTargets({}, { home: HOME, lrcatPaths: lrcats });
  const lr = targets.filter(t => t.id.startsWith('lr-'));
  const lrPaths = lr.map(t => t.path);
  assert.equal(new Set(lrPaths).size, lrPaths.length, 'deduped');
  assert.ok(lrPaths.includes('/Volumes/Photo/Catalog Previews.lrdata'));
  assert.ok(lrPaths.includes('/Volumes/Photo/Catalog Smart Previews.lrdata'));
  assert.ok(lrPaths.includes(`${HOME}/Documents/Old Catalog Previews.lrdata`));
  const def = lr.find(t => t.id === 'lr-default');
  assert.ok(def, 'default always included even when mdfind missed it');
  assert.equal(def.path, `${HOME}/Pictures/Lightroom`);
});

test('default lightroom target skipped when a catalog lives there (covered by siblings)', () => {
  const targets = cacheTargets({}, {
    home: HOME,
    lrcatPaths: [`${HOME}/Pictures/Lightroom/Lightroom Catalog.lrcat`],
  });
  assert.ok(!targets.some(t => t.id === 'lr-default'));
});

test('measure: size/newest mtime/count; symlinks skipped; EACCES dirs count 0', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'performac-paths-'));
  try {
    await writeFile(path.join(dir, 'a.bin'), Buffer.alloc(1024));
    await mkdir(path.join(dir, 'sub'));
    await writeFile(path.join(dir, 'sub', 'b.bin'), Buffer.alloc(2048));
    await symlink(path.join(dir, 'a.bin'), path.join(dir, 'link.bin'));
    const old = Date.now() - 10 * DAY;
    await utimes(path.join(dir, 'a.bin'), old / 1000, old / 1000);
    const locked = path.join(dir, 'locked');
    await mkdir(locked);
    await writeFile(path.join(locked, 'secret.bin'), Buffer.alloc(4096));
    await chmod(locked, 0o000);
    try {
      const m = await measure(dir);
      assert.equal(m.fileCount, 2);
      assert.equal(m.sizeMb, 3072 / 1048576);
      assert.ok(m.newestMtime > old + 8 * DAY, 'newest is b.bin, not a.bin');
    } finally {
      await chmod(locked, 0o755);
    }
    const missing = await measure(path.join(dir, 'nope'));
    assert.deepEqual(missing, { sizeMb: 0, newestMtime: null, fileCount: 0 });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('generic registry: fixed entries + discovered per-bundle dirs, Purge safety labels', () => {
  const targets = cacheTargets({}, {
    home: HOME,
    cacheDirs: [{ name: 'BigBundle', sizeMb: 600, newestMtime: 1, fileCount: 2 }],
  });
  const fixed = ['gen-xcode', 'gen-deriveddata', 'gen-npm', 'gen-google', 'gen-brave', 'gen-zen'];
  for (const id of fixed) {
    const t = targets.find(x => x.id === id);
    assert.ok(t, `missing ${id}`);
    assert.ok(t.path.startsWith(`${HOME}/Library`) || t.path.startsWith(`${HOME}/.npm`), t.path);
  }
  const byId = Object.fromEntries(targets.map(t => [t.id, t]));
  assert.equal(byId['gen-xcode'].safety, 'safe');
  assert.equal(byId['gen-google'].safety, 'check-first');
  assert.equal(byId['gen-brave'].safety, 'check-first');
  assert.equal(byId['gen-zen'].safety, 'check-first');
  const big = byId['gen-bigbundle'];
  assert.ok(big, 'discovered per-bundle dir becomes a target');
  assert.equal(big.safety, 'safe');
  assert.equal(big.path, `${HOME}/Library/Caches/BigBundle`);
  assert.deepEqual(big.measurement, { sizeMb: 600, newestMtime: 1, fileCount: 2 });
});
