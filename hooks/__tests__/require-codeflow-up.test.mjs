import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const dir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(dir, '..', '..', '..');
const hooks = [
  path.join(repoRoot, '.claude', 'hooks', 'require-codeflow-up.js'),
  path.join(repoRoot, '.codex', 'hooks', 'require-codeflow-up.js'),
];

function fakeHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'codeflow-hook-test-'));
  const cache = path.join(home, '.codeflow');
  fs.mkdirSync(cache, { recursive: true });
  fs.writeFileSync(path.join(cache, 'router-health.json'), JSON.stringify({
    ts: Date.now(),
    live: true,
    ok: true,
    status: 'offline',
  }));
  return home;
}

function runHook(script, payload, extraEnv = {}) {
  const home = fakeHome();
  const env = { ...process.env, ...extraEnv };
  delete env.CODEFLOW_ENFORCE;
  env.USERPROFILE = home;
  env.HOME = home;
  const result = spawnSync(process.execPath, [script], {
    input: JSON.stringify(payload),
    encoding: 'utf8',
    env,
    timeout: 3000,
  });
  assert.equal(result.status, 0, `${script} exits cleanly`);
  return JSON.parse(result.stdout || '{}');
}

test('CodeFlow self-repair env bypass lets both guards repair allowlisted targets without a health probe dependency', () => {
  for (const script of hooks) {
    const started = Date.now();
    const output = runHook(script, {
      tool_name: 'Write',
      tool_input: { file_path: 'packages/codeflow/src/brain/readiness.ts' },
    }, { CODEFLOW_SELF_REPAIR: '1' });
    assert.deepEqual(output, { hookSpecificOutput: { hookEventName: 'PreToolUse' } });
    assert.ok(Date.now() - started < 1000, `${script} did not wait on router health`);
  }
});

test('CodeFlow self-repair env bypass does not allow unrelated app targets', () => {
  for (const script of hooks) {
    const output = runHook(script, {
      tool_name: 'Write',
      tool_input: { file_path: 'apps/example/page.tsx', content: 'mentions packages/codeflow but is not a CodeFlow file' },
    }, { CODEFLOW_SELF_REPAIR: '1' });
    assert.equal(output.hookSpecificOutput?.permissionDecision, 'deny');
    assert.match(output.hookSpecificOutput?.permissionDecisionReason || '', /CODEFLOW IS DOWN/);
  }
});

