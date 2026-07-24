#!/usr/bin/env node
/**
 * wt-pool.mjs — warm worktree pool for Claude sessions.
 *
 * Approved: option-1 warm-pool naming + sv-on-main + WorktreeRemove-release.
 * Interview: 2026-06-27.
 *
 * Goal: every (non-supervisor) Claude session runs ISOLATED, but starts INSTANT.
 * A fresh worktree pays an ~85s pnpm link pass; re-attaching a warm one is
 * instant (node_modules already linked). So we keep a POOL of persistent
 * worktrees (claude-1..claude-N); a session claims a FREE slot and re-attaches.
 *
 * Invariants:
 *   1. NO double-claim — slots are claimed by ATOMIC exclusive lockfile create
 *      ('wx'); two simultaneous launches can never win the same slot.
 *   2. NEVER hand out / wipe uncommitted work — a dirty slot is skipped at
 *      selection even if unlocked (preserve-dirty, .claude/rules/session-cleanup.md).
 *
 * Release lifecycle:
 *   - PRIMARY: the WorktreeRemove hook calls releaseByPath() at session exit.
 *   - CRASH SAFETY: sweep() frees a slot ONLY if its lock is clean AND older than
 *     a TTL (default 12h) — long past any real session, so it never steals a
 *     live slot. (A blanket "free all clean slots" sweep is unsafe: it cannot
 *     distinguish a leaked-clean slot from a live session holding it clean.)
 *   - If the whole pool is busy, claim() returns null and the caller falls back
 *     to a unique worktree name (always works, just pays the install once).
 *
 * Pure given deps (injectable) so selection/sweep are unit-tested with no real
 * fs / git. The module NEVER calls Date.now() — callers pass `now`/`ts`.
 */
