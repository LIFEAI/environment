#!/usr/bin/env node
/**
 * env-sync.mjs — environment drift doctor + reconciler for the Carbon7 ⇄ Vultr dev planes.
 *
 * THE MODEL (GitOps-lite): git is the single source of truth. Each managed
 * component declares the surfaces where a version/SHA must agree:
 *   - source        (the repo checkout — package.json / plugin.json / git HEAD)
 *   - npm           (published package, if applicable)
 *   - clone/cache   (Claude Code marketplace clone + plugin cache — NOT covered by the deploy webhook)
 *   - running local (Carbon7 /health)
 *   - running dev   (Vultr /health — reconciled by the develop-push webhook, shown for drift only)
 *
 * `--check` (default) is READ-ONLY: prints a drift table, exits 1 on any drift.
 * `--fix` reconciles the LOCAL (Carbon7) plane only — it NEVER mutates Vultr/prod
 *   (those are webhook/GitOps-driven). Local fixes: pull marketplace clone,
 *   reinstall plugin, rebuild CodeFlow artifacts without restarting its blue/green
 *   gateway, reinstall hooks, and save PM2 only for non-CodeFlow services.
 *
 * Usage:
 *   node scripts/env-sync.mjs            # drift report
 *   node scripts/env-sync.mjs --fix      # reconcile local plane, then re-report
 *   node scripts/env-sync.mjs --json
 */
import { execSync, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const FIX = process.argv.includes('--fix');
const JSON_OUT = process.argv.includes('--json');
// Pre-rebuild gate: exit non-zero ONLY on unpushed LOCAL work (what a rebuild
// would destroy), ignoring codeflow/rdc-skills version drift (which a rebuild
// FIXES by re-cloning). Used by dev-env/bootstrap.ps1's step-0 safety pre-flight.
const GATE_LOCAL_ONLY = process.argv.includes('--gate-local-only');
const HOME = os.homedir();
const VULTR = 'root@64.237.54.189';

function sh(cmd, opts = {}) {
  try { return execSync(cmd, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 30_000, ...opts }).trim(); }
  catch { return null; }
}
// Exit-code-only run: 0 on success, non-zero (or 1) otherwise. Used to consult a
// subscript's own --check mode without re-implementing its logic in env-sync.
function runExit(cmd) {
  try { execSync(cmd, { stdio: 'ignore', timeout: 30_000 }); return 0; }
  catch (e) { return e?.status ?? 1; }
}
function readJson(p) { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; } }
async function healthInfo(url) {
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 8000);
    const r = await fetch(url, { signal: ctrl.signal });
    clearTimeout(t);
    const j = await r.json();
    return { version: j.version ?? null, sha: j.git_sha ?? null };
  } catch { return { version: null, sha: null }; }
}
// git's `rev-parse --short` returns a VARIABLE-length abbreviation (>=7, longer
// when needed for uniqueness), while /health emits the full 40-char SHA. Compare
// on a common 7-char prefix so the same commit never string-mismatches itself.
const sha7 = (s) => (s && s !== 'unknown' ? s.slice(0, 7) : null);
const shaEq = (a, b) => {
  const x = sha7(a);
  const y = sha7(b);
  return x == null || y == null ? null : x === y;
}; // null = indeterminate
function gitHead(dir) { return sh(`git -C "${dir}" rev-parse --short HEAD`); }
function gitBehind(dir, remote) {
  sh(`git -C "${dir}" fetch -q ${remote.split('/')[0]} 2>/dev/null`);
  const n = sh(`git -C "${dir}" rev-list --count HEAD..${remote}`);
  return n == null ? null : Number.parseInt(n, 10);
}

// ── Local-plane drift gate (WP-1.4) ──────────────────────────────────────────
// repos.json is authored by WP-1.1 (dev-env/repos.json). We read it if present
// and degrade gracefully when absent — the gate simply has no repos to check.
// Resolved lazily because REPO is declared in the components section below.
function reposManifestPath() { return path.join(REPO, 'dev-env/repos.json'); }

