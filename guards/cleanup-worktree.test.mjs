// Tests for the worktree cleanup classification logic used by
// scripts/cleanup-agent-jobs.ps1 (WP-3, Worktree Isolation epic 3e300047).
//
// The PowerShell Stop hook is hard to exercise directly (it needs real
// processes + git worktrees), so the *classification decision* — the load-bearing
// safety logic — is extracted here as a pure JS function that mirrors the
// PowerShell `Classify-Worktree` / `Select-BranchGc` rules exactly. Both
// implementations encode the same contract:
//
//   - dirty *.wt/* worktree              -> PRESERVE (recover-report), NEVER removed
//   - clean + branch merged + claude-* POOL slot -> KEEP (warm pool, never GC'd)
//   - clean + branch merged into develop -> GC (eligible for git worktree remove)
//   - clean + branch NOT merged          -> KEEP (unmerged work, not GC'd)
//   - worktree with a live owning process -> KEEP (skip, e.g. Codex/cell)
//   - gone wt/*|cell/* branch, no live worktree -> DELETE (git branch -D)
//   - branch WITH a live worktree              -> KEEP (never deleted)
//
// Pool-slot exemption: a warm launcher-cd pool slot is a sibling worktree whose
// path matches `regen-root.wt[\\/]claude-\d+` (e.g. C:/Dev/regen-root.wt/claude-1).
// These are kept warm on purpose so the launcher can hand them out instantly, so
// they are exempt from GC even when clean + merged. The exemption is checked AFTER
// the dirty->PRESERVE invariant (a dirty pool slot is still preserved, not GC'd).
//
// Core invariant under test: under NO input may a dirty worktree be classified GC.
//
// Run: node --test scripts/__tests__/cleanup-worktree.test.mjs
// (matches the sibling needle-verify.test.mjs convention; no vitest dep at root.)
import { test } from 'node:test';
import assert from 'node:assert/strict';

/**
 * Classify a single worktree for the Stop-hook GC pass.
 * Mirrors PowerShell `Classify-Worktree` in cleanup-agent-jobs.ps1.
 *
 * @param {object} wt
 * @param {string} wt.path        worktree path
 * @param {string} wt.branch      branch name (or 'DETACHED')
 * @param {number} wt.dirtyFiles  count from `git status --porcelain`
 * @param {boolean} wt.merged     branch fully merged into develop
 * @param {boolean} wt.liveProcess a live owning process holds this worktree
 * @param {boolean} [wt.isPoolSlot] path matches a warm `claude-*` pool slot
 *   (regen-root.wt[\\/]claude-\d+); kept warm, exempt from GC. Defaults to false.
 * @returns {'PRESERVE'|'GC'|'KEEP'}
 */
export function classifyWorktree(wt) {
  // A live owning process (Codex, an active cell) is never touched.
  if (wt.liveProcess) return 'KEEP';
  // CORE INVARIANT: any uncommitted change => preserve + report, never remove.
  if (wt.dirtyFiles > 0) return 'PRESERVE';
  // Warm claude-* pool slot — kept warm on purpose, never GC'd even when merged.
  if (wt.isPoolSlot) return 'KEEP';
  // Clean. Only GC when the branch is fully merged into develop.
  if (wt.merged) return 'GC';
  // Clean but unmerged work — keep it; the branch carries committed work.
  return 'KEEP';
}

/**
 * Decide whether a local branch is eligible for `git branch -D`.
 * Mirrors PowerShell `Select-BranchGc` in cleanup-agent-jobs.ps1.
 * Only wt/* and cell/* branches are in scope.
 *
 * @param {object} br
 * @param {string} br.name          branch name
 * @param {boolean} br.goneOnRemote upstream is '[gone]'
 * @param {boolean} br.hasWorktree  a live worktree is checked out on this branch
 * @returns {boolean} true => eligible for git branch -D
 */