import { openSync, closeSync, writeSync, readFileSync, writeFileSync, unlinkSync, existsSync, mkdirSync } from 'node:fs';
import { execFileSync as _execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Windows: force CREATE_NO_WINDOW on EVERY child. When this module runs from a
// console-less parent (e.g. a detached session-boundary hook), a console app like
// git.exe/powershell.exe otherwise gets a fresh visible console window per call —
// that was the "25 flashing windows" drift-sweep bug. Redirected stdio does NOT
// suppress it; only windowsHide (CREATE_NO_WINDOW) does. Callers' opts spread last,
// so an explicit windowsHide:false could still opt out (none do). Applies to every
// execFileSync call site below through this single wrapper.
const execFileSync = (file, args, opts = {}) => _execFileSync(file, args, { windowsHide: true, ...opts });

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = process.env.PROJECT_ROOT || path.resolve(__dirname, '..');
export const WT_ROOT = (REPO_ROOT + '.wt').split(path.sep).join('/');
export const POOL_DIR = path.join(REPO_ROOT, '.wt-pool');
export const DEFAULT_POOL_SIZE = Number(process.env.CLAUDE_WT_POOL_SIZE) || 8;
export const CELL_STATE_DIR = path.join(REPO_ROOT, '.cell-state');
export const DEFAULT_TTL_MS = 12 * 60 * 60 * 1000; // 12h
const GIT_ENV = { ...process.env, MSYS_NO_PATHCONV: '1' };

// Slots are <prefix>-<n>. prefix defaults to 'claude' (back-compat); Codex passes
// 'x-codex'. One pool engine, two prefixes — no second implementation.
export function slotName(i, prefix = 'claude') { return `${prefix}-${i}`; }
export function isPoolSlot(name) { return /^(claude|x-codex)-\d+$/.test(name); }
export const BASE_REMOTE = 'origin';
export const BASE_BRANCH = 'develop';
export function wtDirFor(name) { return `${WT_ROOT}/${name}`; }
function lockPathFor(name) { return path.join(POOL_DIR, `${name}.lock`); }

export function commandOwnsLane(commandLine, name) {
  const lower = String(commandLine || '').toLowerCase();
  const escaped = String(name).toLowerCase().replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(`regen-root\\.wt[\\\\/]${escaped}(?:[\\\\/\\s\"']|$)`).test(lower);
}

export function commandIsPoolLauncher(commandLine) {
  const lower = String(commandLine || '').toLowerCase();
  return lower.includes('codex-worktree-launch.ps1') || lower.includes('claude-iso.ps1');
}

export function poolLauncherKind(commandLine) {
  const lower = String(commandLine || '').toLowerCase();
  if (lower.includes('codex-worktree-launch.ps1')) return 'codex';
  if (lower.includes('claude-iso.ps1')) return 'claude';
  return null;
}

export function legacyOwnerOwnsLane(commandLine, descendantCommandLines, name) {
  if (commandOwnsLane(commandLine, name)) return true;
  const launcherKind = poolLauncherKind(commandLine);
  if (!launcherKind) return false;
  if (descendantCommandLines.some((cmd) => commandOwnsLane(cmd, name))) return true;
  // Legacy Claude locks predate owner fingerprints and the `claude.cmd` child
  // does not carry a `--cd` lane path. Keep those alive until the session exits;
  // newly claimed locks use fingerprints and do not rely on this fallback.
  return launcherKind === 'claude';
}

/** Real, injectable effects. Tests pass a mock with the same shape. */
export function defaultDeps() {
  return {
    claimLock(name, body) {
      mkdirSync(POOL_DIR, { recursive: true });
      const fd = openSync(lockPathFor(name), 'wx'); // exclusive create
      try { writeSync(fd, body); } finally { closeSync(fd); }
    },
    readLock(name) {
      try { return readFileSync(lockPathFor(name), 'utf8'); } catch { return null; }
    },
    releaseLock(name) {
      try { unlinkSync(lockPathFor(name)); } catch { /* already gone */ }
    },
    wtExists(name) { return existsSync(wtDirFor(name)); },
    dirtyCount(name) {
      try {
        const out = execFileSync('git', ['status', '--porcelain'],
          { cwd: wtDirFor(name), encoding: 'utf8', env: GIT_ENV, stdio: ['ignore', 'pipe', 'pipe'] });
        return out.trim() ? out.trim().split('\n').length : 0;
      } catch { return 0; }
    },
    ownerFingerprint(pid) {
      if (!pid || process.platform !== 'win32') return null;
      try {
          const out = execFileSync('powershell', [
            '-NoProfile',
            '-Command',
            `Get-CimInstance Win32_Process -Filter "ProcessId = ${Number(pid)}" | ` +
            `ForEach-Object { $_.CreationDate.ToUniversalTime().Ticks } | Select-Object -First 1`,
        ], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], env: GIT_ENV }).trim();
        return out || null;
      } catch {
        return null;
      }
    },
    descendantCommandLines(pid) {
      if (!pid || process.platform !== 'win32') return [];
      const ps =
        `$root=${Number(pid)}; ` +
        `$all=Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,CommandLine; ` +
        `$front=@($root); $seen=@{}; $out=@(); ` +
        `while($front.Count -gt 0){ ` +
          `$next=@(); ` +
          `foreach($p in $front){ ` +
            `$children=$all | Where-Object { $_.ParentProcessId -eq $p }; ` +
            `foreach($c in $children){ ` +
              `if(-not $seen.ContainsKey([string]$c.ProcessId)){ ` +
                `$seen[[string]$c.ProcessId]=$true; $out += $c.CommandLine; $next += $c.ProcessId ` +
              `} ` +
            `} ` +
          `} ` +
          `$front=$next ` +
        `}; ` +
        `$out | ConvertTo-Json -Compress`;
      try {
        const raw = execFileSync('powershell', ['-NoProfile', '-Command', ps],
          { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], env: GIT_ENV }).trim();
        if (!raw) return [];
        const parsed = JSON.parse(raw);
        return Array.isArray(parsed) ? parsed.filter(Boolean) : [parsed].filter(Boolean);
      } catch {
        return [];
      }
    },
    // Liveness probe: is the exact owner process still running? `kill(pid, 0)`
    // alone is unsafe on long-lived Windows machines because PIDs are reused; a
    // stale x-codex-7 lock once pointed at an unrelated chrome.exe, so the pool
    // skipped reusable lanes and grew to x-codex-10. New locks stamp the process
    // creation fingerprint, so a reused PID is reclaimable even when another
    // same-family launcher later gets that PID. pid 0/unknown → assume alive for
    // legacy safety.
    isAlive(pid, name = '', expectedFingerprint = null) {
      if (!pid) return true;
      if (process.platform === 'win32') {
        try {
          const out = execFileSync('powershell', [
            '-NoProfile',
            '-Command',
            `Get-CimInstance Win32_Process -Filter "ProcessId = ${Number(pid)}" | ` +
              `ForEach-Object { [pscustomobject]@{ ProcessId = $_.ProcessId; CreationTicks = "$($_.CreationDate.ToUniversalTime().Ticks)"; CommandLine = $_.CommandLine } } | ` +
              `Select-Object -First 1 | ConvertTo-Json -Compress`,
          ], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], env: GIT_ENV }).trim();
          if (!out) return false;
          const proc = JSON.parse(out);
          if (expectedFingerprint) return String(proc.CreationTicks || '') === String(expectedFingerprint);
          return legacyOwnerOwnsLane(proc.CommandLine, this.descendantCommandLines(pid), name);
        } catch {
          return false;
        }
      }
      try { process.kill(pid, 0); return true; }
      catch (e) { return e.code === 'EPERM'; }
    },
    // Reaper — kill any process whose command line runs UNDER this lane's worktree
    // path (orphaned dev servers a session left backgrounded). Matched by the path
    // token WITH a trailing separator so 'x-codex-2' can't match 'x-codex-20', and
    // the reaper's own `wt-pool release <name>` argv (bare name, no trailing sep) is
    // excluded — as is our own PID. Windows-only kill; no-op elsewhere. Fail-open.
    killLaneProcesses(name) {
      if (process.platform !== 'win32') return 0;
      const self = process.pid;
      const tokBack = `regen-root.wt\\${name}\\`;
      const tokFwd = `regen-root.wt/${name}/`;
      const ps =
        `$self=${self}; Get-CimInstance Win32_Process | Where-Object { ` +
        `$_.ProcessId -ne $self -and $_.CommandLine -and ` +
        `($_.CommandLine -like '*${tokBack}*' -or $_.CommandLine -like '*${tokFwd}*') } | ` +
        `ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue } catch {}; $_.ProcessId }`;
      try {
        const out = execFileSync('powershell', ['-NoProfile', '-Command', ps],
          { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], env: GIT_ENV });
        return out.trim() ? out.trim().split(/\r?\n/).length : 0;
      } catch { return 0; }
    },
    // Clear the legacy per-lane lease that cleanup-agent-jobs.ps1 still consults.
    releaseCellLock(name) {
      try { unlinkSync(path.join(CELL_STATE_DIR, `${name}.lock`)); } catch { /* already gone */ }
    },
    log: (s) => process.stderr.write(s.endsWith('\n') ? s : s + '\n'),
  };
}

