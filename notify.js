// notify.js — osascript notification, cooldown-gated. Cooldown persists in
// findings.last_notified so it survives restarts (never a module-level variable).
const NOTIFY_KINDS = new Set(['drive', 'thermal', 'backup', 'storage', 'digest']);

export async function maybeNotify(db, finding, cfg, now, exec) {
  if (cfg.notifyEnabled === false) return false;   // master switch (Settings)
  if (finding.severity === 'info') return false;
  if (!NOTIFY_KINDS.has(finding.kind)) return false;
  if (finding.kind === 'storage' && finding.severity !== 'red') return false;
  const row = db.prepare('SELECT last_notified FROM findings WHERE id = ?').get(finding.id);
  const cooldown = cfg.notifyCooldownHours * 3600000;
  if (row && row.last_notified && now - row.last_notified < cooldown) return false;
  const clean = s => String(s).replace(/"/g, '');
  const script = `display notification "${clean(finding.why)}" with title "Performac" subtitle "${clean(finding.headline)}"`;
  try {
    await exec('osascript', ['-e', script]);   // argv array, never a shell string
  } catch {
    return false;   // don't burn the cooldown on a failed fire
  }
  db.prepare('UPDATE findings SET last_notified = ? WHERE id = ?').run(now, finding.id);
  return true;
}