test('scoped command marker is implemented with parity across Claude and Codex hooks', () => {
  for (const script of hooks) {
    const source = fs.readFileSync(script, 'utf8');
    assert.match(source, /function isCodeflowSelfRepair\(event\)/);
    assert.match(source, /function resolveRepoRoot\(\)/);
    assert.match(source, /process\.cwd\(\)/);
    assert.match(source, /scripts', 'codeflow-ensure-up\.mjs'/);
    assert.match(source, /CODEFLOW_SELF_REPAIR/);
    assert.match(source, /CODEFLOW_FIXER/);
    assert.match(source, /normalizeRepoPath/);
    assert.match(source, /isSelfRepairPath/);
    assert.ok(source.includes(`p === '.claude/hooks/require-codeflow-up.js'`));
    assert.ok(source.includes(`p === '.codex/hooks/require-codeflow-up.js'`));
    assert.ok(source.includes(`p.startsWith('packages/codeflow/')`));
    assert.ok(source.includes(`p === 'scripts/codeflow-local.config.js'`));
    assert.ok(source.includes(`scripts\\/codeflow[-\\w.]*\\.mjs`));
    assert.match(source, /allowlisted CodeFlow\/hook repair targets/);
  }
});

test('CodeFlow self-repair env bypass allows the local PM2 ecosystem config', () => {
  for (const script of hooks) {
    const output = runHook(script, {
      tool_name: 'Write',
      tool_input: { file_path: 'scripts/codeflow-local.config.js' },
    }, { CODEFLOW_SELF_REPAIR: '1' });
    assert.deepEqual(output, { hookSpecificOutput: { hookEventName: 'PreToolUse' } });
  }
});

test('command-scoped marker allows CodeFlow repair targets only', () => {
  const payload = {
    tool_name: 'Bash',
    tool_input: { command: 'CODEFLOW_SELF_REPAIR=1 node scripts/codeflow-ensure-up.mjs' },
  };
  for (const script of hooks) {
    const output = runHook(script, payload);
    assert.deepEqual(output, { hookSpecificOutput: { hookEventName: 'PreToolUse' } });
    const source = fs.readFileSync(script, 'utf8');
    assert.match(source, /SELF_REPAIR_MARKER\.test\(command\)/);
    assert.match(source, /return marked && \(explicitToolPathTarget\(event\) \|\| isSelfRepairShellCommand/);
    assert.doesNotMatch(source, /JSON\.stringify\(event\.tool_input/);
  }
});

test('marked arbitrary commands do not pass by mentioning an allowlisted token', () => {
  const payload = {
    tool_name: 'Bash',
    tool_input: { command: 'CODEFLOW_SELF_REPAIR=1 echo packages/codeflow' },
  };
  for (const script of hooks) {
    const output = runHook(script, payload);
    assert.equal(output.hookSpecificOutput?.permissionDecision, 'deny');
  }
});

test('nested app paths that contain packages/codeflow are not self-repair targets', () => {
  for (const script of hooks) {
    const output = runHook(script, {
      tool_name: 'Write',
      tool_input: { file_path: 'apps/example/packages/codeflow/fake.ts' },
    }, { CODEFLOW_SELF_REPAIR: '1' });
    assert.equal(output.hookSpecificOutput?.permissionDecision, 'deny');
  }
});

test('dot-segment traversal out of packages/codeflow is not a self-repair target', () => {
  for (const script of hooks) {
    const output = runHook(script, {
      tool_name: 'Write',
      tool_input: { file_path: 'packages/codeflow/../../apps/example/page.tsx' },
    }, { CODEFLOW_SELF_REPAIR: '1' });
    assert.equal(output.hookSpecificOutput?.permissionDecision, 'deny');
  }
});

test('patch targets that traverse out of packages/codeflow are denied', () => {
  const patch = [
    '*** Begin Patch',
    '*** Update File: packages/codeflow/../../apps/example/page.tsx',
    '@@',
    '-old',
    '+new',
    '*** End Patch',
  ].join('\n');
  for (const script of hooks) {
    const output = runHook(script, {
      tool_name: 'apply_patch',
      tool_input: { command: patch },
    }, { CODEFLOW_SELF_REPAIR: '1' });
    assert.equal(output.hookSpecificOutput?.permissionDecision, 'deny');
  }
});

test('valid patch payloads under packages/codeflow are self-repair targets', () => {
  const patch = [
    '*** Begin Patch',
    '*** Update File: packages/codeflow/src/brain/readiness.ts',
    '@@',
    '-old',
    '+new',
    '*** End Patch',
  ].join('\n');
  for (const script of hooks) {
    const output = runHook(script, {
      tool_name: 'apply_patch',
      tool_input: { command: patch },
    }, { CODEFLOW_SELF_REPAIR: '1' });
    assert.deepEqual(output, { hookSpecificOutput: { hookEventName: 'PreToolUse' } });
  }
});

test('marked compound repair-looking commands do not pass', () => {
  const payload = {
    tool_name: 'Bash',
    tool_input: { command: 'CODEFLOW_SELF_REPAIR=1 node scripts/codeflow-ensure-up.mjs; echo nope' },
  };
  for (const script of hooks) {
    const output = runHook(script, payload);
    assert.equal(output.hookSpecificOutput?.permissionDecision, 'deny');
  }
});

test('marked pnpm filter commands cannot launch arbitrary node execution', () => {
  const payload = {
    tool_name: 'Bash',
    tool_input: { command: 'CODEFLOW_SELF_REPAIR=1 pnpm --filter @regen/codeflow exec node -e "console.log(1)"' },
  };
  for (const script of hooks) {
    const output = runHook(script, payload);
    assert.equal(output.hookSpecificOutput?.permissionDecision, 'deny');
  }
});

test('both require-codeflow-up hooks pass syntax check', () => {
  for (const script of hooks) {
    execFileSync(process.execPath, ['--check', script], { encoding: 'utf8' });
  }
});

test('auto-heal strips brain-forcing env with parity across Claude and Codex hooks', () => {
  for (const script of hooks) {
    const source = fs.readFileSync(script, 'utf8');
    assert.match(source, /const \{ CODEFLOW_BRAIN, NEO4J_PASSWORD, CODEFLOW_SELF_BRAINS, \.\.\.env \} = process\.env;/);
    assert.match(source, /void CODEFLOW_BRAIN; void NEO4J_PASSWORD; void CODEFLOW_SELF_BRAINS;/);
  }
});

test('sentinel-file break-glass allows ANY tool mid-session (env-plumbing independent) — both engines', () => {
  for (const script of hooks) {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), 'codeflow-hook-bg-'));
    const cache = path.join(home, '.codeflow');
    fs.mkdirSync(cache, { recursive: true });
    fs.writeFileSync(path.join(cache, 'router-health.json'), JSON.stringify({ ts: Date.now(), live: true, ok: true, status: 'offline' }));
    fs.writeFileSync(path.join(cache, 'break-glass'), '');
    const env = { ...process.env, USERPROFILE: home, HOME: home };
    delete env.CODEFLOW_ENFORCE;
    const r = spawnSync(process.execPath, [script], {
      input: JSON.stringify({ tool_name: 'Bash', tool_input: { command: 'git status && ssh root@host pm2 restart codeflow' } }),
      encoding: 'utf8', env, timeout: 3000,
    });
    assert.equal(r.status, 0, script + ' exits cleanly');
    assert.deepEqual(JSON.parse(r.stdout || '{}'), { hookSpecificOutput: { hookEventName: 'PreToolUse' } },
      script + ': sentinel break-glass must allow an arbitrary (non-allowlisted) fixer command');
  }
});