/**
 * Reap a lane whose owning session is gone: kill its orphaned child processes
 * (backgrounded dev servers that survive Ctrl+D) and clear its stale .cell-state
 * lock. Called from release() (clean exit via launcher `finally` / WorktreeRemove
 * hook) and from reclaimDead() (dead-owner lanes — catches hard window-closes the
 * exit hook never sees). Fail-open: a mock deps without the reaper hooks no-ops.
 */
export function reapLane(name, deps = defaultDeps()) {
  const killed = deps.killLaneProcesses ? deps.killLaneProcesses(name) : 0;
  if (deps.releaseCellLock) deps.releaseCellLock(name);
  if (killed) deps.log(`wt-pool: reaped ${killed} orphaned process(es) under ${name}`);
  return killed;
}

/** Free to claim? Not holding dirty work, AND no lock present. */
export function isClaimable(deps, name) {
  if (deps.wtExists(name) && deps.dirtyCount(name) > 0) return false; // unrecovered work
  return deps.readLock(name) == null;                                  // free iff unlocked
}

/**
 * Reclaim leaked slots: free any CLEAN slot whose owner process is gone. This is
 * the fast path that a hard-closed terminal window (which skips the WorktreeRemove
 * release hook) would otherwise leave LOCKED until the 12h TTL sweep. Unlike
 * sweep(), it is age-independent — a dead owner is dead regardless of lock age, so
 * it never steals a live session's slot (that owner's process answers kill(pid,0)).
 *
 * Safety: never frees a dirty slot (preserve-dirty); only frees when the lock
 * records a pid AND that pid is provably gone. Legacy pid-less locks are skipped
 * here and left to the TTL sweep — so this change is backward-compatible.
 */
export function reclaimDead({ deps = defaultDeps(), size = DEFAULT_POOL_SIZE, prefix = 'claude' } = {}) {
  const released = [];
  for (let i = 1; i <= size; i++) {
    const name = slotName(i, prefix);
    const raw = deps.readLock(name);
    if (raw == null) continue;                                      // already free
    if (deps.wtExists(name) && deps.dirtyCount(name) > 0) continue; // preserve dirty
    let pid = 0;
    let ownerFingerprint = null;
    try {
      const lock = JSON.parse(raw);
      pid = lock.pid || 0;
      ownerFingerprint = lock.ownerFingerprint || null;
    } catch { continue; }     // corrupt → leave to TTL
    if (pid > 0 && !deps.isAlive(pid, name, ownerFingerprint)) { reapLane(name, deps); deps.releaseLock(name); released.push(name); }
  }
  return released;
}

