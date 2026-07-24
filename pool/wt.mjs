#!/usr/bin/env node
/**
 * wt.mjs — git-backed, crash-isolated, RESTARTABLE sibling worktrees.
 *
 * Each cell/agent gets its own worktree at C:/Dev/regen-root.wt/<name> on
 * branch wt/<name>, branched off a FRESHLY-FETCHED origin/develop HEAD (never the
 * current in-progress HEAD — kills the stale-base bug by construction). The point
 * is RECOVERABILITY: an aborted/hung session re-attaches to its existing worktree
 * with uncommitted work intact, never loses or strands work.
 *
 * Subcommands:
 *   add <name> [--no-install]  create/re-attach a worktree (idempotent, restartable)
 *   enter <name>               print the absolute path of an existing worktree
 *   list                       table of all *.wt/* worktrees
 *   remove <name> [--force]    remove a worktree (refuses if dirty unless --force)
 *   prune                      git worktree prune; never deletes a dirty worktree
 *
 * Dependency-free (Node built-ins only). All git via execFileSync with explicit
 * arg vectors (no shell string interpolation) + MSYS_NO_PATHCONV=1 so Git-Bash on
 * Windows does not mangle paths/refspecs.
 *
 * Testability: every external effect goes through an injectable `deps` object
 * ({ run, exists, log, errlog }) so tests can mock child_process + fs and assert
 * the exact git arg vectors with NO real git/pnpm running. The default deps are
 * the real built-ins.
 */
import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, copyFileSync, mkdirSync, constants as fsConstants } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Repo root — prefer PROJECT_ROOT env var (set by environment harness shim),
// fall back to parent of this file's location for direct invocation.
export const REPO_ROOT = process.env.PROJECT_ROOT || path.resolve(__dirname, '..');
// Sibling worktree root: C:/Dev/regen-root  ->  C:/Dev/regen-root.wt
export const WT_ROOT = REPO_ROOT + '.wt';
export const BASE_REMOTE = 'origin';
export const BASE_BRANCH = 'develop';

const GIT_ENV = { ...process.env, MSYS_NO_PATHCONV: '1' };

/** Error that carries a process exit code (so main() can exit cleanly). */
export class WtError extends Error {
  constructor(message, code = 1) {
    super(message);
    this.exitCode = code;
  }
}

// --- Default real effects (overridable in tests) ---------------------------

/** Real spawn: run `<cmd> <args>` in `cwd`, return trimmed stdout. */
function realRun(cmd, args, opts = {}) {
  // Windows: a .cmd/.bat shim (e.g. pnpm.cmd) cannot be spawned directly by
  // execFileSync — it throws `spawnSync <cmd> EINVAL`. Route those through the
  // shell so `node scripts/wt.mjs add <name>` installs cleanly. Non-Windows and
  // plain binaries (git) keep the existing no-shell behavior.
  const useShell = process.platform === 'win32' && /\.(cmd|bat)$/i.test(cmd);
  return execFileSync(cmd, args, {
    cwd: opts.cwd ?? REPO_ROOT,
    encoding: 'utf8',
    env: GIT_ENV,
    stdio: opts.stdio ?? ['ignore', 'pipe', 'pipe'],
    shell: useShell,
  });
}

export function defaultDeps() {
  return {
    run: realRun,
    exists: existsSync,
    log: (s) => process.stdout.write(s.endsWith('\n') ? s : s + '\n'),
    errlog: (s) => process.stderr.write(s.endsWith('\n') ? s : s + '\n'),
  };
}

// --- Helpers (pure given deps) ---------------------------------------------

/** Run git with an explicit arg vector via deps.run. Returns trimmed stdout. */
function git(deps, args, opts = {}) {
  return String(deps.run('git', args, { cwd: opts.cwd ?? REPO_ROOT, stdio: opts.stdio })).trim();
}

