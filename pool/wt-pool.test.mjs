import { test } from 'node:test';
import assert from 'node:assert/strict';
import { claim, commandOwnsLane, isClaimable, isPoolSlot, legacyOwnerOwnsLane, liveLockedOwnerPid, reclaimDead, reapLane, release, releaseByPath, sweep, slotName, DEFAULT_TTL_MS } from '../wt-pool.mjs';

/**
 * Mock deps backed by in-memory maps so claim/sweep are exercised with NO real
 * fs / git / processes.
 *   locks:  { [name]: bodyString }   existing lockfiles
 *   dirty:  { [name]: count }        uncommitted-change counts
 *   exists: Set<string>             worktrees present on disk
 *   dead:   Set<number>             pids whose owner process is gone (isAlive=false)
 */
function mockDeps(state = {}) {
  const locks = new Map(Object.entries(state.locks || {}));
  const dirty = state.dirty || {};
  const exists = state.exists || new Set();
  const dead = state.dead || new Set();
  const ownerFingerprints = state.ownerFingerprints || {};
  const reaped = [];        // lanes whose child processes were killed
  const cellCleared = [];   // lanes whose .cell-state lock was removed
  return {
    _locks: locks,
    _reaped: reaped,
    _cellCleared: cellCleared,
    claimLock(name, body) {
      if (locks.has(name)) { const e = new Error('EEXIST'); e.code = 'EEXIST'; throw e; }
      locks.set(name, body);
    },
    readLock(name) { return locks.has(name) ? locks.get(name) : null; },
    releaseLock(name) { locks.delete(name); },
    wtExists(name) { return exists.has(name); },
    dirtyCount(name) { return dirty[name] || 0; },
    ownerFingerprint(pid) { return ownerFingerprints[pid] || null; },
    isAlive(pid) { return !pid || !dead.has(pid); },
    killLaneProcesses(name) { reaped.push(name); return 0; },
    releaseCellLock(name) { cellCleared.push(name); },
    log() {},
  };
}

test('claims the first free slot and stamps the lock', () => {
  const deps = mockDeps();
  const got = claim({ deps, size: 4, sessionId: 's1', now: 1000 });
  assert.equal(got, slotName(1));
  assert.equal(JSON.parse(deps._locks.get(slotName(1))).sessionId, 's1');
});

test('claim stamps the owner pid into the lock', () => {
  const deps = mockDeps();
  claim({ deps, size: 4, sessionId: 's1', pid: 4242, now: 1000 });
  assert.equal(JSON.parse(deps._locks.get(slotName(1))).pid, 4242);
});

test('claim stamps the owner process fingerprint when available', () => {
  const deps = mockDeps({ ownerFingerprints: { 4242: '20260719230102.123456-000' } });
  claim({ deps, size: 4, sessionId: 's1', pid: 4242, now: 1000 });
  assert.equal(JSON.parse(deps._locks.get(slotName(1))).ownerFingerprint, '20260719230102.123456-000');
});

test('reclaimDead frees a clean slot whose owner process is gone', () => {
  const deps = mockDeps({ locks: { 'claude-1': JSON.stringify({ pid: 999, ts: 0 }) }, dead: new Set([999]) });
  const freed = reclaimDead({ deps, size: 4 });
  assert.deepEqual(freed, ['claude-1']);
  assert.equal(deps._locks.has('claude-1'), false);
});

test('reclaimDead REAPS a dead-owner lane (kills orphans + clears cell lock)', () => {
  const deps = mockDeps({ locks: { 'x-codex-3': JSON.stringify({ pid: 999, ts: 0 }) }, dead: new Set([999]) });
  reclaimDead({ deps, size: 4, prefix: 'x-codex' });
  assert.deepEqual(deps._reaped, ['x-codex-3']);       // child process tree killed
  assert.deepEqual(deps._cellCleared, ['x-codex-3']);  // stale .cell-state lock removed
});

test('reclaimDead keeps a slot whose owner is alive', () => {
  const deps = mockDeps({ locks: { 'claude-1': JSON.stringify({ pid: 1234, ts: 0 }) } });
  assert.deepEqual(reclaimDead({ deps, size: 4 }), []);
  assert.equal(deps._locks.has('claude-1'), true);
  assert.deepEqual(deps._reaped, []);       // NEVER reap a live lane
  assert.deepEqual(deps._cellCleared, []);
});