/**
 * Claim the first free pool slot. Returns its name, or null if the pool is busy.
 * Callers MUST pass `now` (ms) — the module never reads the clock itself.
 * `pid` is the OWNING session process (the launcher), stamped into the lock so a
 * later claim can reclaim the slot if that process dies without releasing.
 * `exclude` (optional Set of slot names) lets a caller skip slots it has already
 * rejected this run — e.g. a slot whose unlanded commits will not rebase onto
 * origin/develop. Such a slot stays UNTOUCHED (its commits are preserved); the
 * caller just won't be handed it again, so one poisoned slot can't strand a claim.
 */
export function claim({ deps = defaultDeps(), size = DEFAULT_POOL_SIZE, sessionId = '', pid = 0, now = 0, prefix = 'claude', exclude = null } = {}) {
  reclaimDead({ deps, size, prefix }); // self-heal leaked slots before deciding the pool is busy
  for (let i = 1; i <= size; i++) {
    const name = slotName(i, prefix);
    if (exclude && exclude.has(name)) continue; // caller already rejected this slot (e.g. unlanded work won't rebase)
    if (!isClaimable(deps, name)) continue;
    try {
      const ownerFingerprint = deps.ownerFingerprint ? deps.ownerFingerprint(pid) : null;
      deps.claimLock(name, JSON.stringify({ sessionId, pid, ts: now, slot: name, ownerFingerprint }));
      return name;
    } catch {
      continue; // lost the atomic race for this slot → next
    }
  }
  return null; // exhausted → caller falls back to a unique name
}

export function release(name, deps = defaultDeps()) { reapLane(name, deps); deps.releaseLock(name); }

/** Release the slot owning a given worktree path (WorktreeRemove hook). */
export function releaseByPath(worktreePath, deps = defaultDeps()) {
  const base = String(worktreePath || '').split(/[\\/]/).filter(Boolean).pop() || '';
  if (isPoolSlot(base)) { reapLane(base, deps); deps.releaseLock(base); return base; }
  return null;
}

/** Return the live owner PID for that exact lane, or 0 when absent/stale. */
export function liveLockedOwnerPid(deps, name) {
  const raw = deps.readLock(name);
  let livePid = 0;
  let ownerFingerprint = null;
  try {
    const lock = raw ? JSON.parse(raw) : {};
    livePid = lock.pid || 0;
    ownerFingerprint = lock.ownerFingerprint || null;
  } catch { livePid = 0; }
  return livePid > 0 && deps.isAlive(livePid, name, ownerFingerprint) ? livePid : 0;
}

/** True iff a slot lock records a live owner for that exact lane. */
export function lockedOwnerIsLive(deps, name) {
  return liveLockedOwnerPid(deps, name) > 0;
}

/**
 * Crash-safety sweep: free slots whose lock is CLEAN and OLDER than ttlMs.
 * Never frees a dirty slot; never frees a recently-locked (likely-live) slot.
 */
export function sweep({ deps = defaultDeps(), size = DEFAULT_POOL_SIZE, now = 0, ttlMs = DEFAULT_TTL_MS, force = false, prefix = 'claude' } = {}) {
  const released = [];
  for (let i = 1; i <= size; i++) {
    const name = slotName(i, prefix);
    const raw = deps.readLock(name);
    if (raw == null) continue;                                   // already free
    if (deps.wtExists(name) && deps.dirtyCount(name) > 0) continue; // preserve dirty
    let ts = 0;
    try { ts = JSON.parse(raw).ts || 0; } catch { /* corrupt → treat as old */ }
    if (force || now - ts >= ttlMs) { deps.releaseLock(name); released.push(name); }
  }
  return released;
}

// --- Shared post-claim recovery (active-repair) — applied to EVERY claimed slot,
// claude-N and x-codex-N alike, so neither engine drifts. cmdAdd bases a FRESH slot
// off origin/develop and installs; these helpers cover the RE-ATTACH path (a warm
// slot that has gone stale or lost deps since it was last used).
function gitOut(dir, args) {
  try { return execFileSync('git', args, { cwd: dir, encoding: 'utf8', env: GIT_ENV, stdio: ['ignore', 'pipe', 'pipe'] }).trim(); }
  catch { return null; }
}
/** True iff a rebase is mid-flight in `dir` (wedged by a prior crashed sync). */
function rebaseInProgress(dir) {
  for (const p of ['rebase-merge', 'rebase-apply']) {
    const gp = gitOut(dir, ['rev-parse', '--git-path', p]);
    if (gp && existsSync(path.isAbsolute(gp) ? gp : path.join(dir, gp))) return true;
  }
  return false;
}

