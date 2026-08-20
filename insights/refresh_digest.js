#!/usr/bin/env node
// insights/refresh_digest.js — regenerate seed/digest.json from live findings
// (Task 17 Step 2, Money Dashboard's pattern). The app itself never calls the
// network or the Claude CLI; this script runs only when the user schedules it.
// Run by hand:  node insights/refresh_digest.js
// Scheduled:    ~/Library/LaunchAgents/com.example.performac-insights.plist (opt-in, see README)
// Requires the Claude CLI to be logged in once:  claude  then  /login
import fs from 'node:fs';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileP = promisify(execFile);
const HERE = path.dirname(new URL(import.meta.url).pathname);
const APP = path.dirname(HERE);
const SEED = path.join(APP, 'seed');
const MAX_WORDS = 120;

// findings payload → plain summary lines for the prompt; digest first, live fills
// gaps, deduped by id, red before amber before info.
export function buildFindingsSummary(payload) {
  const seen = new Set();
  const rank = { red: 0, amber: 1, info: 2 };
  return [...(payload?.digest ?? []), ...(payload?.live ?? [])]
    .filter(f => f && f.id && !seen.has(f.id) && seen.add(f.id))
    .sort((a, b) => (rank[a.severity] ?? 3) - (rank[b.severity] ?? 3))
    .map(f => `[${String(f.severity).toUpperCase()}] ${f.headline} Why: ${f.why}${f.detail ? ` (${f.detail})` : ''}`);
}

// clamp to maxWords, cut at the last sentence boundary inside the limit; strip
// stray markdown fences/headings and em-dashes (the prompt forbids them, and the
// UI renders plain text).
export function clampIntro(text, maxWords = MAX_WORDS) {
  const s = String(text ?? '')
    .replace(/```[a-z]*\n?/g, '')
    .replace(/^#+\s*/gm, '')
    .replace(/—/g, '-')
    .trim();
  const words = s.split(/\s+/).filter(Boolean);
  if (words.length <= maxWords) return s;
  const cut = words.slice(0, maxWords).join(' ');
  const m = cut.match(/^(.*[.!?])\s+\S*$/);
  return (m ? m[1] : cut).trim();
}

async function main() {
  const res = await fetch('http://127.0.0.1:7420/api/findings');
  if (!res.ok) throw new Error(`/api/findings -> ${res.status}`);
  const payload = await res.json();
  const doc = fs.readFileSync(path.join(HERE, 'performac-coach.md'), 'utf8');
  const summary = buildFindingsSummary(payload);
  const prompt = `${doc}\n\n${summary.length ? summary.join('\n') : '(no findings)'}`;
  const claude = fs.existsSync('/opt/homebrew/bin/claude') ? '/opt/homebrew/bin/claude' : 'claude';
  const { stdout } = await execFileP(claude, ['-p', prompt], { timeout: 600000, maxBuffer: 1024 * 1024 });
  const text = clampIntro(stdout);
  if (!text) throw new Error('claude returned empty output');
  fs.mkdirSync(SEED, { recursive: true });
  fs.writeFileSync(path.join(SEED, 'digest.json'), JSON.stringify({ generatedAt: Date.now(), text }, null, 2));
  console.log(`OK findings=${summary.length} words=${text.split(/\s+/).filter(Boolean).length}`);
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  main().catch(err => { console.error('refresh_digest:', err.message); process.exit(1); });
}
