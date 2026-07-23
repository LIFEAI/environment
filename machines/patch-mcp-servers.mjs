#!/usr/bin/env node
/**
 * patch-mcp-servers.mjs — idempotent MCP-registration patcher for one box.
 *
 * Part of the startup-environment subscript set (called by env-sync.mjs --fix,
 * runnable standalone). Each subscript patches ONE concern and is safe to run
 * every time. This one keeps the local Claude Code MCP registry clean.
 *
 * THE PROBLEM IT PREVENTS (2026-06-14): `clauth` and `gws` were registered in
 * the `local` scope pointed at `http://127.0.0.1:52437/clauth` and `/gws`. The
 * clauth daemon on 52437 serves `/ping`, `/v/<service>`, `/list-services` — it
 * does NOT serve `/clauth` or `/gws` as MCP transports. So Claude Code reported
 * "clauth: Failed to connect" / "gws: Failed to connect" on every startup — a
 * false alarm, because the real surfaces (the claude.ai connectors) were fine.
 *
 * This patcher removes those known-bad local registrations. It is a CLEANUP
 * patcher by design: it only removes registrations it can prove are wrong (an
 * MCP server pointed at a daemon path that is not an MCP transport). It does NOT
 * invent canonical `claude mcp add` entries — the authoritative endpoint set
 * lives with the connector config, and guessing endpoints would violate the
 * "never guess infra" rule.
 *
 * Idempotent: removing an absent server is a no-op; re-running changes nothing.
 *
 * Usage:
 *   node scripts/dev-setup/patch-mcp-servers.mjs           # apply
 *   node scripts/dev-setup/patch-mcp-servers.mjs --check    # report only, exit 1 if a bad reg exists
 *   node scripts/dev-setup/patch-mcp-servers.mjs --json
 */
import { execSync } from 'node:child_process';

const CHECK = process.argv.includes('--check');
const JSON_OUT = process.argv.includes('--json');

// Known-bad registrations: an MCP server name registered against the clauth
// daemon's non-MCP base. Any registration whose URL matches one of these is a
// false-failure source and must be removed. (scope, name) pairs are removed
// defensively across the scopes Claude Code supports.
const DAEMON_BASE = 'http://127.0.0.1:52437';
const BAD = [
  { name: 'clauth', badUrlIncludes: `${DAEMON_BASE}/clauth` },
  { name: 'gws', badUrlIncludes: `${DAEMON_BASE}/gws` },
];
const SCOPES = ['local', 'project', 'user'];

function sh(cmd) {
  try { return execSync(cmd, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 20_000 }).trim(); }
  catch (e) { return e.stdout ? String(e.stdout).trim() : null; }
}

// `claude mcp get <name>` prints the resolved server incl. its URL + scope.
// We use it to detect whether a name currently resolves to the bad daemon URL.
function getServer(name) {
  return sh(`claude mcp get ${name}`) ?? '';
}

const actions = [];
let foundBad = false;

for (const { name, badUrlIncludes } of BAD) {
  const info = getServer(name);
  const hasBad = info.includes(badUrlIncludes);
  if (!hasBad) {
    actions.push({ name, status: 'clean', detail: 'no daemon-path registration' });
    continue;
  }
  foundBad = true;
  if (CHECK) {
    actions.push({ name, status: 'BAD', detail: `registered at ${badUrlIncludes}` });
    continue;
  }
  // Remove from every scope that might hold the bad entry. Absent scope = no-op.
  const removed = [];
  for (const scope of SCOPES) {
    const out = sh(`claude mcp remove ${name} -s ${scope}`);
    if (out && /Removed/i.test(out)) removed.push(scope);
  }
  actions.push({ name, status: removed.length ? 'removed' : 'noop', detail: removed.join(', ') || 'nothing to remove' });
}

const result = { ok: CHECK ? !foundBad : true, found_bad: foundBad, actions };

if (JSON_OUT) {
  console.log(JSON.stringify(result, null, 2));
} else {
  for (const a of actions) console.error(`  mcp ${a.name.padEnd(8)} ${a.status.padEnd(8)} ${a.detail}`);
  if (CHECK && foundBad) console.error('  → run without --check to remove the daemon-path MCP registrations');
}

// In --check, a lingering bad registration is drift (exit 1). In apply mode we
// always exit 0 — removal is best-effort and absence is success.
process.exit(CHECK && foundBad ? 1 : 0);
