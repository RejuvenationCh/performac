// paths.js — D2 cache registry (runtime-detected) + the directory walker.
// cacheTargets is pure: real config/prefs text and mdfind results arrive via `inputs`.
import os from 'node:os';
import path from 'node:path';
import { opendir, stat } from 'node:fs/promises';
import { parseResolveConfig } from './collectors.js';

// per-id metadata used by rules.js for card copy and link-outs
export const CACHE_META = {
  'premiere-media':    { app: 'Premiere', media: true, clearing: 'Premiere: Settings → Media Cache → Delete.' },
  'premiere-db':       { app: 'Premiere', media: true, clearing: 'Premiere: Settings → Media Cache → Delete.' },
  'premiere-peaks':    { app: 'Premiere', media: true, clearing: 'Premiere: Settings → Media Cache → Delete.' },
  'premiere-analyzer': { app: 'Premiere', media: true, clearing: 'Premiere: Settings → Media Cache → Delete.' },
  'resolve-cache':     { app: 'Resolve', media: true, clearing: 'Resolve: Playback → Delete Render Cache, and Media Storage cleanup.' },
  'resolve-gallery':   { app: 'Resolve', media: true, clearing: 'Resolve: Media Storage cleanup.' },
  'resolve-proxy':     { app: 'Resolve', media: true, clearing: 'Resolve: delete proxies from the Media page.' },
};

export function cacheTargets(cfg, inputs = {}) {
  const home = inputs.home ?? os.homedir();
  const targets = [];

  // Resolve — config.dat is plain key = value text
  const rc = parseResolveConfig(inputs.resolveCfg ?? '');
  const fsRoot = rc.fsRoot ?? path.join(home, 'Movies');
  const cacheDir = rc.cacheDir ?? 'CacheClip';
  targets.push({ id: 'resolve-cache', label: 'Resolve render cache', path: path.join(fsRoot, cacheDir) });
  targets.push({ id: 'resolve-gallery', label: 'Resolve gallery stills', path: path.join(fsRoot, '.gallery') });
  targets.push({ id: 'resolve-proxy', label: 'Resolve proxies', path: path.join(fsRoot, 'ProxyMedia'), optional: true });

  // Premiere — fixed Adobe/Common subdirs; prefs may override
  const prefs = inputs.prefs ?? '';
  const sideBySide = /<BE\.Prefs\.MediaCache\.FilesSideBySide>\s*(true|false)/.exec(prefs)?.[1] === 'true';
  const override = prefs.match(/<BE\.Prefs\.MediaCache[^>]*>\s*(\/[^<\s]*)/)?.[1];
  const adobe = path.join(home, 'Library/Application Support/Adobe/Common');
  targets.push({
    id: 'premiere-media',
    label: 'Premiere media cache',
    path: override ?? path.join(adobe, 'Media Cache Files'),
    note: sideBySide ? 'side-by-side' : undefined,
  });
  targets.push({ id: 'premiere-db', label: 'Premiere cache database', path: path.join(adobe, 'Media Cache') });
  targets.push({ id: 'premiere-peaks', label: 'Premiere peak files', path: path.join(adobe, 'Peak Files') });
  targets.push({ id: 'premiere-analyzer', label: 'Premiere analyzer cache', path: path.join(adobe, 'Analyzer Cache Files') });

  // Lightroom — previews sit beside each catalog; mdfind discovers the catalogs
  const seen = new Set();
  let defaultCovered = false;
  const lrHome = path.join(home, 'Pictures/Lightroom');
  for (const lrcat of inputs.lrcatPaths ?? []) {
    if (lrcat.startsWith(lrHome)) defaultCovered = true;
    const dir = path.dirname(lrcat);
    const base = path.basename(lrcat).replace(/\.lrcat$/, '');
    for (const [suffix, idSuffix] of [[' Previews.lrdata', 'previews'], [' Smart Previews.lrdata', 'smart'], [' Helper.lrdata', 'helper']]) {
      const p = path.join(dir, base + suffix);
      if (seen.has(p)) continue;
      seen.add(p);
      targets.push({ id: `lr-${idSuffix}-${slug(`${dir}/${base}`)}`, label: `Lightroom ${base}`, path: p });
    }
  }
  if (!defaultCovered) targets.push({ id: 'lr-default', label: 'Lightroom Classic (default catalog)', path: lrHome });

  // generic caches (Task 11) — safety labels mirror Purge's Safe to Clean / Check First
  const GENERIC = [
    { id: 'gen-xcode', label: 'Xcode cache', path: path.join(home, 'Library/Caches/com.apple.dt.Xcode'), safety: 'safe' },
    { id: 'gen-deriveddata', label: 'Xcode DerivedData', path: path.join(home, 'Library/Developer/Xcode/DerivedData'), safety: 'safe' },
    { id: 'gen-npm', label: 'npm cache', path: path.join(home, '.npm/_cacache'), safety: 'safe' },
    { id: 'gen-google', label: 'Google Chrome cache', path: path.join(home, 'Library/Caches/Google'), safety: 'check-first' },
    { id: 'gen-brave', label: 'Brave cache', path: path.join(home, 'Library/Caches/BraveSoftware'), safety: 'check-first' },
    { id: 'gen-zen', label: 'Zen cache', path: path.join(home, 'Library/Caches/zen'), safety: 'check-first' },
  ];
  for (const g of GENERIC) targets.push({ id: g.id, label: g.label, path: g.path, safety: g.safety });
  for (const d of inputs.cacheDirs ?? []) {
    targets.push({
      id: `gen-${slug(d.name)}`,
      label: `${d.name} cache`,
      path: path.join(home, 'Library/Caches', d.name),
      safety: 'safe',
      measurement: { sizeMb: d.sizeMb, newestMtime: d.newestMtime, fileCount: d.fileCount },   // premeasured — no double walk
    });
  }

  return targets;
}

function slug(s) {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
}

// walk a directory: sum sizes, newest mtime, file count.
// No symlink following; unreadable dirs count as 0/skip; missing dir → zeros.
export async function measure(dir) {
  let size = 0;
  let newest = null;
  let count = 0;
  const dirs = [dir];
  while (dirs.length) {
    const d = dirs.pop();
    let entries;
    try {
      entries = await opendir(d);
    } catch {
      continue;
    }
    try {
      for await (const e of entries) {
        if (e.isSymbolicLink()) continue;
        if (e.isDirectory()) { dirs.push(path.join(d, e.name)); continue; }
        if (!e.isFile()) continue;
        try {
          const st = await stat(path.join(d, e.name));
          size += st.size;
          count += 1;
          if (newest === null || st.mtimeMs > newest) newest = st.mtimeMs;
        } catch {
          // raced: file vanished mid-walk
        }
      }
    } catch {
      // permission error mid-walk → skip this dir
    }
  }
  return { sizeMb: size / 1048576, newestMtime: newest === null ? null : Math.round(newest), fileCount: count };
}
