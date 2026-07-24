#!/usr/bin/env node
/**
 * PostToolUse — Biome LINT the single changed file (2026-07-11).
 * This repo runs Biome lint-only (biome.json has `formatter: false`, script `biome lint
 * --changed`), so this hook lints — it does NOT auto-write. Best practice: surface lint
 * diagnostics on the just-edited file immediately, as advisory context, so the agent fixes
 * real issues in-loop instead of shipping them.
 * Engine-agnostic (shared stdin contract): wired into Claude + Codex PostToolUse.
 * Never hard-blocks (exit 0) — a linter must not wedge a turn. Kill-switch: env BIOME_HOOK=0.
 */
import { readFileSync } from 'fs';
import { execSync } from 'child_process';
import path from 'path';
import { fileURLToPath } from 'url';

const EDIT_TOOLS = new Set(['Write', 'Edit', 'MultiEdit', 'NotebookEdit']);
const CODE_EXT = new Set(['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.json', '.jsonc', '.css']);
const IGNORE_SEGMENTS = ['node_modules/', '/dist/', '/.next/', '/.turbo/', '/build/', '/out/', '/coverage/'];

/** Pure: the file Biome should touch, or null. Exported for tests. */
export function targetFile(input) {
  if (!input || !EDIT_TOOLS.has(input.tool_name)) return null;
  const ti = input.tool_input || {};
  const fp = ti.file_path || ti.path || ti.notebook_path;
  if (!fp || typeof fp !== 'string') return null;
  const norm = fp.replace(/\\/g, '/');
  if (IGNORE_SEGMENTS.some((s) => norm.includes(s))) return null;
  if (!CODE_EXT.has(path.extname(norm).toLowerCase())) return null;
  return fp;
}

function biomeBin(repoRoot) {
  const bin = process.platform === 'win32' ? 'biome.cmd' : 'biome';
  return path.join(repoRoot, 'node_modules', '.bin', bin);
}

function main() {
  if (process.env.BIOME_HOOK === '0') process.exit(0);
  let input = {};
  try { input = JSON.parse(readFileSync(0, 'utf8')); } catch { process.exit(0); }
  const file = targetFile(input);
  if (!file) process.exit(0);
  const repoRoot = input.cwd || process.cwd();
  const bin = biomeBin(repoRoot);

  // Lint the single changed file; surface diagnostics as advisory context (never block).
  let out = '';
  try {
    out = execSync(`"${bin}" lint --files-ignore-unknown=true --max-diagnostics=10 "${file}"`, {
      cwd: repoRoot, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 8000,
    });
  } catch (e) {
    out = String(e.stdout || '') + String(e.stderr || ''); // biome exits non-zero when it finds issues
  }
  if (/\b(error|warning)\b/i.test(out)) {
    const summary = out.split('\n').filter((l) => /error|warning|━|╳|⚠|lint\//.test(l)).slice(0, 12).join('\n');
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PostToolUse',
        additionalContext: `Biome lint on ${path.basename(file)} reported issues — fix before finishing:\n${summary}`,
      },
    }));
  }
  process.exit(0);
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) main();