/**
 * THE ONE lane-sync primitive. Bring a worktree current with a freshly-fetched
 * origin/develop WITHOUT ever destroying committed OR uncommitted work. This is the
 * only sanctioned sync path — `git reset --hard` is intentionally ABSENT: it silently
 * ate real unlanded work (2026-07-05: claude-8 rdc-website feature, x-codex-1 codeflow
 * fix) because isClaimable() screens only DIRTY slots, not committed-but-unlanded ones.
 *
 * Behavior (all via a single `git rebase --autostash origin/develop`):
 *   behind-only clean -> fast-forward             ahead>0 -> REPLAY the commits (preserve)
 *   dirty             -> autostash then restore    conflict -> abort + throw (surface, never discard)
 * Target is the REMOTE ref origin/develop, never the local `develop` branch (a live
 * shared checkout in the SV/main tree that may itself be diverged and is un-fast-
 * forwardable from a linked worktree). Shared by the pool re-attach path (ensureFresh)
 * and the startup guard (agent-startup-guard.ps1 shells to the `sync-lane` subcommand).
 */
export function syncLaneToOriginDevelop(dir, log = () => {}) {
  // A crashed prior sync can leave a half-applied rebase that wedges every future
  // rebase ("another rebase is in progress"). Clear it first — an aborted rebase in a
  // scratch lane restores the pre-rebase state, losing nothing (autostash is also
  // restored by --abort). (review Q5: never let a wedged lane stay wedged.)
  if (rebaseInProgress(dir)) {
    log(`wt-pool: ${dir} -> aborting a wedged in-progress rebase before sync`);
    try { execFileSync('git', ['rebase', '--abort'], { cwd: dir, env: GIT_ENV, stdio: 'ignore' }); } catch { /* best effort */ }
  }
  // Assert the fetch succeeded: gitOut returns '' on quiet success, null only on throw.
  // A swallowed fetch failure would leave `base` resolving to a STALE local ref — FATAL,
  // not fail-open: a lane that cannot be proven fresh must NOT be handed out (lesson
  // 2026-07-05-fixit-warm-lane-boots-stale).
  if (gitOut(dir, ['fetch', BASE_REMOTE, BASE_BRANCH]) === null) {
    throw new Error(`sync-lane: fetch ${BASE_REMOTE}/${BASE_BRANCH} failed in ${dir}`);
  }
  const base = gitOut(dir, ['rev-parse', `${BASE_REMOTE}/${BASE_BRANCH}`]);
  if (!base) throw new Error(`sync-lane: cannot resolve ${BASE_REMOTE}/${BASE_BRANCH} (fetch failed?) in ${dir}`);
  const head = gitOut(dir, ['rev-parse', 'HEAD']);
  const dirty = (gitOut(dir, ['status', '--porcelain']) ?? '') !== '';
  if (head === base && !dirty) return; // already current and clean — nothing to do
  const aheadRaw = gitOut(dir, ['rev-list', '--count', `${BASE_REMOTE}/${BASE_BRANCH}..HEAD`]);
  const ahead = Number.parseInt(aheadRaw ?? '', 10);
  log(`wt-pool: ${dir} -> rebase --autostash onto ${BASE_REMOTE}/${BASE_BRANCH}` +
      `${Number.isFinite(ahead) && ahead > 0 ? ` (preserve ${ahead} unlanded commit(s))` : ''}${dirty ? ' (autostash dirty tree)' : ''}`);
  try {
    // --autostash: stash uncommitted changes, rebase, restore — atomic + non-interactive.
    // On rebase failure git restores the autostash and leaves the branch untouched.
    execFileSync('git', ['rebase', '--autostash', `${BASE_REMOTE}/${BASE_BRANCH}`], { cwd: dir, env: GIT_ENV, stdio: ['ignore', 2, 2] });
  } catch (e) {
    if (rebaseInProgress(dir)) {
      try { execFileSync('git', ['rebase', '--abort'], { cwd: dir, env: GIT_ENV, stdio: 'ignore' }); } catch { /* best effort */ }
    }
    throw new Error(`sync-lane: ${dir} will not rebase onto ${BASE_REMOTE}/${BASE_BRANCH}` +
      `${Number.isFinite(ahead) && ahead > 0 ? ` — carries ${ahead} unlanded commit(s), land or resolve them in the lane (never reset)` : ''}: ${e?.message || e}`);
  }
}

