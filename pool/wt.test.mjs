/**
 * wt.mjs tests — node:test (the repo convention; see needle-verify.test.mjs).
 *
 * NO real git/pnpm runs. wt.mjs takes an injectable `deps` ({ run, exists, log,
 * errlog }); every test passes a mock `run`/`exists` and asserts the exact git
 * arg vectors. A mock `run` that does NOT handle `worktree add` would throw if
 * called, which is how the re-attach test proves `worktree add` is never invoked.
 *
 * Coverage:
 *   (a) `add x` when the worktree dir exists re-attaches and does NOT call `worktree add`
 *   (b) `add x` builds base `origin/develop` AFTER `git fetch` (arg vector + order)
 *   (c) `remove x` dirty throws without --force, proceeds with --force
 *   (d) `prune` never removes a dirty entry (no worktree-remove call)
 *   (e) contract: subcommands are exactly add|enter|list|remove|prune
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  run, cmdAdd, cmdRemove, cmdPrune, propagateEnv, WtError,
  SUBCOMMANDS, wtPath, branchFor, REPO_ROOT, WT_ROOT, BASE_REMOTE, BASE_BRANCH,
} from '../wt.mjs';

/**
 * Build a mock deps. `handlers` maps a git-arg-vector signature → string output
 * (or a function). Any unhandled git call returns ''. `exists` is a predicate.
 * Every `run` invocation is recorded in `calls` for ordered assertions.
 */
function mockDeps({ handlers = {}, exists = () => false } = {}) {
  const calls = [];
  const logs = [];
  const errs = [];
  const deps = {
    calls,
    logs,
    errs,
    exists: (p) => exists(p),
    log: (s) => logs.push(String(s)),
    errlog: (s) => errs.push(String(s)),
    run(cmd, args, opts = {}) {
      calls.push({ cmd, args: [...args], cwd: opts.cwd });
      const key = `${cmd} ${args.join(' ')}`;
      for (const [sig, val] of Object.entries(handlers)) {
        if (key === sig || key.startsWith(sig)) {
          return typeof val === 'function' ? val(cmd, args) : val;
        }
      }
      return '';
    },
  };
  return deps;
}

function gitCalls(deps) {
  return deps.calls.filter((c) => c.cmd === 'git').map((c) => c.args.join(' '));
}

// ---------------------------------------------------------------------------

test('(a) add re-attaches when the worktree dir exists — never calls `worktree add`', () => {
  const dir = wtPath('reattach');
  const deps = mockDeps({
    exists: (p) => p === dir,
    handlers: {
      // re-attach validates the dir IS a real worktree on the expected branch
      // before reattaching (defensive guard in cmdAdd).
      'git rev-parse --is-inside-work-tree': 'true',
      'git rev-parse --abbrev-ref HEAD': branchFor('reattach'),
      // status --porcelain inside the existing worktree → clean
      'git status --porcelain': '',
      // If `worktree add` were ever called the test must fail loudly:
      'git worktree add': () => { throw new Error('worktree add MUST NOT run on re-attach'); },
      // If a fetch were called on re-attach it would also be wrong:
      'git fetch': () => { throw new Error('fetch MUST NOT run on re-attach'); },
    },
  });

  const code = cmdAdd(deps, 'reattach');
  assert.equal(code, 0, 're-attach exits 0');

  const calls = gitCalls(deps);
  assert.ok(!calls.some((c) => c.startsWith('worktree add')), 'no `worktree add`');
  assert.ok(!calls.some((c) => c.startsWith('fetch')), 'no `fetch`');
  assert.ok(deps.logs.some((l) => l.includes('re-attach')), 'reports re-attach');
  assert.ok(deps.logs.some((l) => l.includes(dir)), 'prints the existing path');
});

test('(b) add builds base origin/develop AFTER git fetch (arg vector + order)', () => {
  const deps = mockDeps({
    exists: () => false, // fresh: dir absent, branch absent
    handlers: {
      'git show-ref': () => { throw new Error('branch absent'); }, // branchExists → false
    },
  });

  const code = cmdAdd(deps, 'fresh', new Set(['--no-install']));
  assert.equal(code, 0);

  const calls = gitCalls(deps);
  const fetchIdx = calls.findIndex((c) => c === `fetch ${BASE_REMOTE} ${BASE_BRANCH}`);
  const addIdx = calls.findIndex((c) => c.startsWith('worktree add'));
  assert.ok(fetchIdx >= 0, 'git fetch origin develop was called');
  assert.ok(addIdx >= 0, 'git worktree add was called');
  assert.ok(fetchIdx < addIdx, 'fetch happens BEFORE worktree add (fresh base)');

  // The exact add arg vector: base is origin/develop, branch is wt/fresh.
  const addArgs = deps.calls.find((c) => c.cmd === 'git' && c.args[0] === 'worktree' && c.args[1] === 'add').args;
  assert.deepEqual(addArgs, [
    'worktree', 'add', wtPath('fresh'), '-b', branchFor('fresh'), `${BASE_REMOTE}/${BASE_BRANCH}`,
  ], 'base is origin/develop HEAD, never current HEAD');

  // --no-install means pnpm must never run.
  assert.ok(!deps.calls.some((c) => c.cmd === 'pnpm'), 'no pnpm install with --no-install');
});