/** Run git, swallowing a non-zero exit; returns { ok, out, err }. */
function gitTry(deps, args, opts = {}) {
  try {
    return { ok: true, out: git(deps, args, opts) };
  } catch (err) {
    return {
      ok: false,
      out: (err.stdout || '').toString().trim(),
      err: (err.stderr || err.message || '').toString().trim(),
    };
  }
}

/** Forward-slash absolute path for a worktree by name. */
export function wtPath(name) {
  return path.join(WT_ROOT, name).split(path.sep).join('/');
}

export function branchFor(name) {
  return `wt/${name}`;
}

function branchExists(deps, branch) {
  return gitTry(deps, ['show-ref', '--verify', '--quiet', `refs/heads/${branch}`]).ok;
}

function dirtyCount(deps, dir) {
  const r = gitTry(deps, ['status', '--porcelain'], { cwd: dir });
  if (!r.ok) return 0;
  return r.out ? r.out.split('\n').filter(Boolean).length : 0;
}

function aheadBehind(deps, dir) {
  const r = gitTry(deps, ['rev-list', '--left-right', '--count', `${BASE_REMOTE}/${BASE_BRANCH}...HEAD`], { cwd: dir });
  if (!r.ok || !r.out) return { ahead: '?', behind: '?' };
  const [behind, ahead] = r.out.split(/\s+/);
  return { ahead: ahead ?? '?', behind: behind ?? '?' };
}

/** Parse `git worktree list --porcelain` into [{ path, branch }]. */
function listWorktrees(deps) {
  const r = gitTry(deps, ['worktree', 'list', '--porcelain']);
  if (!r.ok) return [];
  const out = [];
  let cur = null;
  for (const line of r.out.split('\n')) {
    if (line.startsWith('worktree ')) {
      if (cur) out.push(cur);
      cur = { path: line.slice('worktree '.length).split(path.sep).join('/'), branch: null };
    } else if (line.startsWith('branch ') && cur) {
      cur.branch = line.slice('branch '.length).replace('refs/heads/', '');
    } else if (line.startsWith('detached') && cur) {
      cur.branch = '(detached)';
    }
  }
  if (cur) out.push(cur);
  return out;
}

function siblingWorktrees(deps) {
  const root = WT_ROOT.split(path.sep).join('/') + '/';
  return listWorktrees(deps).filter((w) => w.path.startsWith(root));
}

function pnpmInstall(deps, dir) {
  const nmDir = path.join(dir, 'node_modules');
  if (deps.exists(nmDir)) {
    deps.log(`pnpm install skipped — node_modules already present in ${dir}`);
    return;
  }
  deps.log(`pnpm install in ${dir} (prefer-offline, frozen-lockfile) ...`);
  const pnpmCmd = process.platform === 'win32' ? 'pnpm.cmd' : 'pnpm';
  try {
    deps.run(pnpmCmd, ['install', '--prefer-offline', '--frozen-lockfile'], { cwd: dir, stdio: 'inherit' });
  } catch (err) {
    const reason = err?.code || err?.message || String(err);
    if (err?.code !== 'ENOENT') {
      throw err;
    }
    deps.log(`  install-warn: ${pnpmCmd} install failed (${reason}); worktree is still usable`);
  }
}

// ---------------------------------------------------------------------------
// Env propagation — copy gitignored env/secret files into a worktree so apps
// can build/run. Uses COPYFILE_EXCL: copies ONLY missing files, never clobbers
// a worktree-local edit. Called at the end of cmdAdd on BOTH fresh and
// re-attach paths so a newly-added app's .env.local gets propagated on relaunch.
// ---------------------------------------------------------------------------

/** Match a filename against env-file glob patterns. */
function isEnvFile(name) {
  // .env, .env.local, .env.*.local, .env.<anything>.local
  return (
    name === '.env' ||
    name === '.env.local' ||
    (name.startsWith('.env.') && name.endsWith('.local'))
  );
}