// Pure decision helper — the unit under test. Given a repo's git state, decide
// whether the local checkout is "pushed" (safe to rebuild over). It is NOT
// pushed if there are unpushed commits (ahead > 0) OR any stashed work
// (stash > 0). dirty/behind do not, by themselves, fail this gate — uncommitted
// edits are a separate concern and being behind the remote loses no local work.
// Indeterminate counts (null — e.g. no upstream / git unreachable) are treated
// as "nothing unpushed proven" → true, so a missing upstream never hard-fails.
function localPushed(state) {
  const ahead = Number(state?.ahead);
  const stash = Number(state?.stash);
  const hasUnpushed = Number.isFinite(ahead) && ahead > 0;
  const hasStash = Number.isFinite(stash) && stash > 0;
  return !(hasUnpushed || hasStash);
}

// Resolve a repo's on-disk path from a manifest entry. Entries may carry an
// explicit `path`/`dir`; otherwise fall back to C:/Dev/<slug>.
function repoPath(entry) {
  const p = entry.path || entry.dir || path.join('C:/Dev', entry.slug || '');
  return p;
}

// Compute ahead/behind/dirty/stash for one repo checkout. All counts are
// integers; null where git could not answer (missing dir, no upstream, etc.).
function repoState(dir) {
  const exists = dir && fs.existsSync(path.join(dir, '.git'));
  if (!exists) return { ahead: null, behind: null, dirty: null, stash: null, missing: true };
  // Fetch the tracking remote quietly so ahead/behind reflect the real remote.
  const upstream = sh(`git -C "${dir}" rev-parse --abbrev-ref --symbolic-full-name @{u}`);
  if (upstream) sh(`git -C "${dir}" fetch -q ${upstream.split('/')[0]} 2>/dev/null`);
  const aheadBehind = upstream
    ? sh(`git -C "${dir}" rev-list --left-right --count @{u}...HEAD`) // "<behind>\t<ahead>"
    : null;
  let behind = null;
  let ahead = null;
  if (aheadBehind) { const [b, a] = aheadBehind.split(/\s+/).map((n) => Number.parseInt(n, 10)); behind = b; ahead = a; }
  const dirtyOut = sh(`git -C "${dir}" status --porcelain`);
  const dirty = dirtyOut == null ? null : (dirtyOut === '' ? 0 : dirtyOut.split('\n').filter(Boolean).length);
  const stashOut = sh(`git -C "${dir}" stash list`);
  const stash = stashOut == null ? null : (stashOut === '' ? 0 : stashOut.split('\n').filter(Boolean).length);
  return { ahead, behind, dirty, stash, upstream: !!upstream };
}

// Read repos.json and compute per-repo drift for every `class:"owned"` repo.
// Returns { name, agree, repos: [{repo, ahead, behind, dirty, stash, pushed}], rows }.
function checkLocalRepos() {
  const manifest = readJson(reposManifestPath());
  if (!manifest) {
    return { name: 'local-repos', agree: true, repos: [], rows: { 'dev-env/repos.json': '(absent — drift gate skipped)' }, skipped: true };
  }
  const entries = Array.isArray(manifest) ? manifest : (manifest.repos ?? []);
  // Owned repos are the safety-gate scope; tools-home repos are owned too.
  const owned = entries.filter((e) => e && e.class === 'owned');
  const repos = [];
  const rows = {};
  for (const e of owned) {
    const slug = e.slug || path.basename(repoPath(e));
    const dir = repoPath(e);
    const st = repoState(dir);
    const pushed = st.missing ? true : localPushed(st);
    repos.push({ repo: slug, ahead: st.ahead, behind: st.behind, dirty: st.dirty, stash: st.stash, pushed });
    const tag = st.missing ? '(missing)' : `${st.ahead ?? '?'}↑ ${st.behind ?? '?'}↓ dirty:${st.dirty ?? '?'} stash:${st.stash ?? '?'} ${pushed ? 'pushed' : 'UNPUSHED'}`;
    rows[slug] = tag;
  }
  // The gate: any owned repo that is NOT pushed fails the local plane.
  const unpushed = repos.filter((r) => !r.pushed).map((r) => r.repo);
  const behindRepos = repos.filter((r) => Number.isFinite(r.behind) && r.behind > 0).map((r) => r.repo);
  const agree = unpushed.length === 0;
  if (unpushed.length) rows['⚠ unpushed'] = unpushed.join(', ');
  if (behindRepos.length) rows['· behind remote'] = behindRepos.join(', ');
  return { name: 'local-repos', agree, repos, rows, unpushed };
}

