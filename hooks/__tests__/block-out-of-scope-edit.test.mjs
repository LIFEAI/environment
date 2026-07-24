// Tests for block-out-of-scope-edit.js — runnable via `node --test`.
// Spawns the hook as a child process, pipes a tool-call JSON to stdin, and
// asserts on stdout. The hook NEVER exits non-zero, so we assert behavior via
// stdout content (block → JSON with decision:"block"; allow → empty stdout).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';
import fs from 'node:fs';

// A real on-disk dir shaped like a lane worktree, used as the hook's cwd to
// exercise tree-boundary enforcement (spawnSync requires the cwd to exist).
const LANE_CWD = path.join(os.tmpdir(), 'regen-root.wt', 'testlane');
const MAIN_CWD = path.join(os.tmpdir(), 'regen-root');
fs.mkdirSync(LANE_CWD, { recursive: true });
fs.mkdirSync(MAIN_CWD, { recursive: true });

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const HOOK = path.resolve(__dirname, '..', 'block-out-of-scope-edit.js');

// Run the hook with a given stdin payload and optional CELL_ROLE / cwd env.
function runHook({ payload, role, cwd, clearRole = true }) {
  const env = { ...process.env };
  if (clearRole) delete env.CELL_ROLE;
  if (role !== undefined) env.CELL_ROLE = role;
  const res = spawnSync(process.execPath, [HOOK], {
    input: typeof payload === 'string' ? payload : JSON.stringify(payload),
    env,
    cwd: cwd || process.cwd(),
    encoding: 'utf8'
  });
  return res;
}

function editPayload(filePath, tool = 'Edit') {
  return { tool_name: tool, tool_input: { file_path: filePath } };
}

function isBlock(res) {
  assert.equal(res.status, 0, 'hook must exit 0');
  const out = (res.stdout || '').trim();
  assert.ok(out.length > 0, 'expected block output on stdout');
  const parsed = JSON.parse(out);
  assert.equal(parsed.decision, 'block');
  assert.ok(typeof parsed.reason === 'string' && parsed.reason.length > 0);
  return parsed;
}

function isAllow(res) {
  assert.equal(res.status, 0, 'hook must exit 0');
  assert.equal((res.stdout || '').trim(), '', 'expected no output on allow');
}

// decomp-hook-block-rules
test('cell-portal editing .claude/rules/x.md is blocked', () => {
  const res = runHook({ payload: editPayload('.claude/rules/x.md'), role: 'cell-portal' });
  const parsed = isBlock(res);
  assert.match(parsed.reason, /cell-portal/);
  assert.match(parsed.reason, /\.claude\/rules\/x\.md/);
});

// decomp-hook-allow-inscope
test('cell-portal editing apps/prt/page.tsx is allowed', () => {
  const res = runHook({ payload: editPayload('apps/prt/page.tsx'), role: 'cell-portal' });
  isAllow(res);
});

// decomp-hook-sv-allow
test('sv editing .claude/rules/x.md is allowed', () => {
  const res = runHook({ payload: editPayload('.claude/rules/x.md'), role: 'sv' });
  isAllow(res);
});

// decomp-hook-failopen — unknown role
test('unknown role editing forbidden path is allowed (fail-open)', () => {
  // No CELL_ROLE and a cwd that does not resolve to a known role/worktree → _default.
  const res = runHook({
    payload: editPayload('.claude/rules/x.md'),
    cwd: path.parse(process.cwd()).root
  });
  isAllow(res);
});

// decomp-hook-failopen — missing path
test('missing target path is allowed (fail-open)', () => {
  const res = runHook({ payload: { tool_name: 'Edit', tool_input: {} }, role: 'cell-portal' });
  isAllow(res);
});

// decomp-hook-path-normalize
test('absolute worktree path normalizes to repo-relative and is blocked', () => {
  const res = runHook({
    payload: editPayload('C:/Dev/regen-root.wt/cell-portal/.claude/hooks/y.js'),
    role: 'cell-portal'
  });
  const parsed = isBlock(res);
  assert.match(parsed.reason, /\.claude\/hooks\/y\.js/);
  // The worktree prefix must be stripped from the reason.
  assert.doesNotMatch(parsed.reason, /regen-root\.wt/);
});

