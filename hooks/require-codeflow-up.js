#!/usr/bin/env node
/**
 * PreToolUse hook (matcher "*") — HARD COLD-STOP when CodeFlow is DOWN.
 *
 * Directive (2026-07-20, Dave): "If CodeFlow is down then everything stops. The
 * grep fallback was ONLY for when CodeFlow returned inadequate/stale results —
 * it was NEVER meant to let a session continue while CodeFlow is DOWN. No more
 * CodeFlow-offline sessions that keep going."
 *
 * Contract:
 *   - "Down" = the LOCAL router (:3109) does not answer `/health`. The response
 *     is a PM2-owned readiness snapshot, so `offline`/`unknown` does not mean
 *     the gateway itself should be restarted.
 *   - PM2 readiness ok/degraded → allow silently. (If the brain is UP but its answer is stale or
 *     unhelpful, the SEPARATE codeflow-preflight hook still lets grep run as a
 *     quality fallback — that path is untouched and correct.)
 *   - Router down → DENY this tool call (any tool: Read/Edit/Bash/Grep/Task/MCP/…).
 *     No hook may spin up a local fallback gateway. Repair must go through the
 *     blue/green controller (`node scripts/codeflow-bluegreen.mjs recover`) or
 *     a read-only diagnostic/probe command.
 *
 * Never-deadlock escape hatches (so the router can always be fixed):
 *   - A Bash command that is itself a CodeFlow blue/green repair or read-only
 *     probe command is allowed through even while down.
 *   - A dedicated CodeFlow fixer session may set CODEFLOW_SELF_REPAIR=1, or a
 *     scoped CodeFlow/hook repair command may carry CODEFLOW_SELF_REPAIR=1.
 *   - CODEFLOW_ENFORCE=0 disables the gate entirely (break-glass).
 *
 * A `deny` from THIS hook overrides any allow/additionalContext from the
 * codeflow-preflight hook (in Claude Code, any PreToolUse deny blocks the tool) —
 * which is exactly the point: down is a stop, not a fallback.
 *
 * Fail-open ONLY on an internal hook bug (never brick the harness on our own
 * exception) — a genuine router-down is fail-CLOSED (deny).
 */
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

const HOOK_REPO_ROOT = path.resolve(__dirname, '..', '..');

function isRepoRoot(candidate) {
  if (!candidate) return false;
  try {
    return fs.existsSync(path.join(candidate, 'scripts', 'codeflow-ensure-up.mjs'))
      && fs.existsSync(path.join(candidate, 'packages', 'codeflow', 'package.json'));
  } catch {
    return false;
  }
}

function resolveRepoRoot() {
  for (const candidate of [process.env.CODEFLOW_REPO_ROOT, process.cwd(), HOOK_REPO_ROOT]) {
    const resolved = candidate ? path.resolve(candidate) : '';
    if (isRepoRoot(resolved)) return resolved;
  }
  return HOOK_REPO_ROOT;
}

const REPO_ROOT = resolveRepoRoot();
const ROUTER = { host: '127.0.0.1', port: 3109, pathname: '/health' };
const CACHE_DIR = path.join(os.homedir(), '.codeflow');
const HEALTH_CACHE = path.join(CACHE_DIR, 'router-health.json');
const HEALTH_TTL_MS = 8000;    // trust a fresh cached health result this long
const PROBE_TIMEOUT_MS = 2000;
const SELF_REPAIR_MARKER = /\bCODEFLOW_(?:SELF_REPAIR|FIXER)=1\b/i;