// Best-effort cross-box check: ask carbon7 whether any owned repo there has
// unpushed commits. NEVER fails on ssh-unreachable — warn only. Returns a list
// of warning strings (empty when reachable+clean or unreachable).
function warnOtherBox() {
  // Single ssh round-trip: for each owned repo dir, print "<slug> <ahead>".
  const manifest = readJson(reposManifestPath());
  if (!manifest) return [];
  const entries = Array.isArray(manifest) ? manifest : (manifest.repos ?? []);
  const owned = entries.filter((e) => e && e.class === 'owned');
  if (!owned.length) return [];
  // Build a remote shell snippet. carbon7 mirrors C:/Dev; resolve each repo by
  // slug under /c/Dev (git-bash path) — best effort, tolerant of missing dirs.
  const remoteScript = owned.map((e) => {
    const slug = e.slug || path.basename(repoPath(e));
    const rdir = `/c/Dev/${slug}`;
    return `if [ -d "${rdir}/.git" ]; then a=$(git -C "${rdir}" rev-list --count @{u}..HEAD 2>/dev/null); echo "${slug} \${a:-?}"; fi`;
  }).join('; ');
  // ConnectTimeout keeps an unreachable box from stalling the report.
  const out = sh(`ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 carbon7 'bash -lc ${JSON.stringify(remoteScript)}' 2>/dev/null`);
  if (out == null) return []; // unreachable → warn nothing, never fail
  const warnings = [];
  for (const line of out.split('\n').map((l) => l.trim()).filter(Boolean)) {
    const [slug, aRaw] = line.split(/\s+/);
    const a = Number.parseInt(aRaw, 10);
    if (Number.isFinite(a) && a > 0) warnings.push(`carbon7: ${slug} has ${a} unpushed commit(s)`);
  }
  return warnings;
}

// ── Managed components ───────────────────────────────────────────────────────
const REPO = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Z]:)/, '$1')), '..');
const RDC_SKILLS_REPO = 'C:/Dev/rdc-skills';
const MARKET_CLONE = path.join(HOME, '.claude/plugins/marketplaces/rdc-skills');
const CACHE_PLUGIN = path.join(HOME, '.claude/plugins/cache/rdc-skills/rdc-skills/latest/.claude-plugin/plugin.json');

async function checkRdcSkills() {
  const srcPkg = readJson(path.join(RDC_SKILLS_REPO, 'package.json'))?.version ?? '?';
  const srcPlugin = readJson(path.join(RDC_SKILLS_REPO, '.claude-plugin/plugin.json'))?.version ?? '?';
  const npmV = sh('npm view @lifeaitools/rdc-skills version');
  const cloneV = readJson(path.join(MARKET_CLONE, '.claude-plugin/plugin.json'))?.version ?? '?';
  const cloneBehind = gitBehind(MARKET_CLONE, 'origin/master');
  const cacheV = readJson(CACHE_PLUGIN)?.version ?? '?';
  const mcp = await healthInfo('https://rdc-skills.regendevcorp.com/health');
  const srcHeadRaw = gitHead(RDC_SKILLS_REPO);         // commit the running MCP loads from
  const mcpSha = sha7(mcp.sha);
  const srcHead = sha7(srcHeadRaw);
  // SHA agreement: running MCP must report the source checkout's HEAD. Compare
  // on 7-char prefixes; null (MCP unreachable / no git_sha) is indeterminate → never fails.
  const shaCmp = shaEq(mcp.sha, srcHeadRaw);
  const shaAgree = shaCmp !== false;
  const versions = [srcPkg, srcPlugin, npmV, cloneV, cacheV, mcp.version];
  const agree = new Set(versions.filter(Boolean)).size === 1 && (cloneBehind === 0 || cloneBehind === null) && shaAgree;
  return {
    name: 'rdc-skills', agree,
    rows: { 'source pkg': srcPkg, 'source plugin.json': srcPlugin, npm: npmV, 'marketplace clone': `${cloneV} (${cloneBehind ?? '?'} behind)`, 'plugin cache': cacheV, 'running MCP': mcp.version, 'running MCP sha': `${mcpSha ?? '(no git_sha)'} ${shaCmp == null ? '·' : shaCmp ? '==' : '!='} src ${srcHead ?? '?'}` },
  };
}