test('reclaimDead passes slot name to liveness probe so PID reuse can be rejected', () => {
  const deps = mockDeps({ locks: { 'x-codex-7': JSON.stringify({ pid: 30244, ts: 0, ownerFingerprint: 'old-start' }) } });
  const seen = [];
  deps.isAlive = (pid, name, ownerFingerprint) => {
    seen.push({ pid, name, ownerFingerprint });
    return false; // e.g. PID exists but belongs to an unrelated Windows process.
  };
  assert.deepEqual(reclaimDead({ deps, size: 8, prefix: 'x-codex' }), ['x-codex-7']);
  assert.deepEqual(seen, [{ pid: 30244, name: 'x-codex-7', ownerFingerprint: 'old-start' }]);
  assert.equal(deps._locks.has('x-codex-7'), false);
});

test('liveLockedOwnerPid uses the exact slot name for drift-sweep live checks', () => {
  const deps = mockDeps({ locks: { 'x-codex-8': JSON.stringify({ pid: 33568, ts: 0, ownerFingerprint: 'codex8-start' }) } });
  const seen = [];
  deps.isAlive = (pid, name, ownerFingerprint) => {
    seen.push({ pid, name, ownerFingerprint });
    return name === 'x-codex-8' && ownerFingerprint === 'codex8-start';
  };
  assert.equal(liveLockedOwnerPid(deps, 'x-codex-8'), 33568);
  assert.deepEqual(seen, [{ pid: 33568, name: 'x-codex-8', ownerFingerprint: 'codex8-start' }]);
});

test('reclaimDead reclaims same-engine PID reuse when owner fingerprint changed', () => {
  const deps = mockDeps({ locks: { 'x-codex-7': JSON.stringify({ pid: 33568, ts: 0, ownerFingerprint: 'old-codex7-start' }) } });
  deps.isAlive = (_pid, _name, ownerFingerprint) => ownerFingerprint === 'new-codex8-start';
  assert.deepEqual(reclaimDead({ deps, size: 8, prefix: 'x-codex' }), ['x-codex-7']);
  assert.equal(deps._locks.has('x-codex-7'), false);
});

test('commandOwnsLane rejects same-engine launcher for a different lane', () => {
  const cmd = '"C:/Users/Dave/AppData/Local/Programs/OpenAI/Codex/bin/codex.exe" --cd C:/Dev/regen-root.wt/x-codex-8 --dangerously-bypass-hook-trust';
  assert.equal(commandOwnsLane(cmd, 'x-codex-7'), false);
  assert.equal(commandOwnsLane(cmd, 'x-codex-8'), true);
});

test('legacyOwnerOwnsLane uses launcher descendants for pre-fingerprint locks', () => {
  const owner = 'pwsh.exe -NoLogo -File "C:/Dev/regen-root/scripts/codex-worktree-launch.ps1"';
  const child = '"C:/Users/Dave/AppData/Local/Programs/OpenAI/Codex/bin/codex.exe" --cd C:/Dev/regen-root.wt/x-codex-7';
  assert.equal(legacyOwnerOwnsLane(owner, [child], 'x-codex-7'), true);
  assert.equal(legacyOwnerOwnsLane(owner, [child], 'x-codex-8'), false);
  assert.equal(legacyOwnerOwnsLane('"C:/Program Files/Google/Chrome/Application/chrome.exe"', [child], 'x-codex-7'), false);
});

test('legacyOwnerOwnsLane preserves pre-fingerprint Claude wrappers without lane-path children', () => {
  const owner = 'pwsh.exe -NoLogo -File "C:/Dev/regen-root/scripts/claude-iso.ps1"';
  const child = 'C:/Windows/system32/cmd.exe /c "C:/Users/Dave/AppData/Roaming/npm/claude.cmd"';
  assert.equal(legacyOwnerOwnsLane(owner, [child], 'claude-7'), true);
});

test('release and reapLane kill orphans + clear the cell lock for the lane', () => {
  const rel = mockDeps({ locks: { 'x-codex-2': '{}' } });
  release('x-codex-2', rel);
  assert.equal(rel._locks.has('x-codex-2'), false);
  assert.deepEqual(rel._reaped, ['x-codex-2']);
  assert.deepEqual(rel._cellCleared, ['x-codex-2']);

  const direct = mockDeps();
  reapLane('claude-5', direct);
  assert.deepEqual(direct._reaped, ['claude-5']);
  assert.deepEqual(direct._cellCleared, ['claude-5']);
});