// Plumbing-independent break-glass. CODEFLOW_ENFORCE / CODEFLOW_SELF_REPAIR set in a
// RUNNING shell never reach this separately-spawned hook process (the 2026-07-21
// deadlock: a per-command `VAR=1 cmd` prefix or PowerShell `$env:VAR` does not propagate
// to the harness-spawned hook). So a mid-session operator/fixer can instead create a
// sentinel FILE — this hook reads it from disk on EVERY invocation, no env plumbing
// required. Any present → gate fully open. Delete it to re-arm. Create with
// `touch .rdc/codeflow-break-glass` (repo) or a file at ~/.codeflow/break-glass (home).
const BREAK_GLASS_FILES = [
  path.join(CACHE_DIR, 'break-glass'),
  path.join(REPO_ROOT, '.rdc', 'codeflow-break-glass'),
];
const PLANNED_DOWNTIME_FILES = [
  process.env.CODEFLOW_UPGRADE_PAUSE_PATH,
  process.env.CODEFLOW_WRITE_OUTBOX_DIR
    ? path.join(path.dirname(path.resolve(process.env.CODEFLOW_WRITE_OUTBOX_DIR)), 'upgrade-pause.json')
    : null,
  process.env.CODEFLOW_WORKSPACE_ROOT?.startsWith('/srv/regen/')
    ? '/srv/regen/codeflow-state/upgrade-pause.json'
    : null,
  path.join(CACHE_DIR, 'upgrade-pause.json'),
  path.join(REPO_ROOT, '.rdc', 'upgrade-pause.json'),
  path.join(CACHE_DIR, 'planned-downtime.json'),
  path.join(REPO_ROOT, '.rdc', 'codeflow-planned-downtime.json'),
].filter(Boolean);
const PLANNED_DOWNTIME_MAX_AGE_MS = 60 * 60 * 1000;
function breakGlassActive() {
  if (process.env.CODEFLOW_ENFORCE === '0') return true; // only if set BEFORE session launch
  for (const f of BREAK_GLASS_FILES) {
    try { if (fs.existsSync(f)) return true; } catch { /* ignore */ }
  }
  return false;
}

function plannedDowntimeActive() {
  for (const f of PLANNED_DOWNTIME_FILES) {
    try {
      if (!fs.existsSync(f)) continue;
      const raw = fs.readFileSync(f, 'utf8').trim();
      if (raw) {
        const state = JSON.parse(raw);
        if (state.active === false || state.paused === false) continue;
        const until = state.until || state.expires_at;
        if (typeof until === 'string' && until.trim()) {
          const untilMs = Date.parse(until);
          if (Number.isFinite(untilMs) && untilMs > Date.now()) return true;
          continue;
        }
      }
      return Date.now() - fs.statSync(f).mtimeMs < PLANNED_DOWNTIME_MAX_AGE_MS;
    } catch {
      /* ignore malformed sentinels */
    }
  }
  return false;
}

