// Tests for block-cross-tree-bash.js — runnable via `node --test`.
// Spawns the hook, pipes a Bash tool-call JSON to stdin, asserts on stdout.
// The hook NEVER exits non-zero (block → JSON decision:"block"; allow → empty).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';
import fs from 'node:fs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const HOOK = path.resolve(__dirname, '..', 'block-cross-tree-bash.js');

// Real on-disk dirs shaped like a lane worktree and the main tree (spawnSync
// requires cwd to exist).
const LANE_CWD = path.join(os.tmpdir(), 'regen-root.wt', 'testlane');
const MAIN_CWD = path.join(os.tmpdir(), 'regen-root');
fs.mkdirSync(LANE_CWD, { recursive: true });
fs.mkdirSync(MAIN_CWD, { recursive: true });

function runHook({ command, cwd, toolName = 'Bash' }) {
  const payload = JSON.stringify({ tool_name: toolName, tool_input: { command } });
  return spawnSync(process.execPath, [HOOK], {
    input: payload,
    cwd: cwd || process.cwd(),
    encoding: 'utf8'
  });
}

function isBlock(res) {
  assert.equal(res.status, 0, 'hook must exit 0');
  const out = (res.stdout || '').trim();
  assert.ok(out.length > 0, 'expected block output on stdout');
  const parsed = JSON.parse(out);
  assert.equal(parsed.decision, 'block');
  assert.match(parsed.reason, /CROSS-TREE SHELL BLOCKED/);
  return parsed;
}

function isAllow(res) {
  assert.equal(res.status, 0, 'hook must exit 0');
  assert.equal((res.stdout || '').trim(), '', 'expected no output on allow');
}

test('lane session `cd /c/Dev/regen-root && git commit` is blocked', () => {
  const res = runHook({
    command: 'cd /c/Dev/regen-root && git add -A && git commit -m x',
    cwd: LANE_CWD
  });
  isBlock(res);
});

test('lane session `cd C:/Dev/regen-root` (backslash-free) is blocked', () => {
  const res = runHook({ command: 'cd C:/Dev/regen-root', cwd: LANE_CWD });
  isBlock(res);
});

test('lane session `git -C C:/Dev/regen-root status` is blocked', () => {
  const res = runHook({ command: 'git -C C:/Dev/regen-root status', cwd: LANE_CWD });
  isBlock(res);
});

test('lane session cd into ANOTHER lane is blocked', () => {
  const res = runHook({
    command: 'cd /c/Dev/regen-root.wt/other-lane && git log',
    cwd: LANE_CWD
  });
  isBlock(res);
});

test('lane session with a RELATIVE cd is allowed', () => {
  const res = runHook({ command: 'cd apps/prt && ls', cwd: LANE_CWD });
  isAllow(res);
});

test('lane session cd into its OWN worktree is allowed', () => {
  const res = runHook({
    command: `cd ${LANE_CWD.replace(/\\/g, '/')}/apps && ls`,
    cwd: LANE_CWD
  });
  isAllow(res);
});

test('lane session command with no cd/git -C is allowed', () => {
  const res = runHook({ command: 'npx tsc --noEmit', cwd: LANE_CWD });
  isAllow(res);
});

test('MAIN/SV session `cd /c/Dev/regen-root` is allowed (not a lane)', () => {
  const res = runHook({ command: 'cd /c/Dev/regen-root && git status', cwd: MAIN_CWD });
  isAllow(res);
});

test('non-Bash tool is ignored (allowed)', () => {
  const res = runHook({ command: 'cd /c/Dev/regen-root', cwd: LANE_CWD, toolName: 'Read' });
  isAllow(res);
});

test('missing command is allowed (fail-open)', () => {
  const res = spawnSync(process.execPath, [HOOK], {
    input: JSON.stringify({ tool_name: 'Bash', tool_input: {} }),
    cwd: LANE_CWD,
    encoding: 'utf8'
  });
  isAllow(res);
});

test('unparseable stdin is allowed (fail-open)', () => {
  const res = spawnSync(process.execPath, [HOOK], {
    input: 'not json {',
    cwd: LANE_CWD,
    encoding: 'utf8'
  });
  isAllow(res);
});

test('hook passes node --check', () => {
  const res = spawnSync(process.execPath, ['--check', HOOK], { encoding: 'utf8' });
  assert.equal(res.status, 0, `node --check failed: ${res.stderr}`);
});