/**
 * Copy gitignored env/secret files from repoRoot into wtDir at the same
 * relative paths. Never clobbers (COPYFILE_EXCL). Dependency-free.
 *
 * Sources:
 *   - Root: .env, .env.local, .env.*.local
 *   - Apps: apps/<app>/.env, .env.local, .env*.local
 *   - Claude: .claude/settings.local.json
 *
 * @param {string} repoRoot  Absolute path to the main repo root
 * @param {string} wtDir     Absolute path to the worktree directory
 * @param {object} deps      Injectable deps ({ exists, log })
 */
export function propagateEnv(repoRoot, wtDir, deps = defaultDeps()) {
  const relPaths = [];

  // 1. Root env files
  try {
    const rootEntries = readdirSync(repoRoot);
    for (const entry of rootEntries) {
      if (isEnvFile(entry)) relPaths.push(entry);
    }
  } catch { /* root unreadable — skip */ }

  // 2. Apps env files: apps/<app>/.env*
  const appsDir = path.join(repoRoot, 'apps');
  try {
    const apps = readdirSync(appsDir, { withFileTypes: true });
    for (const app of apps) {
      if (!app.isDirectory()) continue;
      const appDir = path.join(appsDir, app.name);
      try {
        const entries = readdirSync(appDir);
        for (const entry of entries) {
          if (isEnvFile(entry)) {
            relPaths.push(path.join('apps', app.name, entry));
          }
        }
      } catch { /* app dir unreadable — skip */ }
    }
  } catch { /* apps dir absent — skip */ }

  // 3. Claude settings
  const claudeSettings = path.join('.claude', 'settings.local.json');
  const claudeSettingsSrc = path.join(repoRoot, claudeSettings);
  if (existsSync(claudeSettingsSrc)) {
    relPaths.push(claudeSettings);
  }

  // Copy each file that exists in the source but not yet in the target.
  let copied = 0;
  let skipped = 0;
  for (const rel of relPaths) {
    const src = path.join(repoRoot, rel);
    const dst = path.join(wtDir, rel);

    // Source must exist (it should — we just discovered it).
    if (!existsSync(src)) continue;

    // Ensure destination directory exists.
    const dstDir = path.dirname(dst);
    mkdirSync(dstDir, { recursive: true });

    try {
      copyFileSync(src, dst, fsConstants.COPYFILE_EXCL);
      deps.log(`  env-copy: ${rel}`);
      copied++;
    } catch (err) {
      if (err.code === 'EEXIST') {
        deps.log(`  env-skip: ${rel} (already exists)`);
        skipped++;
      } else {
        deps.log(`  env-warn: ${rel} — ${err.message}`);
      }
    }
  }
  deps.log(`env propagation: ${copied} copied, ${skipped} skipped (already present)`);
}

// ---------------------------------------------------------------------------
// Subcommands — each takes (deps, name, flags), returns an exit code (0).
// Throw WtError for failures so main() can map to a non-zero exit + stderr.
// ---------------------------------------------------------------------------