async function checkCodeflow() {
  const srcPkg = readJson(path.join(REPO, 'packages/codeflow/package.json'))?.version ?? '?';
  const repoHead = gitHead(REPO);
  const repoBehind = gitBehind(REPO, 'origin/develop');
  const localMcp = await healthInfo('http://127.0.0.1:3109/health');
  const devMcp = await healthInfo('https://codeflow.regendevcorp.com/health');
  const vultrHead = sh(`ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ${VULTR} 'git -C /srv/regen/regen-root rev-parse --short HEAD' 2>/dev/null`);
  const localSha = sha7(localMcp.sha);
  const devSha = sha7(devMcp.sha);
  // local MCP loads from this checkout (repoHead); dev MCP loads from the Vultr
  // checkout (vultrHead). Compare 7-char prefixes; null = indeterminate → never fails.
  const localCmp = shaEq(localMcp.sha, repoHead);
  const devCmp = shaEq(devMcp.sha, vultrHead);
  const localShaAgree = localCmp !== false;
  const devShaAgree = devCmp !== false;
  const agree = srcPkg === localMcp.version && srcPkg === devMcp.version && (repoBehind === 0 || repoBehind === null) && localShaAgree && devShaAgree;
  return {
    name: 'codeflow', agree,
    rows: { 'source pkg': srcPkg, 'regen-root HEAD': `${repoHead} (${repoBehind ?? '?'} behind develop)`, 'local MCP (3109)': `${localMcp.version} @ ${localSha ?? '(no git_sha)'} ${localCmp == null ? '·' : localCmp ? '==' : '!='} ${sha7(repoHead) ?? '?'}`, 'dev MCP (codeflow.regendevcorp.com)': `${devMcp.version} @ ${devSha ?? '(no git_sha)'} ${devCmp == null ? '·' : devCmp ? '==' : '!='} vultr ${sha7(vultrHead) ?? '?'}`, 'Vultr checkout HEAD': vultrHead ?? '(ssh unreachable)' },
  };
}

// ── Reconcile (local plane only) ─────────────────────────────────────────────
function fixRdcSkills() {
  const log = [];
  // 1. marketplace clone → origin/master
  if (sh(`git -C "${MARKET_CLONE}" fetch -q origin && git -C "${MARKET_CLONE}" reset --hard origin/master`) != null) log.push('pulled marketplace clone → origin/master');
  // 2. reinstall plugin (writes cache + installed_plugins + endpoint config)
  sh(`node "${RDC_SKILLS_REPO}/scripts/install-rdc-skills.js"`, { stdio: ['ignore', 'ignore', 'ignore'] });
  log.push('ran install-rdc-skills.js');
  // 3. restart MCP to serve current label
  if (sh('pm2 restart rdc-skills-mcp --update-env && pm2 save') != null) log.push('restarted rdc-skills-mcp + pm2 save');
  return log;
}
function fixCodeflow() {
  const log = [];
  if (sh(`npm --prefix "${path.join(REPO, 'packages/codeflow')}" run esbuild`, { cwd: path.join(REPO, 'packages/codeflow') }) != null) log.push('rebuilt codeflow dist (esbuild)');
  log.push('skipped codeflow-mcp restart; stable gateway is blue/green-owned (run node scripts/codeflow-bluegreen.mjs recover)');
  // hooks (endpoint config + registrations)
  sh(`node "${REPO}/scripts/claude-hooks/install-codeflow-hooks.mjs"`, { stdio: ['ignore', 'ignore', 'ignore'] });
  log.push('reinstalled codeflow hooks');
  return log;
}

