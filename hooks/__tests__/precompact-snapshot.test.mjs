/** PreCompact snapshot — render + path tests (2026-07-11). */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { renderSnapshot, snapshotPath } from '../precompact-snapshot.mjs';

test('renderSnapshot includes branch, changed files, rules', () => {
  const md = renderSnapshot({ branch: 'develop', changed: ['apps/prt/a.ts', 'x.md'], commits: ['abc feat: x'], rules: ['truth.md'], trigger: 'auto', ts: '2026-07-11T00:00:00Z' });
  assert.match(md, /Branch:\*\* develop/);
  assert.match(md, /apps\/prt\/a\.ts/);
  assert.match(md, /truth\.md/);
  assert.match(md, /abc feat: x/);
});

test('renderSnapshot handles empty state', () => {
  const md = renderSnapshot({ branch: 'develop', changed: [], commits: [], rules: [], trigger: 'manual', ts: 't' });
  assert.match(md, /\(clean tree\)/);
  assert.match(md, /\(none\)/);
});

test('snapshotPath sanitizes the session id', () => {
  assert.match(snapshotPath('C:/repo', 'a/b:c'), /a_b_c\.md$/);
  assert.match(snapshotPath('C:/repo', undefined), /unknown\.md$/);
});