export function cmdAdd(deps, name, flags = new Set()) {
  if (!name) throw new WtError('usage: wt add <name> [--no-install]');
  const dir = wtPath(name);
  const branch = branchFor(name);

  // RE-ATTACH: worktree dir already exists → never recreate, never lose work.
  if (deps.exists(dir)) {
    const inside = gitTry(deps, ['rev-parse', '--is-inside-work-tree'], { cwd: dir });
    const currentBranch = gitTry(deps, ['rev-parse', '--abbrev-ref', 'HEAD'], { cwd: dir });
    if (!inside.ok || inside.out !== 'true' || !currentBranch.ok) {
      throw new WtError(
        `add: ${dir} exists but is not a valid git worktree. ` +
        `Move it aside, then re-run: node scripts/wt.mjs add ${name}`,
        1
      );
    }
    if (currentBranch.out !== branch) {
      throw new WtError(
        `add: ${dir} is on ${currentBranch.out}, expected ${branch}. ` +
        `Refusing to reattach the wrong worktree.`,
        1
      );
    }
    const dc = dirtyCount(deps, dir);
    deps.log(
      `re-attach: worktree already present\n` +
      `  path:   ${dir}\n` +
      `  branch: ${branch}\n` +
      `  dirty:  ${dc} file(s)`
    );
    // Propagate any new env files (e.g. a new app added since last attach).
    propagateEnv(REPO_ROOT, dir, deps);
    return 0;
  }

  // Always base off FRESH origin/develop — fetch first.
  deps.log(`git fetch ${BASE_REMOTE} ${BASE_BRANCH} ...`);
  git(deps, ['fetch', BASE_REMOTE, BASE_BRANCH], { stdio: 'inherit' });

  if (branchExists(deps, branch)) {
    // Branch exists but worktree dir is gone → re-add onto the existing branch
    // (preserves committed work). Do NOT reset the branch to develop.
    deps.log(`branch ${branch} exists; re-adding worktree onto it (preserving committed work)`);
    git(deps, ['worktree', 'add', dir, branch], { stdio: 'inherit' });
  } else {
    // Fresh branch off the just-fetched origin/develop HEAD.
    git(deps, ['worktree', 'add', dir, '-b', branch, `${BASE_REMOTE}/${BASE_BRANCH}`], { stdio: 'inherit' });
  }

  deps.log(`worktree ready: ${dir}  (branch ${branch} @ ${BASE_REMOTE}/${BASE_BRANCH})`);

  // Copy gitignored env/secret files into the new worktree.
  propagateEnv(REPO_ROOT, dir, deps);

  if (flags.has('--no-install')) {
    deps.log('--no-install: skipping pnpm install');
  } else {
    pnpmInstall(deps, dir);
  }
  return 0;
}

export function cmdEnter(deps, name) {
  if (!name) throw new WtError('usage: wt enter <name>');
  const dir = wtPath(name);
  if (!deps.exists(dir)) throw new WtError(`enter: no worktree at ${dir}`, 1);
  deps.log(dir); // path to stdout so caller can `cd "$(node wt.mjs enter <name>)"`
  return 0;
}

export function cmdList(deps) {
  const wts = siblingWorktrees(deps);
  if (wts.length === 0) {
    deps.log(`No worktrees under ${WT_ROOT}`);
    return 0;
  }
  const rows = wts.map((w) => {
    const name = w.path.slice(w.path.lastIndexOf('/') + 1);
    const { ahead, behind } = aheadBehind(deps, w.path);
    const dc = dirtyCount(deps, w.path);
    return { name, branch: w.branch ?? '?', ab: `+${ahead}/-${behind}`, dirty: String(dc) };
  });
  const col = (key, head) => Math.max(head.length, ...rows.map((r) => r[key].length));
  const wName = col('name', 'NAME');
  const wBr = col('branch', 'BRANCH');
  const wAb = col('ab', 'AHEAD/BEHIND');
  const wD = col('dirty', 'DIRTY');
  const pad = (s, n) => s.padEnd(n);
  deps.log(`${pad('NAME', wName)}  ${pad('BRANCH', wBr)}  ${pad('AHEAD/BEHIND', wAb)}  ${pad('DIRTY', wD)}`);
  for (const r of rows) {
    deps.log(`${pad(r.name, wName)}  ${pad(r.branch, wBr)}  ${pad(r.ab, wAb)}  ${pad(r.dirty, wD)}`);
  }
  return 0;
}

