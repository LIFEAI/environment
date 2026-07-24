#!/usr/bin/env node
/**
 * PermissionRequest — safety backstop + audit (2026-07-11).
 * Defense-in-depth at the permission layer: if a catastrophic command somehow reaches a
 * permission prompt, DENY it (in addition to the PreToolUse guards). Everything else is left
 * to the normal permission flow (no decision emitted). All requests logged for audit.
 * Claude PermissionRequest + Codex PermissionRequest (managed). Kill-switch: PERM_BACKSTOP=0.
 */
import { readFileSync, appendFileSync, mkdirSync } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { evaluateGuard } from '../codex/hooks/codex-guards.mjs';

function normalize(input) {
  const ev = input.event && typeof input.event === 'object' ? input.event : input;
  const ti = ev.tool_input || ev.toolInput || input.tool_input || {};
  return {
    toolName: String(ev.tool_name || input.tool_name || '').toLowerCase(),
    cmd: String(ti.command || ti.cmd || ti.script || ''),
    file: String(ti.file_path || ti.path || ''),
    cwd: input.cwd || process.cwd(),
  };
}

function main() {
  if (process.env.PERM_BACKSTOP === '0') process.exit(0);
  let input = {};
  try { input = JSON.parse(readFileSync(0, 'utf8')); } catch { process.exit(0); }
  const ctx = normalize(input);
  const v = evaluateGuard(ctx);
  try {
    const dir = path.join(ctx.cwd, '.rdc', 'logs');
    mkdirSync(dir, { recursive: true });
    appendFileSync(path.join(dir, 'permission-requests.jsonl'),
      JSON.stringify({ ts: new Date().toISOString(), tool: ctx.toolName, denied: v.block, rule: v.rule || null }) + '\n');
  } catch { /* */ }
  if (v.block) {
    // Emit both deny shapes: Claude's decision.behavior AND permissionDecision (Codex, which
    // needs the JSON wire form — same reason PreToolUse exit-2 is ignored there). Inert in
    // headless codex exec (no prompts; codex-guards covers PreToolUse denial), but correct if
    // an interactive Codex session raises a PermissionRequest.
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PermissionRequest',
        decision: { behavior: 'deny' },
        permissionDecision: 'deny',
        permissionDecisionReason: `Backstop-denied [${v.rule}]: ${v.reason}`,
      },
      decision: 'deny',
      reason: `Backstop-denied [${v.rule}]: ${v.reason}`,
    }));
  }
  process.exit(0);
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) main();