// Pool re-attach recovery calls the shared primitive (was a destructive reset --hard).
function ensureFresh(dir, log) { return syncLaneToOriginDevelop(dir, log); }
function ensureDeps(dir, log) {
  const present = existsSync(path.join(dir, 'node_modules')) && existsSync(path.join(dir, 'packages', 'codeflow', 'node_modules'));
  if (present) return;
  log(`wt-pool: ${dir} deps incomplete — pnpm install --prefer-offline (recover)`);
  try {
    const pnpm = process.platform === 'win32' ? 'pnpm.cmd' : 'pnpm';
    execFileSync(pnpm, ['install', '--prefer-offline'], { cwd: dir, env: GIT_ENV, stdio: ['ignore', 2, 2], shell: process.platform === 'win32' });
  } catch (e) {
    log(`wt-pool: pnpm install failed in ${dir}: ${e?.message || e}`);
  }
}
function lockWorktree(dir, reason) {
  // git worktree lock so neither the Stop-hook GC nor git's auto-prune-on-add can
  // drop a warm lane's admin metadata. Already-locked is a harmless no-op.
  try { execFileSync('git', ['worktree', 'lock', '--reason', reason, dir], { cwd: REPO_ROOT, env: GIT_ENV, stdio: 'ignore' }); } catch { /* already locked */ }
}

