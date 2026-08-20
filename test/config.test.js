// config tests — PUT validation against DEFAULTS shape + loadConfig merge roundtrip
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { openDb, setSetting } from '../db.js';
import { DEFAULTS, loadConfig, validateSetting } from '../config.js';

test('validateSetting: types against DEFAULTS shape', () => {
  assert.equal(validateSetting(95, 30), true);
  assert.equal(validateSetting('95', 30), false);
  assert.equal(validateSetting(-5, 30), false);
  assert.equal(validateSetting(NaN, 30), false);
  assert.equal(validateSetting(true, false), true);
  assert.equal(validateSetting(1, true), false);
  assert.equal(validateSetting({ cpuPct: 95 }, DEFAULTS.hog), true);
  assert.equal(validateSetting({ cpuPct: 95, bogus: 1 }, DEFAULTS.hog), false, 'unknown nested key rejected');
  assert.equal(validateSetting({ cpuPct: '95' }, DEFAULTS.hog), false);
  assert.equal(validateSetting({ battery: true }, DEFAULTS.tier3), true);
  assert.equal(validateSetting(['~/Desktop'], DEFAULTS.drift.paths), true);
  assert.equal(validateSetting('x', DEFAULTS.drift.paths), false);
});

test('loadConfig: PUT a threshold → merged config reflects it (persists via settings rows)', () => {
  const db = openDb(':memory:');
  setSetting(db, 'hog', { cpuPct: 95 });
  setSetting(db, 'tier3', { battery: true });
  setSetting(db, 'tickSec', 60);
  const cfg = loadConfig(db);
  assert.equal(cfg.hog.cpuPct, 95);
  assert.equal(cfg.hog.minMinutes, 30, 'unset nested keys keep DEFAULTS');
  assert.equal(cfg.tier3.battery, true);
  assert.equal(cfg.tier3.browserBloat, false, 'tier-3 stays off unless enabled');
  assert.equal(cfg.tickSec, 60);
  // "after restart": a fresh loadConfig from the same rows sees the same values
  assert.equal(loadConfig(db).hog.cpuPct, 95);
});