// ── Startup-environment concern (per-box runtime provisioning) ───────────────
// Unlike codeflow/rdc-skills (version drift), this component verifies that the
// idempotent startup subscripts have been applied to THIS box. Each concern is a
// standalone subscript under scripts/dev-setup/ (or scripts/) — env-sync only
// orchestrates: it calls each subscript's --check to detect drift and each
// subscript's apply mode under --fix. No provisioning logic lives here.
const NODE = process.execPath;
const PWSH = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File';
const SUB = {
  mcp: path.join(REPO, 'scripts/dev-setup/patch-mcp-servers.mjs'),
  shortcuts: path.join(REPO, 'scripts/dev-setup/patch-desktop-shortcuts.ps1'),
  autostart: path.join(REPO, 'scripts/register-autostart.ps1'),
};
const AUTOSTART_LNK = path.join(HOME, 'AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup/clauth-autostart.lnk');
const CODEX_MANAGED_MIRROR = path.join(REPO, 'codex/requirements.managed.toml');
const CODEX_MANAGED_LIVE = 'C:/ProgramData/OpenAI/Codex/requirements.toml';

function normalizeText(s) {
  return String(s ?? '').replace(/\r\n/g, '\n').trim();
}

function codexManagedPolicyState(mirrorText, liveText) {
  if (!mirrorText) return { ok: false, status: '⚠ mirror missing' };
  if (liveText == null) return { ok: false, status: '⚠ live policy missing' };
  const ok = normalizeText(mirrorText) === normalizeText(liveText);
  return { ok, status: ok ? 'installed' : '⚠ live policy differs from mirror' };
}

async function checkStartupEnv() {
  const mcpBad = runExit(`"${NODE}" "${SUB.mcp}" --check`) !== 0;
  const shortcutBad = runExit(`${PWSH} "${SUB.shortcuts}" -Check`) !== 0;
  const autostartMissing = !fs.existsSync(AUTOSTART_LNK);
  const mirrorText = fs.existsSync(CODEX_MANAGED_MIRROR) ? fs.readFileSync(CODEX_MANAGED_MIRROR, 'utf8') : '';
  const liveText = fs.existsSync(CODEX_MANAGED_LIVE) ? fs.readFileSync(CODEX_MANAGED_LIVE, 'utf8') : null;
  const codexManaged = codexManagedPolicyState(mirrorText, liveText);
  const dc = await healthInfo('http://127.0.0.1:3003/api/version'); // informational only
  const agree = !mcpBad && !shortcutBad && !autostartMissing && codexManaged.ok;
  return {
    name: 'startup-env', agree,
    rows: {
      'mcp registry': mcpBad ? '⚠ daemon-path dupe present' : 'clean',
      'desktop shortcut': shortcutBad ? '⚠ missing/mis-targeted' : 'ok',
      'clauth autostart': autostartMissing ? '⚠ missing' : 'ok',
      'codex managed hooks': codexManaged.status,
      'dev-center (3003)': dc.version ?? '(unreachable — guard starts it on session)',
    },
  };
}
function fixStartupEnv() {
  const log = [];
  if (runExit(`"${NODE}" "${SUB.mcp}"`) === 0) log.push('patched MCP registry (removed any daemon-path dupes)');
  if (runExit(`${PWSH} "${SUB.shortcuts}"`) === 0) log.push('patched desktop shortcuts');
  if (runExit(`${PWSH} "${SUB.autostart}"`) === 0) log.push('registered clauth autostart watchdog');
  try {
    fs.mkdirSync(path.dirname(CODEX_MANAGED_LIVE), { recursive: true });
    fs.copyFileSync(CODEX_MANAGED_MIRROR, CODEX_MANAGED_LIVE);
    log.push('installed Codex managed hooks policy');
  } catch (e) {
    log.push(`could not install Codex managed hooks policy (${e?.code || 'error'})`);
  }
  return log;
}