test('reclaimDead preserves a dirty slot even if its owner is gone', () => {
  const deps = mockDeps({
    locks: { 'claude-1': JSON.stringify({ pid: 999, ts: 0 }) },
    exists: new Set(['claude-1']), dirty: { 'claude-1': 2 }, dead: new Set([999]),
  });
  assert.deepEqual(reclaimDead({ deps, size: 4 }), []);
  assert.equal(deps._locks.has('claude-1'), true);
});

test('reclaimDead skips legacy pid-less locks (left to the TTL sweep)', () => {
  const deps = mockDeps({ locks: { 'claude-1': JSON.stringify({ ts: 0 }) }, dead: new Set([0]) });
  assert.deepEqual(reclaimDead({ deps, size: 4 }), []);
  assert.equal(deps._locks.has('claude-1'), true);
});

test('claim self-heals: a pool full of dead owners is reclaimed, not reported busy', () => {
  const deps = mockDeps({
    locks: {
      'claude-1': JSON.stringify({ pid: 901, ts: 0 }),
      'claude-2': JSON.stringify({ pid: 902, ts: 0 }),
    },
    dead: new Set([901, 902]),
  });
  const got = claim({ deps, size: 2, sessionId: 's-new', pid: 5000, now: 2000 });
  assert.equal(got, slotName(1)); // reclaimed slot 1 instead of returning null
  assert.equal(JSON.parse(deps._locks.get(slotName(1))).pid, 5000);
});

test('claim(exclude) skips a caller-rejected slot and takes the next free one', () => {
  // The CLI passes a `poisoned` set of slots whose unlanded commits will not rebase.
  // claim() must skip them and hand out the next free slot — one bad slot can't strand a launch.
  const deps = mockDeps();
  const got = claim({ deps, size: 4, sessionId: 's', now: 1, exclude: new Set(['claude-1']) });
  assert.equal(got, slotName(2));                     // claude-1 excluded → next free
  assert.equal(deps._locks.has(slotName(1)), false);  // excluded slot is never locked/touched
});

test('claim(exclude) returns null when every free slot is excluded (whole pool poisoned)', () => {
  const deps = mockDeps();
  const got = claim({ deps, size: 2, sessionId: 's', now: 1, exclude: new Set(['claude-1', 'claude-2']) });
  assert.equal(got, null); // caller then surfaces the stale-and-unrebasable cleanup signal, never boots un-isolated
});

test('never double-claims: a locked slot is skipped', () => {
  const deps = mockDeps({ locks: { 'claude-1': JSON.stringify({ sessionId: 'other', ts: 1000 }) } });
  const got = claim({ deps, size: 4, sessionId: 's2', now: 1000 });
  assert.equal(got, slotName(2));
});

test('preserve-dirty: never hands out a slot holding uncommitted work', () => {
  const deps = mockDeps({ exists: new Set(['claude-1']), dirty: { 'claude-1': 3 } });
  assert.equal(isClaimable(deps, 'claude-1'), false);
  const got = claim({ deps, size: 4, sessionId: 's4', now: 1000 });
  assert.equal(got, slotName(2)); // dirty slot 1 skipped even though unlocked
});

test('returns null when the whole pool is busy', () => {
  const deps = mockDeps({ locks: { 'claude-1': '{}', 'claude-2': '{}' } });
  assert.equal(claim({ deps, size: 2, sessionId: 's5', now: 1000 }), null);
});

test('release frees a slot', () => {
  const deps = mockDeps({ locks: { 'claude-2': '{}' } });
  release('claude-2', deps);
  assert.equal(deps._locks.has('claude-2'), false);
});

test('releaseByPath maps a worktree path back to its slot', () => {
  const deps = mockDeps({ locks: { 'claude-3': '{}' } });
  const freed = releaseByPath('C:/Dev/regen-root.wt/claude-3', deps);
  assert.equal(freed, 'claude-3');
  assert.equal(deps._locks.has('claude-3'), false);
  // non-pool path is ignored
  assert.equal(releaseByPath('C:/Dev/regen-root.wt/cell-portal', deps), null);
});

