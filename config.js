// config.js — DEFAULTS are the calibration knobs; settings-table rows override per top-level key
import { allSettings } from './db.js';

export const DEFAULTS = {
  tickSec: 30, diskTickSec: 300, cacheTickSec: 3600,
  procKeepTop: 12, procMinCpu: 3, procMinRssMb: 300,   // a proc row is stored if EITHER threshold hit
  retentionDays: { proc: 14, disk: 180, cache: 180, events: 90 },
  hog:    { cpuPct: 80, minMinutes: 30, lookbackHours: 24,
            ignore: ['kernel_task','WindowServer','launchd','mds_stores','backupd'] },
  idle:   { rssMb: 800, hours: 12 },
  exportProcs: ['Adobe Premiere Pro','Adobe Media Encoder','PProHeadless','Resolve',
                'Compressor','Blackmagic Proxy Generator'],   // prefix match on ps comm
  export: { cpuPct: 150, minMinutes: 10 },
  thermal:{ minElevatedMinutes: 10 },
  drive:  { cycles24h: 2, cycles7d: 3 },
  backup: { maxAgeDays: 7, watchPaths: [] },               // watchPaths: [{path, maxAgeDays}]
  storage:{ fitDays: 14, warnWeeksLeft: 8, redWeeksLeft: 3 },
  cacheRules: { amberGb: 5, redGb: 20, staleDays: 21 },
  drift:  { paths: ['~/Downloads','~/Desktop'], minAgeDays: 60, minMb: 100, maxItems: 8 },
  dup:    { minMb: 100 },
  notifyCooldownHours: 24, weeklyDigestNotify: true,       // Monday 09:00 local
  notifyEnabled: true,                                      // master switch (Task 15 Settings)
  dupRoots: ['~'],                                          // saved dedupe roots (Task 15 Settings)
  tier3:  { battery: false, browserBloat: false },         // OFF by default (scope doc §Tier 3)
  browser:{ procs: ['Zen','Google Chrome','Brave Browser','Safari','Chromium'], rssGb: 4, minMinutes: 60 },
};

// PUT /api/settings validation: value must match the DEFAULTS template shape
// (numbers finite + positive, nested objects may carry a subset of template keys)
export function validateSetting(value, template) {
  if (typeof template === 'number') return typeof value === 'number' && Number.isFinite(value) && value > 0;
  if (typeof template === 'boolean') return typeof value === 'boolean';
  if (typeof template === 'string') return typeof value === 'string';
  if (Array.isArray(template)) return Array.isArray(value);
  if (template && typeof template === 'object') {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
    return Object.entries(value).every(([k, v]) => k in template && validateSetting(v, template[k]));
  }
  return false;
}

export function loadConfig(db) {
  const cfg = structuredClone(DEFAULTS);
  for (const [k, v] of Object.entries(allSettings(db))) {
    const bothObjects = v !== null && typeof v === 'object' && !Array.isArray(v) &&
                        cfg[k] !== null && typeof cfg[k] === 'object' && !Array.isArray(cfg[k]);
    cfg[k] = bothObjects ? { ...cfg[k], ...v } : v;
  }
  return cfg;
}