// Named exports for unit testing (pure helpers — no side effects on import).
export { localPushed, repoState, checkLocalRepos, warnOtherBox, codexManagedPolicyState };

// ── Main ─────────────────────────────────────────────────────────────────────
// Only run the drift report when executed directly, not when imported by a test.
const IS_MAIN = (() => {
  try {
    const here = path.resolve(new URL(import.meta.url).pathname.replace(/^\/([A-Z]:)/, '$1'));
    const argv1 = process.argv[1] ? path.resolve(process.argv[1]) : '';
    return here === argv1;
  } catch { return true; }
})();

if (IS_MAIN) (async () => {
  // ── SAFETY GATE (MUST run BEFORE any destructive --fix) ────────────────────
  // Compute the local-plane drift gate first and hard-REFUSE --fix while any
  // owned repo has unpushed commits or stashed work. This is the pre-rebuild
  // safety guarantee: a reconcile/rebuild can never run over un-pushed local
  // work. (Previously the gate was computed AFTER fixRdcSkills/fixCodeflow had
  // already run `git reset --hard` — purely advisory, never blocking.)
  const localRepos = checkLocalRepos();
  if (FIX && !localRepos.agree) {
    console.error(`⛔ LOCAL NOT PUSHED — refusing --fix. Unpushed work on: ${(localRepos.unpushed ?? []).join(', ')}. Push or stash-pop before reconciling.`);
    process.exit(1);
  }

  // Pre-rebuild gate: scope the exit code to the local plane only.
  if (GATE_LOCAL_ONLY) {
    if (!localRepos.agree) {
      console.error(`⛔ LOCAL NOT PUSHED — unpushed work on: ${(localRepos.unpushed ?? []).join(', ')}. Push or stash-pop before rebuild.`);
      for (const [k, v] of Object.entries(localRepos.rows)) console.error(`    ${k.padEnd(22)} ${v}`);
      process.exit(1);
    }
    console.error('local-plane gate: OK — no unpushed local work; safe to rebuild.');
    process.exit(0);
  }

  if (FIX) {
    if (!JSON_OUT) console.error('[env-sync] reconciling LOCAL (Carbon7) plane — Vultr/prod are webhook/GitOps-driven and untouched\n');
    const r1 = fixRdcSkills();
    for (const l of r1) console.error(`  rdc-skills: ${l}`);
    const c1 = fixCodeflow();
    for (const l of c1) console.error(`  codeflow:   ${l}`);
    const s1 = fixStartupEnv();
    for (const l of s1) console.error(`  startup:    ${l}`);
    console.error('');
  }

  const comps = [await checkRdcSkills(), await checkCodeflow(), await checkStartupEnv(), localRepos];
  // Cross-box advisory (carbon7). Never affects exit code — warn only.
  const otherBoxWarnings = warnOtherBox();

  if (JSON_OUT) {
    const out = { components: comps, local_repos: localRepos.repos, other_box_warnings: otherBoxWarnings };
    console.log(JSON.stringify(out, null, 2));
    process.exit(comps.every(c => c.agree) ? 0 : 1);
  }

  for (const c of comps) {
    console.error(`${c.agree ? '✓ IN SYNC' : '✗ DRIFT  '}  ${c.name}`);
    for (const [k, v] of Object.entries(c.rows)) console.error(`    ${k.padEnd(38)} ${v ?? '(unreachable)'}`);
    console.error('');
  }
  for (const w of otherBoxWarnings) console.error(`⚠ ${w}`);
  if (otherBoxWarnings.length) console.error('');

  const drift = comps.filter(c => !c.agree).map(c => c.name);
  if (!localRepos.agree) console.error(`⛔ LOCAL NOT PUSHED — unpushed work on: ${(localRepos.unpushed ?? []).join(', ')}. Push or stash-pop before any rebuild.`);
  console.error(drift.length ? `Drift in: ${drift.join(', ')} — run with --fix to reconcile the local plane.` : 'All managed components in sync across source/npm/clone/cache/local/dev.');
  process.exit(drift.length ? 1 : 0);
})();
