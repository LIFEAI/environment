/** P3: MessageDisplay redaction + PermissionRequest backstop — integration-ish tests (2026-07-11). */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'child_process';
import path from 'path';
import { fileURLToPath } from 'url';

const dir = path.dirname(fileURLToPath(import.meta.url));
const hook = (name) => path.join(dir, '..', name);
const run = (name, input) => {
  try {
    return execFileSync('node', [hook(name)], { input: JSON.stringify(input), encoding: 'utf8' });
  } catch (e) { return String(e.stdout || ''); }
};

test('messagedisplay-redact scrubs a secret from on-screen text', () => {
  const out = run('messagedisplay-redact.mjs', { message: 'here is the key ghp_' + 'a'.repeat(36) + ' ok' });
  const j = JSON.parse(out);
  assert.match(j.hookSpecificOutput.displayContent, /«REDACTED:gh-token»/);
});
test('messagedisplay-redact stays silent on clean text', () => {
  assert.equal(run('messagedisplay-redact.mjs', { message: 'nothing secret here' }).trim(), '');
});

test('permission-backstop denies a catastrophic command', () => {
  const out = run('permission-backstop.mjs', { tool_name: 'shell', tool_input: { command: 'rm -rf /' }, cwd: process.cwd() });
  const j = JSON.parse(out);
  assert.equal(j.hookSpecificOutput.decision.behavior, 'deny');
});
test('permission-backstop stays silent (defers) on a safe command', () => {
  assert.equal(run('permission-backstop.mjs', { tool_name: 'shell', tool_input: { command: 'ls -la' }, cwd: process.cwd() }).trim(), '');
});