// ---------------------------------------------------------------------------
// CLI — claim | release <name> | sweep [--force] | warm [n] | status.
// Flags: --prefix <claude|x-codex> (default claude), --lock, --size <n>.
// (now=Date.now() is fine here; only the pure functions above stay clock-free.)
// ---------------------------------------------------------------------------
const invokedDirectly = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  const argv = process.argv.slice(2);
  const sub = argv[0];
  const flagsWithValue = new Set(['--prefix', '--size']);
  const flagVal = (name) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : null; };
  const positional = [];
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) { if (flagsWithValue.has(a)) i++; continue; }
    positional.push(a);
  }
  const arg = positional[0];
  const prefix = flagVal('--prefix') || 'claude';
  const wantLock = argv.includes('--lock');
  const size = Number(flagVal('--size')) || DEFAULT_POOL_SIZE;
  const deps = defaultDeps();
  const now = Date.now();

  if (sub === 'claim') {
    // Claim a free pool slot, ensure its worktree exists/warm/fresh/installed, then
    // print ONLY the absolute worktree path to STDOUT. ALL progress goes to STDERR —
    // stdout is the path-only contract the launcher captures.
    const ownerPid = Number(process.env.CLAUDE_OWNER_PID) || process.ppid || 0;
    // ELASTIC pool. `size` is the WARM count (pre-created, instant reattach). claim()
    // scans 1..ceiling and takes the first free slot, so it prefers warm slots and
    // only reaches a higher (not-yet-created) index when every warm slot is busy --
    // at which point cmdAdd() below creates that new lane on demand. So a full warm
    // pool GROWS (claude-5, claude-6, ...) rather than blocking or falling back to the
    // main tree: every worker session is isolated, the supervisor owns the main tree.
    // The ceiling is only a runaway guard.
    const ceiling = Math.max(size, Number(process.env.WT_POOL_CEILING) || 16);
    const { cmdAdd } = await import('./wt.mjs');
    const wtDeps = defaultDepsForWtStderr();
    // A slot carrying committed-but-unlanded work that CONFLICTS with origin/develop
    // cannot be refreshed: ensureFresh throws (the sync aborts, never resets, so the
    // slot's commits are preserved). Such a "poisoned" slot must NOT strand the launch
    // while healthy slots sit free — the pre-2026-07-12 code exit(1)'d the whole startup
    // when claude-1 held 3 stale ssh-clauth commits, even though claude-2..8 were fresh.
    // Skip the poisoned slot (leaving its work untouched) and try the next free slot;
    // only give up when NO claimable slot can be made fresh.
    const poisoned = new Set();
    let dir = null;
    for (;;) {
      const slot = claim({ deps, size: ceiling, sessionId: process.env.CLAUDE_SESSION_ID || '', pid: ownerPid, now, prefix, exclude: poisoned });
      if (slot == null) {
        if (poisoned.size) {
          // Every free slot we could reach is stale-and-unrebasable — a cleanup signal,
          // NOT a reason to boot un-isolated on the main tree.
          process.stderr.write(`wt-pool: every free ${prefix} slot is stale-and-unrebasable (${[...poisoned].join(', ')}) — each carries unlanded commit(s) that conflict with ${BASE_REMOTE}/${BASE_BRANCH}.\n`);
          process.stderr.write(`wt-pool: land or resolve them (node scripts/wt-pool.mjs sync-lane <slot>), then relaunch.\n`);
          process.exit(1);
        }
        // Elastic ceiling full of LIVE sessions -- a true hard stop (rare). Still NO
        // un-isolated main-tree fallback (that half-baked sandbox is the very thing
        // isolation prevents). Close a session or raise WT_POOL_CEILING.
        process.stderr.write(`wt-pool: ${prefix} pool is FULL even at the ${ceiling}-slot ceiling - all held by live sessions.\n`);
        process.stderr.write(`wt-pool: isolated-or-SV only; close a ${prefix} session (or raise WT_POOL_CEILING) and relaunch.\n`);
        process.exit(2);
      }
      try {
        cmdAdd(wtDeps, slot);
      } catch (e) {
        // cmdAdd failing is a real infra fault (git worktree add), not a per-slot poison — surface it.
        process.stderr.write(`wt-pool: cmdAdd(${slot}) failed: ${e?.message || e}\n`);
        release(slot, deps);
        process.exit(1);
      }
      const candidate = wtDirFor(slot);
      try {
        ensureFresh(candidate, wtDeps.errlog);   // recover staleness — throws if unlanded work won't rebase
      } catch (e) {
        process.stderr.write(`wt-pool: ${slot} could not be refreshed to ${BASE_REMOTE}/${BASE_BRANCH}: ${e?.message || e}\n`);
        process.stderr.write(`wt-pool: skipping ${slot} (its unlanded work is preserved, untouched) — trying the next free slot.\n`);
        release(slot, deps);   // free the lock only; the slot's git commits are left intact
        poisoned.add(slot);    // never re-pick it this run
        continue;
      }
      dir = candidate;
      break;
    }
    ensureDeps(dir, wtDeps.errlog);           // recover deps (install if incomplete)
    if (wantLock) lockWorktree(dir, `${prefix} warm lane`);
    process.stdout.write(`${dir}\n`);
  } else if (sub === 'release') {
    if (!arg) { process.stderr.write('usage: node scripts/wt-pool.mjs release <name>\n'); process.exit(1); }
    release(arg, deps);
    process.stderr.write(`wt-pool: released ${arg}\n`);
  } else if (sub === 'sweep') {
    const force = argv.includes('--force');
    const freed = sweep({ deps, size, now, force, prefix });
    process.stdout.write(`wt-pool sweep (${prefix}): released ${freed.length} slot(s)${freed.length ? ' - ' + freed.join(', ') : ''}\n`);
  } else if (sub === 'sync-lane') {
    // Shared lane-sync primitive as a CLI: `node scripts/wt-pool.mjs sync-lane <path|name>`.
    // The startup guard (agent-startup-guard.ps1) shells here so BOTH sync points use the
    // one hardened path. Exit 0 = lane current with origin/develop; exit 1 = surface (e.g.
    // unlanded commits that will not rebase) — never a destructive fallback.
    if (!arg) { process.stderr.write('usage: node scripts/wt-pool.mjs sync-lane <path|name>\n'); process.exit(1); }
    const dir = (arg.includes('/') || arg.includes('\\')) ? arg : wtDirFor(arg);
    try {
      syncLaneToOriginDevelop(dir, (s) => process.stderr.write(s.endsWith('\n') ? s : s + '\n'));
      process.stdout.write(`READY ${dir}\n`);
    } catch (e) {
      process.stderr.write(`${e?.message || e}\n`);
      process.exit(1);
    }
  } else if (sub === 'warm') {
    const n = Number(arg) || size;
    const { cmdAdd } = await import('./wt.mjs');
    for (let i = 1; i <= n; i++) {
      const name = slotName(i, prefix);
      process.stdout.write(`warming ${name} ...\n`);
      try { cmdAdd(defaultDepsForWt(), name); } catch (e) { process.stderr.write(`warm ${name} failed: ${e?.message || e}\n`); }
    }
  } else if (sub === 'status') {
    for (let i = 1; i <= size; i++) {
      const name = slotName(i, prefix);
      const raw = deps.readLock(name);
      const exists = deps.wtExists(name);
      const dirty = exists ? deps.dirtyCount(name) : 0;
      process.stdout.write(`${name}: ${raw ? 'LOCKED' : 'free'}  ${exists ? 'present' : 'absent'}  dirty=${dirty}\n`);
    }
  } else if (sub === 'drift-sweep') {
    // WP-2 (2026-07-05 review): bound IDLE drift. Fetch origin/develop once, then for
    // every live pool lane: clean + behind-only -> sync via the primitive (safe,
    // unattended); ahead>0 OR dirty -> HELD, report only and never touch (a real session
    // must resolve committed/uncommitted work so conflicts can be answered). Emit a
    // one-line-per-lane drift report to .rdc/reports/. Intended for a 4-6h schedule.
    const gitTop = (a) => { try { return execFileSync('git', a, { cwd: REPO_ROOT, encoding: 'utf8', env: GIT_ENV, stdio: ['ignore', 'pipe', 'pipe'] }).trim(); } catch { return null; } };
    gitTop(['fetch', BASE_REMOTE, BASE_BRANCH]);
    const wl = gitTop(['worktree', 'list', '--porcelain']) || '';
    const lanes = [];
    for (const line of wl.split(/\r?\n/)) {
      if (!line.startsWith('worktree ')) continue;
      const lp = line.slice('worktree '.length).trim().replace(/\\/g, '/');
      const leaf = lp.split('/').filter(Boolean).pop();
      if (isPoolSlot(leaf)) lanes.push({ leaf, lp });
    }
    const rows = [];
    for (const { leaf, lp } of lanes) {
      const ca = (gitOut(lp, ['rev-list', '--left-right', '--count', `${BASE_REMOTE}/${BASE_BRANCH}...HEAD`]) || '').split(/\s+/);
      const behind = Number.parseInt(ca[0], 10) || 0;
      const ahead = Number.parseInt(ca[1], 10) || 0;
      const dirty = (gitOut(lp, ['status', '--porcelain']) || '') !== '' ? 1 : 0;
      // NEVER touch a lane with a LIVE session — rebasing a branch under an active
      // editor is disruptive even when --autostash loses nothing (e.g. the Odyssey
      // site edited live in claude-7). Live = its pool lock holds an alive pid.
      const livePid = liveLockedOwnerPid(deps, leaf);
      const live = livePid > 0;
      let action;
      if (live) action = `HELD (live session pid=${livePid} — never touch an active lane)`;
      else if (ahead > 0) action = `HELD (ahead=${ahead} unlanded — land in the lane)`;
      else if (dirty) action = 'HELD (dirty — uncommitted work in the lane)';
      else if (behind > 0) {
        try { syncLaneToOriginDevelop(lp); action = `SYNCED (${behind} behind → 0/0)`; }
        catch (e) { action = `STALE (sync failed: ${e?.message || e})`; }
      } else action = 'fresh';
      rows.push(`- ${leaf}: behind=${behind} ahead=${ahead} dirty=${dirty} → ${action}`);
    }
    const d = new Date();
    const stamp = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
    const reportsDir = path.join(REPO_ROOT, '.rdc', 'reports');
    mkdirSync(reportsDir, { recursive: true });
    const file = path.join(reportsDir, `${stamp}-pool-drift.md`);
    const body = `# Pool drift sweep — ${d.toISOString()}\n\n${rows.length ? rows.join('\n') : '(no pool lanes found)'}\n`;
    writeFileSync(file, body);
    process.stdout.write(body + `\n(report: ${file})\n`);
  } else {
    process.stdout.write('usage: node scripts/wt-pool.mjs claim | release <name> | sync-lane <path> | drift-sweep | sweep [--force] | warm [n] | status  [--prefix <claude|x-codex>] [--lock] [--size <n>]\n');
  }
}