test('sweep frees only clean locks older than the TTL', () => {
  const now = 100 * DEFAULT_TTL_MS;
  const deps = mockDeps({
    locks: {
      'claude-1': JSON.stringify({ ts: now - DEFAULT_TTL_MS - 1 }), // old + clean → free
      'claude-2': JSON.stringify({ ts: now - 1000 }),               // recent → keep
      'claude-3': JSON.stringify({ ts: now - DEFAULT_TTL_MS - 1 }), // old BUT dirty → keep
    },
    exists: new Set(['claude-3']),
    dirty: { 'claude-3': 2 },
  });
  const freed = sweep({ deps, size: 4, now });
  assert.deepEqual(freed, ['claude-1']);
  assert.equal(deps._locks.has('claude-2'), true);  // recent kept (likely live)
  assert.equal(deps._locks.has('claude-3'), true);  // dirty preserved
});

test('sweep --force frees clean slots regardless of age, still preserves dirty', () => {
  const deps = mockDeps({
    locks: { 'claude-1': JSON.stringify({ ts: 0 }), 'claude-2': JSON.stringify({ ts: 0 }) },
    exists: new Set(['claude-2']),
    dirty: { 'claude-2': 1 },
  });
  const freed = sweep({ deps, size: 4, now: 0, force: true });
  assert.deepEqual(freed, ['claude-1']);            // clean freed
  assert.equal(deps._locks.has('claude-2'), true);  // dirty still preserved
});

// ── prefix parameterization (the codex/claude pool unification) ──────────────

test('slotName / isPoolSlot honor the prefix (claude default, x-codex opt-in)', () => {
  assert.equal(slotName(1), 'claude-1');
  assert.equal(slotName(2, 'x-codex'), 'x-codex-2');
  assert.equal(isPoolSlot('claude-3'), true);
  assert.equal(isPoolSlot('x-codex-7'), true);
  assert.equal(isPoolSlot('cell-data'), false);
});

test('claim with prefix x-codex claims x-codex-N (one engine, two prefixes)', () => {
  const deps = mockDeps();
  const got = claim({ deps, size: 12, sessionId: 'codex-1', pid: 7, now: 1, prefix: 'x-codex' });
  assert.equal(got, 'x-codex-1');
  assert.equal(JSON.parse(deps._locks.get('x-codex-1')).pid, 7);
});

test('x-codex pool is independent of the claude pool (no cross-claim)', () => {
  // A full claude pool does NOT block an x-codex claim — separate slot namespaces.
  const deps = mockDeps({ locks: { 'claude-1': '{}', 'claude-2': '{}' } });
  assert.equal(claim({ deps, size: 2, prefix: 'claude', now: 1 }), null);        // claude full
  assert.equal(claim({ deps, size: 2, prefix: 'x-codex', now: 1 }), 'x-codex-1'); // x-codex free
});

test('elastic pool: claim with a higher ceiling grows past busy warm slots', () => {
  // The CLI passes a ceiling >= warm size; claim() takes the first free slot, so a
  // full warm pool (claude-1..2) grows to a new higher slot instead of returning null.
  const deps = mockDeps({ locks: { 'claude-1': '{}', 'claude-2': '{}' } });
  assert.equal(claim({ deps, size: 2, now: 1 }), null);          // warm-only would block
  assert.equal(claim({ deps, size: 16, now: 1 }), 'claude-3');   // elastic ceiling grows it
});

test('reclaimDead / releaseByPath / sweep work for x-codex slots', () => {
  const deps = mockDeps({ locks: { 'x-codex-1': JSON.stringify({ pid: 999, ts: 0 }) }, dead: new Set([999]) });
  assert.deepEqual(reclaimDead({ deps, size: 4, prefix: 'x-codex' }), ['x-codex-1']);

  const deps2 = mockDeps({ locks: { 'x-codex-3': '{}' } });
  assert.equal(releaseByPath('C:/Dev/regen-root.wt/x-codex-3', deps2), 'x-codex-3');
  assert.equal(deps2._locks.has('x-codex-3'), false);

  const now = 100 * DEFAULT_TTL_MS;
  const deps3 = mockDeps({ locks: { 'x-codex-1': JSON.stringify({ ts: now - DEFAULT_TTL_MS - 1 }) } });
  assert.deepEqual(sweep({ deps: deps3, size: 4, now, prefix: 'x-codex' }), ['x-codex-1']);
});