// A repair/probe command must pass EVEN WHEN DOWN so the gate never deadlocks its
// own fix. Match the real repair FORMS — a leading repair program, OR an explicit
// reference to the codeflow healer script / the :3109 router URL — rather than any
// command that merely MENTIONS a token (which over-permits, e.g. `echo pm2`).
function isRepairCommand(cmd) {
  const c = stripLeadingEnv(String(cmd || '').trim()).replace(/\\/g, '/');
  if (/[\r\n;&|`]/.test(c) || /\$\(/.test(c)) return false;
  if (/^(?:node|pnpm|npx)\s+(?:\.\/)?scripts\/codeflow-bluegreen\.mjs\b/i.test(c)) return true;
  if (/^(?:curl|wget)\b.*\b(?:127\.0\.0\.1:3109|localhost:3109)\b/i.test(c)) return true;
  if (/^pm2\s+(?:jlist|list|status|describe|info|logs)\b.*\bcodeflow\b/i.test(c)) return true;
  if (/^ssh\b.*\b64\.237\.54\.189\b.*\b(?:codeflow-bluegreen|codeflow.*health|pm2\s+(?:jlist|list|status|describe|info|logs))\b/i.test(c)) return true;
  if (/^clauth\b/i.test(c)) return true;
  if (/^(?:\.\/)?scripts\/restart-clauth\.bat$/i.test(c)) return true;
  return false;
}

function stripLeadingEnv(command) {
  return command.replace(/^\s*(?:[A-Za-z_][\w]*=\S+\s+)*/, '');
}

function normalizeRepoPath(value) {
  const raw = String(value || '').replace(/^["']|["']$/g, '');
  if (!raw) return '';
  const absolute = path.isAbsolute(raw) ? path.resolve(raw) : path.resolve(REPO_ROOT, raw);
  const relative = path.relative(REPO_ROOT, absolute).replace(/\\/g, '/');
  if (relative === '') return '';
  if (relative === '..' || relative.startsWith('../')) return `../${relative}`;
  if (path.isAbsolute(relative)) return `../${relative.replace(/\\/g, '/')}`;
  return relative;
}

function isSelfRepairPath(value) {
  const p = normalizeRepoPath(value).toLowerCase();
  return p === 'hooks/require-codeflow-up.js'
    || p === 'codex/hooks/require-codeflow-up.js'
    || p === 'hooks/__tests__/require-codeflow-up.test.mjs'
    || p === 'codex/hooks.json'
    || p === 'sync/env-sync.mjs'
    || p === '.codex/hooks/require-codeflow-up.js'
    || p === '.claude/hooks/require-codeflow-up.js'
    || p === '.claude/hooks/__tests__/require-codeflow-up.test.mjs'
    || p.startsWith('packages/codeflow/')
    || p === 'scripts/agent-startup-guard.ps1'
    || p === 'scripts/restart-clauth.bat'
    || p.includes('guards/agent-startup-guard.ps1')
    || p.includes('services/restart-clauth.bat')
    || /^scripts\/codeflow[-\w.]*\.mjs$/.test(p);
}

function explicitToolPathTarget(event) {
  const input = event.tool_input || {};
  const values = [
    input.file_path,
    input.path,
    input.notebook_path,
    ...(Array.isArray(input.edits) ? input.edits.map((edit) => edit?.file_path || edit?.path) : []),
  ].filter(Boolean);
  return values.length > 0 && values.every(isSelfRepairPath);
}

function patchTargets(command) {
  const targets = [];
  const re = /^\*\*\* (?:Add|Update|Delete) File: (.+)$/gm;
  for (const m of String(command).matchAll(re)) targets.push(m[1]);
  return targets;
}

function patchTargetsAreSelfRepair(command) {
  if (!String(command || '').startsWith('*** Begin Patch')) return false;
  const targets = patchTargets(command);
  return targets.length > 0 && targets.every(isSelfRepairPath);
}

function isSelfRepairShellCommand(command) {
  const c = stripLeadingEnv(String(command || '').trim()).replace(/\\/g, '/');
  if (patchTargetsAreSelfRepair(c)) return true;
  if (/[\r\n;&|`]/.test(c) || /\$\(/.test(c)) return false;
  if (/^(?:node|pnpm|npx)\s+(?:\.\/)?scripts\/codeflow-bluegreen\.mjs(?:\s+[\w=./:-]+)*$/i.test(c)) return true;
  if (/^node\s+--test\s+\.claude\/hooks\/__tests__\/require-codeflow-up\.test\.mjs$/i.test(c)) return true;
  if (/^pnpm\s+--filter\s+@regen\/codeflow\s+exec\s+vitest\s+run(?:\s+src\/(?:brain\/(?:subsystems|readiness)\.test\.ts|mcp\/server\.test\.ts))+$/i.test(c)) return true;
  if (/^npx\s+tsc\b.*--project\s+packages\/codeflow\/tsconfig\.json\b/i.test(c)) return true;
  if (/^(?:curl|wget)\b.*\b(?:127\.0\.0\.1:3109|localhost:3109)\b/i.test(c)) return true;
  if (/^pm2\s+(?:jlist|list|status|describe|info|logs)\b.*\bcodeflow\b/i.test(c)) return true;
  return false;
}

function isCodeflowSelfRepair(event) {
  const command = `${event.tool_input?.command || ''}\n${event.tool_input?.cmd || ''}`;
  const marked = process.env.CODEFLOW_SELF_REPAIR === '1'
    || process.env.CODEFLOW_FIXER === '1'
    || SELF_REPAIR_MARKER.test(command);
  return marked && (explicitToolPathTarget(event) || isSelfRepairShellCommand(event.tool_input?.command || event.tool_input?.cmd));
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}
function writeJson(file, obj) {
  try { fs.mkdirSync(CACHE_DIR, { recursive: true }); fs.writeFileSync(file, JSON.stringify(obj), 'utf8'); } catch { /* best-effort */ }
}

function probe() {
  return new Promise((resolve) => {
    const req = http.get(
      { hostname: ROUTER.host, port: ROUTER.port, path: ROUTER.pathname, timeout: PROBE_TIMEOUT_MS },
      (res) => {
        let buf = '';
        res.setEncoding('utf8');
        res.on('data', (c) => { buf += c; });
        res.on('end', () => {
          let status = 'unparseable';
          let planned = false;
          try {
            const body = JSON.parse(buf);
            status = body?.status ?? 'no_status';
            planned = body?.upgrade?.paused === true || body?.upgrade?.mode === 'planned_maintenance';
          } catch { /* keep */ }
          resolve({ live: true, ready: status === 'ok' || status === 'degraded', status, planned });
        });
      },
    );
    req.on('error', (e) => resolve({ live: false, ready: false, status: e.code || 'unreachable' }));
    req.on('timeout', () => { req.destroy(); resolve({ live: false, ready: false, status: 'timeout' }); });
  });
}

async function health() {
  const cached = readJson(HEALTH_CACHE);
  if (cached && Date.now() - cached.ts < HEALTH_TTL_MS) {
    const live = typeof cached.live === 'boolean' ? cached.live : !!cached.ok;
    return { live, ready: cached.status === 'ok' || cached.status === 'degraded', status: cached.status, cached: true, planned: cached.planned === true };
  }
  const r = await probe();
  writeJson(HEALTH_CACHE, { ts: Date.now(), live: r.live, ok: r.live, status: r.status, planned: r.planned === true });
  return { ...r, cached: false };
}

function allow() {
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse' } }));
  process.exit(0);
}

function deny(status, gatewayLive = false) {
  const reason = [
    '⛔ CODEFLOW IS DOWN — HARD STOP. This session does not continue while CodeFlow is offline.',
    gatewayLive
      ? `   The local gateway is live; its cached PM2 readiness is status="${status}".`
      : `   Local router :3109 is not responding (status=${status}).`,
    '',
    '   The grep/search fallback exists ONLY for when CodeFlow is UP but returns stale or',
    '   inadequate results — it is NOT a license to keep working while CodeFlow is DOWN.',
    '',
    gatewayLive
      ? '   The gateway was not restarted: a PM2 deep-health fault is not repaired by destroying its pool/cache.'
      : '   No local fallback was started. Stable codeflow-mcp is blue/green-owned.',
    '   Repair lane: use `node scripts/codeflow-bluegreen.mjs recover`; raw pm2 start/restart/delete is denied.',
    '   Break-glass (works mid-session — env vars set in a running shell do NOT reach this hook):',
    '     create a file at  .rdc/codeflow-break-glass  (repo)  or  ~/.codeflow/break-glass  (home) → gate opens; delete it to re-arm.',
    '   (CODEFLOW_ENFORCE=0 only works if exported BEFORE the session launched.)',
  ].join('\n');
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
  }));
  process.exit(0);
}

