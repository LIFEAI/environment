#!/usr/bin/env node
/**
 * Codex PreToolUse — consolidated safety guards (2026-07-11).
 * Codex ran NONE of Claude's 11 block-* guards. This reimplements the highest-value
 * dangerous-command blocks in CODEX's tool shape (tool_name shell/exec_command; command in
 * tool_input.command/cmd/script; file in file_path/path). Wired via managed requirements.toml
 * PreToolUse so it enforces in every lane without a trust prompt.
 * Exit 2 + stderr = block (Codex feeds the reason back to the model). Kill-switch: CODEX_GUARDS=0.
 */
import { readFileSync } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

function parsePowershellRemoveItem(cmd = '') {
  const text = String(cmd).trim();
  if (text.startsWith('*** Begin Patch')) return null;
  const match = text.match(/^(?:powershell|pwsh)(?:\.exe)?\s+-Command\s+(.+)$/i);
  const command = match ? match[1].trim().replace(/^['"]|['"]$/g, '') : text;
  if (!/(^|[;&]\s*)Remove-Item\b/i.test(command)) return null;
  const recursive = /\s-(?:Recurse|r)\b/i.test(command);
  const literal = command.match(/\s-LiteralPath\s+(?:"([^"]+)"|'([^']+)'|([^\s;|&]+))/i);
  const pathArg = literal?.[1] ?? literal?.[2] ?? literal?.[3] ?? null;
  const broad = !literal
    || recursive
    || /\$\(|\*|\?/.test(command)
    || /\s-Path\s/i.test(command)
    || (pathArg ? isBroadDeleteTarget(pathArg) : true);
  return { broad, pathArg, recursive, literal: !!literal };
}

function isBroadDeleteTarget(value) {
  const p = String(value || '').trim().replace(/^["']|["']$/g, '').replace(/\\/g, '/');
  return !p
    || p === '/'
    || /^[A-Za-z]:\/?$/.test(p)
    || p === '~'
    || p.startsWith('~/')
    || /^\$(?:HOME|home|CODEX_HOME)\b/.test(p)
    || p === '.'
    || p === '..'
    || p.startsWith('../')
    || p.includes('/../');
}

/** Each rule: (ctx) => reason string to BLOCK, or null to allow. Pure + tested. */
export const RULES = [
  ['push-main', ({ cmd }) => /\bgit\s+push\b/.test(cmd) && /\b(origin\s+)?main\b/.test(cmd)
    ? 'Never push to main. main is production and requires explicit human approval.' : null],
  ['push-force', ({ cmd }) => /\bgit\s+push\b/.test(cmd) && /(--force\b|--force-with-lease|\s-f\b)/.test(cmd)
    ? 'Never force-push.' : null],
  ['no-verify', ({ cmd }) => /\bgit\s+(commit|push)\b/.test(cmd) && /--no-verify\b/.test(cmd)
    ? 'Never skip hooks with --no-verify.' : null],
  ['full-build', ({ cmd }) => (/\b(pnpm|npm|yarn)\s+(run\s+)?build\b/.test(cmd) || /\bturbo\s+(run\s+)?build\b/.test(cmd))
    && !/--filter|\s-F\b|--scope/.test(cmd)
    ? 'No full monorepo build. Use `pnpm --filter @regen/<app> build` or `npx tsc --noEmit`.' : null],
  ['rm-rf-danger', ({ cmd }) => /\brm\s+-[a-zA-Z]*\b/.test(cmd) && /\brm\s+-[a-zA-Z]*(rf|fr)[a-zA-Z]*\b/.test(cmd)
    && /(\s\/(\s|$)|\s~(\s|\/|$)|\s\$HOME\b|\s\*(\s|$)|\s\.\.(\s|\/|$))/.test(cmd)
    ? 'Refusing a destructive `rm -rf` against a root/home/glob/parent target.' : null],
  ['remove-item-danger', ({ cmd }) => {
    const remove = parsePowershellRemoveItem(cmd);
    return remove?.broad
      ? 'Refusing broad PowerShell Remove-Item. Use explicit non-recursive `Remove-Item -LiteralPath <single file> -Force` only.'
      : null;
  }],
  ['node-modules-write', ({ file }) => file && file.replace(/\\/g, '/').includes('/node_modules/')
    ? 'Do not write into node_modules/. Edit the source package instead.' : null],
  ['coolify-direct', ({ cmd }) => /deploy\.regendevcorp\.com\/api\//.test(cmd)
    ? 'No direct Coolify REST calls. All deploys go through /rdc:deploy.' : null],
  ['reset-hard-pool', ({ cmd, cwd }) => /\bgit\s+reset\s+--hard\b/.test(cmd) && /regen-root\.wt[\\/]/.test(cwd || '')
    ? 'git reset --hard in a pool/lane worktree can destroy unrecovered work — stash/branch first.' : null],
];

/** Pure decision — exported for tests. */
export function evaluateGuard(ctx) {
  for (const [name, fn] of RULES) {
    const reason = fn(ctx || {});
    if (reason) return { block: true, rule: name, reason };
  }
  return { block: false };
}

function normalize(input) {
  const ev = input.event && typeof input.event === 'object' ? input.event : input;
  const toolName = String(ev.tool_name || ev.toolName || ev.name || input.tool_name || '').toLowerCase();
  const ti = ev.tool_input || ev.toolInput || input.tool_input || {};
  const cmd = String(ti.command || ti.cmd || ti.script || ti.input || '');
  const file = ti.file_path || ti.path || ti.filename || ti.uri || '';
  const cwd = input.cwd || ev.cwd || process.cwd();
  return { toolName, cmd, file: String(file || ''), cwd };
}

function main() {
  if (process.env.CODEX_GUARDS === '0') process.exit(0);
  let input = {};
  try { input = JSON.parse(readFileSync(0, 'utf8')); } catch { process.exit(0); }
  const ctx = normalize(input);
  const v = evaluateGuard(ctx);
  if (v.block) {
    // Codex PreToolUse does NOT deny on exit 2 (that only blocks Stop). It honors the JSON
    // permissionDecision wire format. Emit deny (both key shapes for engine portability) AND
    // stderr; exit 0 so Codex reads the JSON. Verified: exit-2 alone let `pnpm build` run.
    process.stderr.write(`🛑 CODEX GUARD [${v.rule}]: ${v.reason}\n`);
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'deny',
        permissionDecisionReason: `CODEX GUARD [${v.rule}]: ${v.reason}`,
      },
      decision: 'block',
      reason: `CODEX GUARD [${v.rule}]: ${v.reason}`,
    }));
    process.exit(0);
  }
  process.exit(0);
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) main();