/** wt.mjs deps that stream to stdout (CLI warm — output is fine on stdout here). */
function defaultDepsForWt() {
  return {
    run(cmd, args, opts = {}) {
      const useShell = process.platform === 'win32' && /\.(cmd|bat)$/i.test(cmd);
      return execFileSync(cmd, args, { cwd: opts.cwd ?? REPO_ROOT, encoding: 'utf8', env: GIT_ENV, stdio: opts.stdio ?? ['ignore', 'pipe', 'pipe'], shell: useShell });
    },
    exists: existsSync,
    log: (s) => process.stdout.write(s.endsWith('\n') ? s : s + '\n'),
    errlog: (s) => process.stderr.write(s.endsWith('\n') ? s : s + '\n'),
  };
}

/**
 * wt.mjs deps for the `claim` path: identical to defaultDepsForWt() except ALL
 * cmdAdd progress is routed to STDERR. stdout is reserved for the path-only
 * contract the launcher captures.
 */
function defaultDepsForWtStderr() {
  const d = defaultDepsForWt();
  d.log = (s) => process.stderr.write(s.endsWith('\n') ? s : s + '\n');
  // pnpm install streams to inherited stdio; force its child output to stderr too.
  const baseRun = d.run;
  d.run = (cmd, args, opts = {}) => {
    if (opts.stdio === 'inherit') opts = { ...opts, stdio: ['ignore', 2, 2] };
    return baseRun(cmd, args, opts);
  };
  return d;
}