test('planned-downtime sentinel allows read/search fallback and defers writes — both engines', () => {
  for (const script of hooks) {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), 'codeflow-hook-planned-'));
    const cache = path.join(home, '.codeflow');
    fs.mkdirSync(cache, { recursive: true });
    fs.writeFileSync(path.join(cache, 'router-health.json'), JSON.stringify({ ts: Date.now(), live: false, ok: false, status: 'ECONNREFUSED' }));
    fs.writeFileSync(path.join(cache, 'planned-downtime.json'), JSON.stringify({
      paused: true,
      reason: 'planned singleton upgrade',
      expires_at: new Date(Date.now() + 60_000).toISOString(),
    }));
    const env = { ...process.env, USERPROFILE: home, HOME: home };
    delete env.CODEFLOW_ENFORCE;
    const r = spawnSync(process.execPath, [script], {
      input: JSON.stringify({ tool_name: 'Grep', tool_input: { pattern: 'codeflow', path: 'packages/codeflow' } }),
      encoding: 'utf8', env, timeout: 3000,
    });
    assert.equal(r.status, 0, script + ' exits cleanly');
    const output = JSON.parse(r.stdout || '{}').hookSpecificOutput;
    assert.equal(output?.permissionDecision, undefined, script + ': planned downtime must not hard-deny');
    assert.match(output?.additionalContext || '', /PLANNED-DOWNTIME/, script + ': planned downtime is visible');
    assert.match(output?.additionalContext || '', /grep\/direct file-tree reads/, script + ': fallback guidance is explicit');

    const shellRead = spawnSync(process.execPath, [script], {
      input: JSON.stringify({ tool_name: 'Bash', tool_input: { command: 'rg codeflow packages/codeflow' } }),
      encoding: 'utf8', env, timeout: 3000,
    });
    assert.equal(shellRead.status, 0, script + ' allows shell search to exit cleanly');
    const shellOutput = JSON.parse(shellRead.stdout || '{}').hookSpecificOutput;
    assert.equal(shellOutput?.permissionDecision, undefined, script + ': planned downtime must allow shell grep/rg');
    assert.match(shellOutput?.additionalContext || '', /PLANNED-DOWNTIME/);

    const write = spawnSync(process.execPath, [script], {
      input: JSON.stringify({ tool_name: 'Write', tool_input: { file_path: 'packages/codeflow/src/brain/readiness.ts', content: 'x' } }),
      encoding: 'utf8', env, timeout: 3000,
    });
    assert.equal(write.status, 0, script + ' denies write through JSON output, not process failure');
    const writeOutput = JSON.parse(write.stdout || '{}').hookSpecificOutput;
    assert.equal(writeOutput?.permissionDecision, 'deny', script + ': planned downtime must defer writes');
    assert.match(writeOutput?.permissionDecisionReason || '', /deferred during planned downtime/);
  }
});

test('CODEFLOW_ENFORCE=0 break-glass allows any tool — both engines', () => {
  for (const script of hooks) {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), 'codeflow-hook-enf-'));
    const cache = path.join(home, '.codeflow');
    fs.mkdirSync(cache, { recursive: true });
    fs.writeFileSync(path.join(cache, 'router-health.json'), JSON.stringify({ ts: Date.now(), live: true, ok: true, status: 'offline' }));
    const env = { ...process.env, USERPROFILE: home, HOME: home, CODEFLOW_ENFORCE: '0' };
    const r = spawnSync(process.execPath, [script], {
      input: JSON.stringify({ tool_name: 'Bash', tool_input: { command: 'node scripts/hydrate.mjs --brain dev' } }),
      encoding: 'utf8', env, timeout: 3000,
    });
    assert.equal(r.status, 0);
    assert.deepEqual(JSON.parse(r.stdout || '{}'), { hookSpecificOutput: { hookEventName: 'PreToolUse' } });
  }
});

test('live-but-unready NEVER infinite-denies: degrades to allow after MAX_UNREADY — both engines', () => {
  for (const script of hooks) {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), 'codeflow-hook-unready-'));
    const cache = path.join(home, '.codeflow');
    fs.mkdirSync(cache, { recursive: true });
    const env = { ...process.env, USERPROFILE: home, HOME: home };
    delete env.CODEFLOW_ENFORCE;
    const payload = JSON.stringify({ tool_name: 'Read', tool_input: { file_path: 'apps/example/page.tsx' } });
    const decisions = [];
    for (let i = 0; i < 7; i++) {
      fs.writeFileSync(path.join(cache, 'router-health.json'), JSON.stringify({ ts: Date.now(), live: true, ok: true, status: 'offline' }));
      const r = spawnSync(process.execPath, [script], { input: payload, encoding: 'utf8', env, timeout: 3000 });
      decisions.push(JSON.parse(r.stdout || '{}').hookSpecificOutput);
    }
    assert.equal(decisions[0]?.permissionDecision, 'deny', script + ': denies while the streak is small');
    const last = decisions[6];
    assert.equal(last?.permissionDecision, undefined, script + ': must stop denying after MAX_UNREADY');
    assert.match(last?.additionalContext || '', /DEGRADED-ALLOW/, script + ': degrade-allows instead of bricking');
  }
});