test('(b2) add re-adds onto an EXISTING branch when dir gone but branch present (preserves committed work)', () => {
  const deps = mockDeps({
    exists: () => false, // dir gone
    handlers: {
      'git show-ref --verify --quiet refs/heads/wt/recover': '', // branchExists → true (ok)
    },
  });
  cmdAdd(deps, 'recover', new Set(['--no-install']));
  const addArgs = deps.calls.find((c) => c.cmd === 'git' && c.args[0] === 'worktree' && c.args[1] === 'add').args;
  // No -b, no origin/develop — re-add onto the existing branch.
  assert.deepEqual(addArgs, ['worktree', 'add', wtPath('recover'), branchFor('recover')]);
});

test('(b3) add keeps the worktree when pnpm install is unavailable', () => {
  const pnpmCmd = process.platform === 'win32' ? 'pnpm.cmd' : 'pnpm';
  const deps = mockDeps({
    exists: () => false,
    handlers: {
      'git show-ref': () => { throw new Error('branch absent'); },
      [`${pnpmCmd} install`]: () => {
        const err = new Error('spawn ENOENT');
        err.code = 'ENOENT';
        throw err;
      },
    },
  });

  const code = cmdAdd(deps, 'missing-pnpm');
  assert.equal(code, 0);
  assert.ok(deps.calls.some((c) => c.cmd === pnpmCmd), 'attempts platform pnpm command');
  assert.ok(deps.logs.some((l) => l.includes('install-warn')), 'logs non-fatal install warning');
  assert.ok(deps.logs.some((l) => l.includes('worktree ready')), 'worktree remains ready');
});

test('(b4) add fails when pnpm install runs but exits unsuccessfully', () => {
  const pnpmCmd = process.platform === 'win32' ? 'pnpm.cmd' : 'pnpm';
  const deps = mockDeps({
    exists: () => false,
    handlers: {
      'git show-ref': () => { throw new Error('branch absent'); },
      [`${pnpmCmd} install`]: () => {
        const err = new Error('install failed');
        err.status = 1;
        throw err;
      },
    },
  });

  assert.throws(() => cmdAdd(deps, 'failed-install'), /install failed/);
});

test('(c) remove on a DIRTY worktree throws without --force, proceeds with --force', () => {
  const dir = wtPath('dirty');
  const makeDeps = () => mockDeps({
    exists: (p) => p === dir,
    handlers: {
      'git status --porcelain': ' M packages/foo/bar.ts\n?? new.ts', // 2 dirty entries
    },
  });

  // Without --force: throws, never calls `worktree remove`.
  const d1 = makeDeps();
  assert.throws(() => cmdRemove(d1, 'dirty'), (e) => {
    assert.ok(e instanceof WtError);
    assert.match(e.message, /uncommitted change/i);
    return true;
  });
  assert.ok(!gitCalls(d1).some((c) => c.startsWith('worktree remove')), 'no remove when dirty + no force');

  // With --force: proceeds — calls `worktree remove --force` then `branch -D`.
  const d2 = makeDeps();
  const code = cmdRemove(d2, 'dirty', new Set(['--force']));
  assert.equal(code, 0);
  const calls = gitCalls(d2);
  assert.ok(calls.some((c) => c === `worktree remove --force ${dir}`), 'forced worktree remove');
  assert.ok(calls.some((c) => c === `branch -D ${branchFor('dirty')}`), 'force-deletes branch with -D');
});

test('(c2) remove on a CLEAN worktree uses -d (safe, merged-only) and no --force', () => {
  const dir = wtPath('clean');
  const deps = mockDeps({
    exists: (p) => p === dir,
    handlers: { 'git status --porcelain': '' },
  });
  cmdRemove(deps, 'clean');
  const calls = gitCalls(deps);
  assert.ok(calls.some((c) => c === `worktree remove ${dir}`), 'plain remove (no --force)');
  assert.ok(calls.some((c) => c === `branch -d ${branchFor('clean')}`), 'safe -d branch delete');
});

test('(d) prune never removes a dirty entry (no worktree-remove call)', () => {
  const dirtyPath = `${WT_ROOT}/aborted`.split('\\').join('/');
  const deps = mockDeps({
    exists: () => true,
    handlers: {
      'git worktree prune': '', // prune itself only drops gone-dir admin entries
      'git worktree list --porcelain':
        `worktree ${dirtyPath}\nbranch refs/heads/wt/aborted\n`,
      'git status --porcelain': ' M scripts/wt.mjs', // the sibling is dirty
    },
  });

  const code = cmdPrune(deps);
  assert.equal(code, 0);
  const calls = gitCalls(deps);
  assert.ok(calls.some((c) => c === 'worktree prune -v'), 'calls git worktree prune');
  assert.ok(!calls.some((c) => c.startsWith('worktree remove')), 'prune NEVER calls worktree remove');
  assert.ok(deps.logs.some((l) => l.includes('preserved (dirty')), 'reports the dirty worktree as preserved');
  assert.ok(deps.logs.some((l) => l.includes(dirtyPath)), 'names the preserved worktree');
});