// decomp-hook-path-normalize — backslash absolute path
test('backslash absolute worktree path normalizes and is blocked', () => {
  const res = runHook({
    payload: editPayload('C:\\Dev\\regen-root.wt\\cell-portal\\.claude\\settings.json'),
    role: 'cell-portal'
  });
  const parsed = isBlock(res);
  assert.match(parsed.reason, /\.claude\/settings\.json/);
});

// decomp-hook-path-normalize — `..` traversal must be canonicalized so it cannot
// defeat the forbidden globs. `apps/prt/../../.claude/rules/x.md` collapses to the
// in-repo `.claude/rules/x.md`, which matches a forbidden glob → block.
test('cell-portal relative ../ traversal into forbidden path is blocked', () => {
  const res = runHook({
    payload: editPayload('apps/prt/../../.claude/rules/x.md'),
    role: 'cell-portal'
  });
  const parsed = isBlock(res);
  // Canonicalized to the bare forbidden path — no raw `..` survives into the reason.
  assert.match(parsed.reason, /\.claude\/rules\/x\.md/);
  assert.doesNotMatch(parsed.reason, /\.\.\//);
});

test('cell-portal absolute worktree path with ../ traversal is blocked', () => {
  const res = runHook({
    payload: editPayload('C:/Dev/regen-root.wt/cell-portal/apps/prt/../../.claude/rules/x.md'),
    role: 'cell-portal'
  });
  const parsed = isBlock(res);
  assert.match(parsed.reason, /\.claude\/rules\/x\.md/);
  assert.doesNotMatch(parsed.reason, /regen-root\.wt/);
  assert.doesNotMatch(parsed.reason, /\.\.\//);
});

// This payload has an extra `../` that escapes the repo root entirely, so it hits
// the fail-closed traversal-escape branch (cannot be proven in-scope) → block.
test('cell-portal ../ traversal escaping the repo root is blocked (fail-closed)', () => {
  const res = runHook({
    payload: editPayload('C:/Dev/regen-root.wt/cell-portal/../../regen-root/.claude/rules/x.md'),
    role: 'cell-portal'
  });
  const parsed = isBlock(res);
  assert.match(parsed.reason, /traversal/i);
});

// negative — a clean in-scope path with no traversal is still allowed
test('cell-portal editing apps/prt/page.tsx (no traversal) is allowed', () => {
  const res = runHook({ payload: editPayload('apps/prt/page.tsx'), role: 'cell-portal' });
  isAllow(res);
});

// negative — traversal under a full-access role (sv) stays fail-open/allowed
test('sv ../ traversal is allowed (full-access role, fail-open preserved)', () => {
  const res = runHook({
    payload: editPayload('apps/prt/../../.claude/rules/x.md'),
    role: 'sv'
  });
  isAllow(res);
});

// test-assert-hook-matrix — migrations ownership split
test('cell-data may edit supabase/migrations (allowed)', () => {
  const res = runHook({ payload: editPayload('supabase/migrations/x.sql'), role: 'cell-data' });
  isAllow(res);
});

test('cell-portal may NOT edit supabase/migrations (blocked)', () => {
  const res = runHook({ payload: editPayload('supabase/migrations/x.sql'), role: 'cell-portal' });
  const parsed = isBlock(res);
  assert.match(parsed.reason, /supabase\/migrations\/x\.sql/);
});

// test-assert-hook-matrix — broader role×path matrix
test('role×path matrix asserts correctly across scoped + full-access roles', () => {
  const cases = [
    // [role, path, expectBlock]
    ['cell-portal', '.claude/hooks/foo.js', true],
    ['cell-portal', '.claude/settings.json', true],
    ['cell-portal', 'scripts/wt.mjs', true],
    ['cell-portal', '.codex/hooks.json', true],
    ['cell-portal', 'AGENTS.md', true],
    ['cell-portal', 'apps/prt/CLAUDE.md', true],
    ['cell-portal', 'docs/systems/cs2/ARCHITECTURE.md', true],
    ['cell-portal', 'apps/prt/src/page.tsx', false],
    ['cell-portal', 'packages/ui/index.ts', false],
    ['cell-data', 'packages/supabase/client.ts', false],
    ['cell-data', '.claude/rules/x.md', true],
    ['cell-cs2', 'supabase/migrations/y.sql', true],
    ['cell-cs2', 'packages/cs2/core.ts', false],
    ['cell-mktg', 'scripts/deploy.mjs', true],
    ['cell-mktg', 'sites/foo/index.html', false],
    ['cell-infra', '.claude/rules/x.md', false],
    ['specialist', '.claude/hooks/x.js', false],
    ['codex', 'AGENTS.md', false],
    ['_default', '.claude/rules/x.md', false]
  ];
  for (const [role, p, expectBlock] of cases) {
    const res = runHook({ payload: editPayload(p), role });
    if (expectBlock) {
      isBlock(res);
    } else {
      isAllow(res);
    }
  }
});

// non-Edit tools are ignored
test('non-Edit tool is ignored (allowed)', () => {
  const res = runHook({
    payload: { tool_name: 'Read', tool_input: { file_path: '.claude/rules/x.md' } },
    role: 'cell-portal'
  });
  isAllow(res);
});

// MultiEdit uses path or file_path
test('MultiEdit with file_path to forbidden path is blocked', () => {
  const res = runHook({
    payload: { tool_name: 'MultiEdit', tool_input: { file_path: '.claude/rules/x.md' } },
    role: 'cell-portal'
  });
  isBlock(res);
});

// unparseable stdin → fail-open
test('unparseable stdin is allowed (fail-open)', () => {
  const res = runHook({ payload: 'not json at all {', role: 'cell-portal' });
  isAllow(res);
});

// ── Tree-boundary enforcement (cross-tree write guard) ──────────────────────
// A lane session (cwd under .../regen-root.wt/<name>) writing an absolute path
// into the MAIN tree is blocked, regardless of cell role — this is the guard
// that stops an isolated lane from corrupting the shared tree.

function isCrossTreeBlock(res) {
  const parsed = isBlock(res);
  assert.match(parsed.reason, /CROSS-TREE WRITE BLOCKED/);
  return parsed;
}

test('lane session writing an absolute MAIN-tree path is blocked (cross-tree)', () => {
  const res = runHook({
    payload: editPayload('C:/Dev/regen-root/apps/prt/src/app/page.tsx'),
    role: '_default', // warm-pool lanes resolve to _default → role-independent guard
    cwd: LANE_CWD
  });
  isCrossTreeBlock(res);
});

test('lane session writing into ANOTHER lane worktree is blocked (cross-tree)', () => {
  const res = runHook({
    payload: editPayload('C:/Dev/regen-root.wt/other-lane/apps/prt/page.tsx'),
    role: '_default',
    cwd: LANE_CWD
  });
  isCrossTreeBlock(res);
});

test('lane session writing a RELATIVE path is allowed (resolves in-lane)', () => {
  const res = runHook({
    payload: editPayload('apps/prt/src/app/page.tsx'),
    role: '_default',
    cwd: LANE_CWD
  });
  isAllow(res);
});

test('lane session writing inside its OWN worktree is allowed', () => {
  const res = runHook({
    payload: editPayload(path.join(LANE_CWD, 'apps/prt/src/app/page.tsx')),
    role: '_default',
    cwd: LANE_CWD
  });
  isAllow(res);
});

test('main/SV session writing an absolute MAIN-tree path is allowed (not a lane)', () => {
  const res = runHook({
    payload: editPayload('C:/Dev/regen-root/apps/prt/page.tsx'),
    role: '_default',
    cwd: MAIN_CWD
  });
  isAllow(res);
});

test('tree-boundary is enforced even for a package the lane role could edit', () => {
  // cell-portal CAN edit apps/prt in its own tree, but NOT in the main tree.
  const res = runHook({
    payload: editPayload('C:/Dev/regen-root/apps/prt/page.tsx'),
    role: 'cell-portal',
    cwd: LANE_CWD
  });
  isCrossTreeBlock(res);
});

// test-smoke-hook-nodecheck
test('hook passes node --check', () => {
  const res = spawnSync(process.execPath, ['--check', HOOK], { encoding: 'utf8' });
  assert.equal(res.status, 0, `node --check failed: ${res.stderr}`);
});