export function shouldDeleteBranch(br) {
  const inScope = /^(wt|cell)\//.test(br.name);
  if (!inScope) return false;
  // A branch with a live worktree is NEVER deleted.
  if (br.hasWorktree) return false;
  // Eligible only when gone on remote and detached from any worktree.
  return br.goneOnRemote === true;
}

/**
 * Is this sibling worktree a warm launcher-cd pool slot? Mirrors the PowerShell
 * `$isPoolSlot` regex in cleanup-agent-jobs.ps1 AFTER Normalize-Text (lowercase,
 * '/' -> '\'). BOTH claude-N (Claude pool) and x-codex-N (Codex warm lanes) are
 * warm pool slots — kept warm so the launcher can hand them out instantly, hence
 * exempt from GC even when clean+merged. The missing x-codex-N arm was the
 * lane-disappearance bug: an idle clean+merged Codex lane got `git worktree
 * remove`d out from under Codex.
 *
 * @param {string} wtPath  worktree path (any slash/case)
 * @returns {boolean}
 */
export function isWarmPoolSlot(wtPath) {
  if (!wtPath) return false;
  const norm = String(wtPath).toLowerCase().replace(/\//g, '\\');
  return /regen-root\.wt\\(claude|x-codex)-\d+/.test(norm);
}

test('classifyWorktree: dirty *.wt worktree -> PRESERVE (never GC)', () => {
  assert.equal(classifyWorktree({
    path: 'C:/Dev/regen-root.wt/cell-data',
    branch: 'cell/data',
    dirtyFiles: 3,
    merged: false,
    liveProcess: false,
  }), 'PRESERVE');
});

test('classifyWorktree: dirty worktree whose branch IS merged is STILL preserved', () => {
  // Even a merged branch must not lose uncommitted working-tree edits.
  assert.equal(classifyWorktree({
    path: 'C:/Dev/regen-root.wt/x',
    branch: 'wt/x',
    dirtyFiles: 1,
    merged: true,
    liveProcess: false,
  }), 'PRESERVE');
});

test('classifyWorktree: clean + merged worktree -> GC', () => {
  assert.equal(classifyWorktree({
    path: 'C:/Dev/regen-root.wt/x',
    branch: 'wt/x',
    dirtyFiles: 0,
    merged: true,
    liveProcess: false,
  }), 'GC');
});

test('classifyWorktree: clean but UNmerged worktree -> KEEP (not GC)', () => {
  assert.equal(classifyWorktree({
    path: 'C:/Dev/regen-root.wt/y',
    branch: 'wt/y',
    dirtyFiles: 0,
    merged: false,
    liveProcess: false,
  }), 'KEEP');
});

test('classifyWorktree: live owning process -> KEEP even if clean+merged', () => {
  assert.equal(classifyWorktree({
    path: 'C:/Dev/regen-root.wt/cell-cs2',
    branch: 'cell/cs2',
    dirtyFiles: 0,
    merged: true,
    liveProcess: true,
  }), 'KEEP');
});

test('classifyWorktree: clean + merged claude-* POOL slot -> KEEP (warm, not GC)', () => {
  assert.equal(classifyWorktree({
    path: 'C:/Dev/regen-root.wt/claude-1',
    branch: 'wt/claude-1',
    dirtyFiles: 0,
    merged: true,
    liveProcess: false,
    isPoolSlot: true,
  }), 'KEEP');
});

test('classifyWorktree: dirty claude-* POOL slot -> PRESERVE (dirty still wins)', () => {
  assert.equal(classifyWorktree({
    path: 'C:/Dev/regen-root.wt/claude-2',
    branch: 'wt/claude-2',
    dirtyFiles: 4,
    merged: true,
    liveProcess: false,
    isPoolSlot: true,
  }), 'PRESERVE');
});

test('classifyWorktree: clean + merged x-codex-* warm lane -> KEEP (was the GC bug)', () => {
  // Regression for the lane-disappearance bug: an idle clean+merged Codex lane
  // must NOT be GC'd. isPoolSlot now covers x-codex-N as well as claude-N.
  assert.equal(classifyWorktree({
    path: 'C:/Dev/regen-root.wt/x-codex-2',
    branch: 'wt/x-codex-2',
    dirtyFiles: 0,
    merged: true,
    liveProcess: false,
    isPoolSlot: true,
  }), 'KEEP');
});

test('classifyWorktree: leased x-codex-* lane (liveProcess via lock PID) -> KEEP', () => {
  // The launcher's command line is the launch SCRIPT path, so live-ness is proven
  // via the .cell-state/<lane>.lock PID and surfaces here as liveProcess=true.
  assert.equal(classifyWorktree({
    path: 'C:/Dev/regen-root.wt/x-codex-1',
    branch: 'wt/x-codex-1',
    dirtyFiles: 0,
    merged: true,
    liveProcess: true,
    isPoolSlot: true,
  }), 'KEEP');
});

test('isWarmPoolSlot: claude-N and x-codex-N are warm pool slots', () => {
  assert.equal(isWarmPoolSlot('C:/Dev/regen-root.wt/claude-1'), true);
  assert.equal(isWarmPoolSlot('C:/Dev/regen-root.wt/x-codex-2'), true);
  assert.equal(isWarmPoolSlot('C:\\Dev\\regen-root.wt\\x-codex-12'), true);
});

test('isWarmPoolSlot: cells, the main tree, and ad-hoc worktrees are NOT pool slots', () => {
  assert.equal(isWarmPoolSlot('C:/Dev/regen-root.wt/cell-data'), false);
  assert.equal(isWarmPoolSlot('C:/Dev/regen-root.wt/promote'), false);
  assert.equal(isWarmPoolSlot('C:/Dev/regen-root'), false);
  assert.equal(isWarmPoolSlot(''), false);
});

test('classifyWorktree: REGRESSION — non-pool clean + merged still -> GC', () => {
  assert.equal(classifyWorktree({
    path: 'C:/Dev/regen-root.wt/x',
    branch: 'wt/x',
    dirtyFiles: 0,
    merged: true,
    liveProcess: false,
    isPoolSlot: false,
  }), 'GC');
});

test('classifyWorktree: CORE INVARIANT — no dirty worktree is ever classified GC', () => {
  for (const merged of [true, false]) {
    for (const liveProcess of [true, false]) {
      for (const dirtyFiles of [1, 5, 99]) {
        const decision = classifyWorktree({
          path: 'C:/Dev/regen-root.wt/inv',
          branch: 'wt/inv',
          dirtyFiles,
          merged,
          liveProcess,
        });
        assert.notEqual(decision, 'GC');
      }
    }
  }
});

test('shouldDeleteBranch: gone wt/* branch with no worktree -> delete', () => {
  assert.equal(shouldDeleteBranch({
    name: 'wt/feature',
    goneOnRemote: true,
    hasWorktree: false,
  }), true);
});

test('shouldDeleteBranch: gone cell/* branch with no worktree -> delete', () => {
  assert.equal(shouldDeleteBranch({
    name: 'cell/data',
    goneOnRemote: true,
    hasWorktree: false,
  }), true);
});

test('shouldDeleteBranch: gone wt/* branch WITH a live worktree -> keep', () => {
  assert.equal(shouldDeleteBranch({
    name: 'wt/feature',
    goneOnRemote: true,
    hasWorktree: true,
  }), false);
});

test('shouldDeleteBranch: wt/* branch present on remote -> keep', () => {
  assert.equal(shouldDeleteBranch({
    name: 'wt/feature',
    goneOnRemote: false,
    hasWorktree: false,
  }), false);
});

test('shouldDeleteBranch: out-of-scope branch (develop) -> never deleted even if gone', () => {
  assert.equal(shouldDeleteBranch({
    name: 'develop',
    goneOnRemote: true,
    hasWorktree: false,
  }), false);
});

test('shouldDeleteBranch: out-of-scope feature branch -> never deleted', () => {
  assert.equal(shouldDeleteBranch({
    name: 'build/prt-footer',
    goneOnRemote: true,
    hasWorktree: false,
  }), false);
});