export function cmdRemove(deps, name, flags = new Set()) {
  if (!name) throw new WtError('usage: wt remove <name> [--force]');
  const dir = wtPath(name);
  const branch = branchFor(name);
  const force = flags.has('--force');

  if (!deps.exists(dir)) throw new WtError(`remove: no worktree at ${dir}`, 1);

  const dc = dirtyCount(deps, dir);
  if (dc > 0 && !force) {
    throw new WtError(
      `remove: worktree ${dir} has ${dc} uncommitted change(s). ` +
      `Refusing to delete (work would be lost). Commit/push, or re-run with --force.`,
      1
    );
  }

  git(deps, ['worktree', 'remove', ...(force ? ['--force'] : []), dir], { stdio: 'inherit' });
  // Delete the branch: -d (safe, merged-only) by default; -D only with --force.
  const delFlag = force ? '-D' : '-d';
  const br = gitTry(deps, ['branch', delFlag, branch]);
  if (br.ok) {
    deps.log(`removed worktree + branch ${branch}`);
  } else {
    deps.log(
      `removed worktree; branch ${branch} NOT deleted (${br.err || 'not fully merged'}). ` +
      `Re-run with --force to force-delete the branch.`
    );
  }
  return 0;
}

export function cmdPrune(deps) {
  // `git worktree prune` only removes administrative entries for worktrees whose
  // directories are already gone; it never touches a present (dirty or clean)
  // worktree. We additionally report which present siblings are dirty so they
  // are visibly PRESERVED, never auto-removed.
  const out = git(deps, ['worktree', 'prune', '-v']);
  if (out) deps.log(out);
  const after = siblingWorktrees(deps);
  const dirty = after.filter((w) => dirtyCount(deps, w.path) > 0).map((w) => w.path);
  deps.log(`pruned stale worktree admin entries; ${after.length} present worktree(s) remain`);
  if (dirty.length) {
    deps.log(`preserved (dirty — never auto-removed):`);
    for (const d of dirty) deps.log(`  ${d}`);
  }
  return 0;
}

export const SUBCOMMANDS = ['add', 'enter', 'list', 'remove', 'prune'];

function usage(deps) {
  deps.log(
    `wt.mjs — git-backed, restartable sibling worktrees (${WT_ROOT}/<name>)\n\n` +
    `Usage:\n` +
    `  node scripts/wt.mjs add <name> [--no-install]   create/re-attach a worktree off origin/develop\n` +
    `  node scripts/wt.mjs enter <name>                print the worktree path (for cd)\n` +
    `  node scripts/wt.mjs list                        list all sibling worktrees\n` +
    `  node scripts/wt.mjs remove <name> [--force]     remove a worktree (refuses if dirty unless --force)\n` +
    `  node scripts/wt.mjs prune                       prune stale entries (never deletes a dirty worktree)`
  );
}

// ---------------------------------------------------------------------------
// Dispatch — returns an exit code; never calls process.exit (testable).
// ---------------------------------------------------------------------------

export function run(argv, deps = defaultDeps()) {
  const args = argv.slice(2);
  const sub = args[0];
  const rest = args.slice(1);
  const positional = rest.filter((a) => !a.startsWith('--'));
  const flags = new Set(rest.filter((a) => a.startsWith('--')));
  const name = positional[0];

  try {
    switch (sub) {
      case 'add':    return cmdAdd(deps, name, flags);
      case 'enter':  return cmdEnter(deps, name);
      case 'list':   return cmdList(deps);
      case 'remove': return cmdRemove(deps, name, flags);
      case 'prune':  return cmdPrune(deps);
      case undefined:
        usage(deps);
        return 1;
      case '-h':
      case '--help':
        usage(deps);
        return 0;
      default:
        deps.errlog(`unknown subcommand: ${sub}`);
        usage(deps);
        return 1;
    }
  } catch (err) {
    if (err instanceof WtError) {
      deps.errlog(err.message);
      return err.exitCode;
    }
    throw err;
  }
}

const invokedDirectly = process.argv[1] && path.resolve(process.argv[1]) === __filename;
if (invokedDirectly) {
  process.exit(run(process.argv));
}
