// insights tests — pure helpers of refresh_digest.js (no network, no claude CLI here)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildFindingsSummary, clampIntro } from '../insights/refresh_digest.js';

test('buildFindingsSummary: digest + live deduped by id, red before amber before info', () => {
  const payload = {
    digest: [
      { id: 'a', severity: 'amber', headline: 'A', why: 'wA', detail: '' },
      { id: 'b', severity: 'red', headline: 'B', why: 'wB', detail: '' },
    ],
    live: [
      { id: 'b', severity: 'red', headline: 'B', why: 'wB', detail: '' },   // dup of digest
      { id: 'c', severity: 'info', headline: 'C', why: 'wC', detail: 'dC' },
    ],
  };
  const s = buildFindingsSummary(payload);
  assert.equal(s.length, 3);
  assert.ok(s[0].startsWith('[RED] B Why: wB'), s[0]);
  assert.ok(s[2].startsWith('[INFO] C') && s[2].endsWith('(dC)'), s[2]);
});

test('buildFindingsSummary: empty or missing payload → empty summary', () => {
  assert.deepEqual(buildFindingsSummary({ digest: [], live: [] }), []);
  assert.deepEqual(buildFindingsSummary(null), []);
});

test('clampIntro: over-limit text cut at the last sentence boundary ≤ 120 words', () => {
  const long = Array(40).fill('This sentence is exactly five words long.').join(' ');   // 200 words
  const out = clampIntro(long);
  const n = out.split(/\s+/).filter(Boolean).length;
  assert.ok(n <= 120, `got ${n} words`);
  assert.ok(out.endsWith('.'), 'ends on a sentence boundary, not mid-word');
});

test('clampIntro: short text passes through; fences and em-dashes stripped', () => {
  assert.equal(clampIntro('All good here.'), 'All good here.');
  assert.equal(clampIntro('```\nHello — world\n```'), 'Hello - world');
});
