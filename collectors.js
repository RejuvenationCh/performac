// collectors.js — pure string→object parsers for every CLI output.
// No child_process in this file. Bad input → null/[]/empty state; never throws.
export function parsePs(text) {
  const rows = [];
  for (const line of String(text ?? '').split('\n')) {
    const m = line.match(/^\s*(\d+)\s+([\d.]+)\s+(\d+)\s+(.+?)\s*$/);
    if (!m) continue;
    rows.push({ pid: Number(m[1]), cpu: Number(m[2]), rssMb: Math.round(Number(m[3]) / 1024), name: m[4].trim() });
  }
  return rows;
}

export function parseDf(text) {
  const rows = [];
  for (const line of String(text ?? '').split('\n')) {
    const f = line.trim().split(/\s+/);
    if (f.length < 9 || !f[0].startsWith('/dev/disk')) continue;
    rows.push({ mount: f.slice(8).join(' '), freeGb: Number(f[3]) / 1048576, totalGb: Number(f[1]) / 1048576 });
  }
  return rows;
}

export function parseFrontAppName(text) {
  const m = String(text ?? '').match(/"LSDisplayName"\s*=\s*"([^"]*)"/);
  return m ? m[1] : null;
}

export function parseTherm(text) {
  const m = String(text ?? '').match(/CPU_Speed_Limit\s*=\s*(\d+)/);
  return m ? { available: true, cpuSpeedLimit: Number(m[1]) } : { available: false, cpuSpeedLimit: null };
}

export function parseThermlogLine(line) {
  const m = String(line ?? '').match(/Thermal Warning Level\s*=\s*(\d+)/);
  return m ? { level: Number(m[1]) } : null;
}

export function parseBattery(text) {
  const g = k => {
    const m = String(text ?? '').match(new RegExp('"' + k + '"\\s*=\\s*(\\d+)'));
    return m ? Number(m[1]) : null;
  };
  const nominal = g('NominalChargeCapacity');
  const design = g('DesignCapacity');
  const cycles = g('CycleCount');
  if (nominal == null || design == null || cycles == null) return null;
  return { cycleCount: cycles, designCap: design, nominalCap: nominal, healthPct: Math.round((nominal / design) * 1000) / 10 };
}

export function parseTmDestinations(text) {
  const names = [...String(text ?? '').matchAll(/^Name\s*:\s*(.+)$/gm)].map(m => m[1].trim());
  return { configured: names.length > 0, names };
}

export function parseTmLatest(text) {
  const m = String(text ?? '').match(/(\d{4})-(\d{2})-(\d{2})-(\d{6})\.backup/);
  if (!m) return null;
  const t = m[4];
  return { backupISO: `${m[1]}-${m[2]}-${m[3]}T${t.slice(0, 2)}:${t.slice(2, 4)}:${t.slice(4, 6)}` };
}

export function parseResolveConfig(text) {
  const s = String(text ?? '');
  const root = s.match(/^Site\.\d+\.FS\.1\.Root\s*=\s*(.+)$/m);
  const dir = s.match(/^RenderCaching\.CacheDir\s*=\s*(.+)$/m);
  return { fsRoot: root ? root[1].trim() : null, cacheDir: dir ? dir[1].trim() : null };
}

// real `diskutil activity` lines carry the literal string DAVolumeName = '<null>' for unnamed
// disks (disk/container/scheme events) — that is NOT a name, return null so no event is written.
// ts comes from the line's own Time=YYYYMMDD-HH:MM:SS (local), null when absent.
export function parseDiskutilActivity(line) {
  const m = String(line ?? '').match(/\*\*\*Disk(Appeared|Disappeared).*DAVolumeName = '([^']*)'/);
  if (!m || !m[2] || m[2] === '<null>') return null;
  const t = String(line).match(/Time=(\d{4})(\d{2})(\d{2})-(\d{2}):(\d{2}):(\d{2})/);
  const ts = t ? new Date(Number(t[1]), Number(t[2]) - 1, Number(t[3]), Number(t[4]), Number(t[5]), Number(t[6])).getTime() : null;
  return { kind: m[1].toLowerCase(), volume: m[2], ts };
}

// `diskutil info -plist <vol>` — booleans render as <true/>/<false/> tags
export function parseDiskutilInfo(text) {
  const s = String(text ?? '');
  const val = k => {
    const m = s.match(new RegExp('<key>' + k + '</key>\\s*<(true|false)/>'));
    return m ? m[1] === 'true' : null;
  };
  const internal = val('Internal');
  const ejectable = val('Ejectable');
  if (internal == null && ejectable == null) return null;
  return { internal: internal ?? false, ejectable: ejectable ?? false };
}

// `pmset -g batt -o` → "Now drawing from 'AC Power'" / "'Battery Power'"
export function parsePower(text) {
  const m = String(text ?? '').match(/Now drawing from '([^']+)'/);
  return m ? m[1] : null;
}

export function parseLoginItems(text) {
  return String(text ?? '').split(',').map(s => s.trim()).filter(Boolean);
}