test('(e) contract: subcommand surface is exactly add|enter|list|remove|prune', () => {
  assert.deepEqual([...SUBCOMMANDS].sort(), ['add', 'enter', 'list', 'prune', 'remove']);

  // Unknown subcommand → usage + exit 1; no git runs.
  const deps = mockDeps();
  const code = run(['node', 'wt.mjs', 'bogus'], deps);
  assert.equal(code, 1);
  assert.ok(deps.errs.some((e) => e.includes('unknown subcommand')), 'errors on unknown subcommand');
  assert.ok(!deps.calls.some((c) => c.cmd === 'git'), 'no git run for an unknown subcommand');

  // No subcommand → usage + exit 1.
  const d2 = mockDeps();
  assert.equal(run(['node', 'wt.mjs'], d2), 1);
  assert.ok(d2.logs.some((l) => l.includes('Usage:')), 'prints usage');
});

// ---------------------------------------------------------------------------
// propagateEnv tests (WP-4 — env file copy into worktrees)
// ---------------------------------------------------------------------------

import { mkdtempSync, writeFileSync, mkdirSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

test('(f) propagateEnv copies missing .env.local and skips existing (never clobbers)', () => {
  // Create a temp "repo" and a temp "worktree"
  const base = mkdtempSync(path.join(tmpdir(), 'wt-env-'));
  const repo = path.join(base, 'repo');
  const wt = path.join(base, 'wt');
  mkdirSync(repo, { recursive: true });
  mkdirSync(wt, { recursive: true });

  // Create source files in repo
  writeFileSync(path.join(repo, '.env.local'), 'REPO_SECRET=abc');
  writeFileSync(path.join(repo, '.env'), 'ROOT_ENV=1');
  mkdirSync(path.join(repo, 'apps', 'myapp'), { recursive: true });
  writeFileSync(path.join(repo, 'apps', 'myapp', '.env.local'), 'APP_SECRET=xyz');
  mkdirSync(path.join(repo, '.claude'), { recursive: true });
  writeFileSync(path.join(repo, '.claude', 'settings.local.json'), '{}');

  // Pre-create ONE file in the worktree (should NOT be overwritten)
  mkdirSync(path.join(wt, 'apps', 'myapp'), { recursive: true });
  writeFileSync(path.join(wt, 'apps', 'myapp', '.env.local'), 'WORKTREE_LOCAL_EDIT=keep');

  const logs = [];
  const logDeps = {
    log: (s) => logs.push(s),
    errlog: (s) => logs.push(s),
    exists: existsSync,
  };

  propagateEnv(repo, wt, logDeps);

  // .env.local at root should be copied (was missing in worktree)
  assert.equal(readFileSync(path.join(wt, '.env.local'), 'utf8'), 'REPO_SECRET=abc');
  // .env at root should be copied
  assert.equal(readFileSync(path.join(wt, '.env'), 'utf8'), 'ROOT_ENV=1');
  // .claude/settings.local.json should be copied
  assert.equal(readFileSync(path.join(wt, '.claude', 'settings.local.json'), 'utf8'), '{}');
  // apps/myapp/.env.local should NOT be overwritten — original content preserved
  assert.equal(readFileSync(path.join(wt, 'apps', 'myapp', '.env.local'), 'utf8'), 'WORKTREE_LOCAL_EDIT=keep');

  // Logs should show copied vs skipped
  assert.ok(logs.some((l) => l.includes('env-copy') && l.includes('.env.local')), 'logs copied root .env.local');
  // path.join uses OS separators — on Windows the log has apps\myapp, on Unix apps/myapp
  assert.ok(logs.some((l) => l.includes('env-skip') && l.includes('myapp')), 'logs skipped existing app .env.local');
});

test('(g) re-attach path calls propagateEnv (env copy runs on both fresh and re-attach)', () => {
  const dir = wtPath('env-reattach');
  const deps = mockDeps({
    exists: (p) => p === dir,
    handlers: {
      'git rev-parse --is-inside-work-tree': 'true',
      'git rev-parse --abbrev-ref HEAD': branchFor('env-reattach'),
      'git status --porcelain': '',
      'git worktree add': () => { throw new Error('worktree add MUST NOT run on re-attach'); },
      'git fetch': () => { throw new Error('fetch MUST NOT run on re-attach'); },
    },
  });

  // Patch deps to track propagateEnv activity: propagateEnv reads real fs
  // via readdirSync/existsSync, but the mock repo root (REPO_ROOT) IS the real
  // repo — so propagateEnv will discover and try to copy real env files. Since
  // the worktree dir doesn't really exist on disk, the copies will fail
  // (ENOENT on mkdir). That's fine — we just need to verify it WAS called by
  // checking for the "env propagation:" summary line in logs.
  const code = cmdAdd(deps, 'env-reattach');
  assert.equal(code, 0, 're-attach exits 0');
  assert.ok(
    deps.logs.some((l) => l.includes('env propagation:')),
    'propagateEnv was called during re-attach (summary line present)'
  );
});