// Resolve on stdin end/error, parsing whatever buffered. A 5s safety net (well
// under the 8s hook timeout) prevents a hang if `end` never arrives — the old
// fixed 200ms timer raced a slow/large payload and dropped tool_input, which
// could deny a genuine repair command. (review 2026-07-20)
function readEvent() {
  return new Promise((resolve) => {
    let chunks = '';
    let done = false;
    const finish = () => { if (done) return; done = true; try { resolve(JSON.parse(chunks || '{}')); } catch { resolve({}); } };
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (c) => { chunks += c; });
    process.stdin.on('end', finish);
    process.stdin.on('error', finish);
    setTimeout(finish, 5000);
  });
}

function getToolName(event) {
  return String(event?.tool_name || event?.toolName || event?.tool || event?.name || event?.recipient_name || '');
}

function getToolInput(event) {
  const input = event?.tool_input || event?.toolInput || event?.input || event?.arguments || event?.args || {};
  return input && typeof input === 'object' ? input : {};
}

function isReadOnlyShellCommand(cmd) {
  const c = stripLeadingEnv(String(cmd || '').trim()).replace(/\\/g, '/');
  if (!c) return false;
  if (/[\r\n;&|`<>]/.test(c) || /\$\(/.test(c)) return false;
  return /^(?:rg|grep|cat|head|tail|sed|awk|find|ls|dir|pwd|Get-Content|Select-String|Get-ChildItem|Get-Location)\b/i.test(c)
    || /^git\s+(?:status|diff|log|show|branch)\b/i.test(c);
}

function isPlannedFallbackTool(event) {
  const toolName = getToolName(event).toLowerCase();
  const input = getToolInput(event);
  if (!toolName) return false;
  if (
    toolName === 'read'
    || toolName.endsWith('.read')
    || toolName.includes('read_mcp_resource')
    || toolName === 'grep'
    || toolName === 'glob'
    || toolName.includes('search')
    || toolName === 'webfetch'
    || toolName === 'websearch'
  ) return true;
  if (
    toolName === 'bash'
    || toolName === 'shell'
    || toolName === 'shell_command'
    || toolName.includes('shell_command')
    || toolName.includes('exec_command')
  ) {
    return isReadOnlyShellCommand(input.command || input.cmd || input.script);
  }
  return false;
}

function plannedDecision(event, status) {
  const ctx = `[codeflow PLANNED-DOWNTIME] CodeFlow is intentionally paused/down for a planned upgrade (status=${status}); use grep/direct file-tree reads until /health reports accepting work again.`;
  if (isPlannedFallbackTool(event)) {
    process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', additionalContext: ctx } }));
  } else {
    const toolName = getToolName(event) || 'tool';
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'deny',
        permissionDecisionReason: `${ctx} ${toolName} is deferred during planned downtime; retry write/edit work after CodeFlow resumes.`,
      },
    }));
  }
  process.exit(0);
}

async function run() {
  if (breakGlassActive()) return allow(); // break-glass
  const event = await readEvent();
  const toolName = getToolName(event);

  // Always exempt the CodeFlow tools themselves (MCP codeflow_* etc.) so the agent
  // can still diagnose/heal the brain while it is down.
  if (/codeflow/i.test(toolName)) return allow();

  // Escape hatch: a Bash command that repairs/probes CodeFlow itself must pass
  // even when down, or the gate deadlocks its own fix.
  if (isCodeflowSelfRepair(event)) return allow();
  if (toolName === 'Bash' && isRepairCommand(event.tool_input?.command)) return allow();
  if (plannedDowntimeActive()) return plannedDecision(event, 'sentinel');

  const h = await health();
  if (h.planned) return plannedDecision(event, h.status);
  if (h.ready) return allow();

  // A responsive gateway with an unhealthy PM2 snapshot must not be restarted.
  // Restarting destroys shared pool/cache state and cannot repair a deep probe;
  // the correct recovery remains blue/green repair or rehydration.
  if (h.live) {
    return deny(h.status, true);
  }

  return deny(h.status);
}

run().catch(() => {
  // Fail-open ONLY on an internal hook bug — never brick the harness on our own error.
  try { process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse' } })); } catch { /* noop */ }
  process.exit(0);
});
