#!/usr/bin/env node
/**
 * Stop — nudge when a turn changed code but never ran a verification command (2026-07-11).
 * The Truth Gate checks *claims*; this checks the *behavior* best-practice gap: agents commit
 * code without running tsc/tests. If code files changed this session and the transcript shows
 * no tsc/test/vitest/biome/build command, surface a reminder. Advisory by default (exit 0 +
 * additionalContext); set STOP_TEST_GATE=block to make the reminder mandatory
 * while continuing the active goal. Kill-switch: STOP_TEST_GATE=0.
 * Engine-agnostic (transcript reader handles Claude + Codex rollout shapes).
 */
import { readFileSync, existsSync } from 'fs';
import { execSync } from 'child_process';
import path from 'path';
import { fileURLToPath } from 'url';

const VERIFY_RE = /\b(tsc|--noEmit|vitest|jest|mocha|pnpm\s+(-\w+\s+)?test|npm\s+test|yarn\s+test|biome\s+(lint|check)|turbo\s+(run\s+)?test|node\s+--test|playwright)\b/i;
const CODE_RE = /\.(ts|tsx|js|jsx|mjs|cjs)$/;

/** Pure: should we nudge? Exported for tests. */
export function needsNudge({ changedCode = 0, transcriptText = '' }) {
  if (changedCode <= 0) return false;
  return !VERIFY_RE.test(transcriptText);
}

/** Engine-specific Stop-hook continuation payload. */
export function stopNudgeOutput(message, input = {}) {
  const reminder = `Reminder: ${message}`;
  if (Object.hasOwn(input, 'turn_id')) return { continue: true, systemMessage: reminder };
  return {
    hookSpecificOutput: {
      hookEventName: input.hook_event_name === 'SubagentStop' ? 'SubagentStop' : 'Stop',
      additionalContext: reminder,
    },
  };
}

/** Read a transcript (Claude {message} or Codex {payload}) into one big text blob incl tool commands. */
function transcriptBlob(p) {
  if (!p || !existsSync(p)) return '';
  const lines = readFileSync(p, 'utf8').split('\n').filter(Boolean);
  const parts = [];
  for (const l of lines) {
    let o; try { o = JSON.parse(l); } catch { continue; }
    const m = o.message ?? o.payload ?? o;
    const c = m?.content;
    if (typeof c === 'string') parts.push(c);
    else if (Array.isArray(c)) for (const part of c) {
      if (part?.type === 'text' || part?.type === 'output_text') parts.push(part.text || '');
      if (part?.type === 'tool_use' || part?.type === 'function_call') parts.push(JSON.stringify(part.input || part.arguments || ''));
    }
  }
  return parts.join('\n');
}

function main() {
  if (process.env.STOP_TEST_GATE === '0') process.exit(0);
  if (process.env.__STOP_NUDGED === '1') process.exit(0); // don't re-fire in the same continuation
  let input = {};
  try { input = JSON.parse(readFileSync(0, 'utf8')); } catch { process.exit(0); }
  if (input.stop_hook_active) process.exit(0); // already in a stop-hook continuation — don't loop
  const repoRoot = input.cwd || process.cwd();
  const blob = transcriptBlob(input.transcript_path || input.transcriptPath);
  let changed = 0;
  try {
    const status = execSync('git status --porcelain', { cwd: repoRoot, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 5000 });
    const uncommitted = status.split('\n').map((l) => l.slice(3).trim()).filter(Boolean);
    let committed = [];
    try {
      const unpushed = execSync('git diff --name-only @{u}..HEAD', { cwd: repoRoot, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 5000 });
      committed = unpushed.split('\n').map((l) => l.trim()).filter(Boolean);
    } catch { /* no upstream tracking branch — only uncommitted changes matter */ }
    const files = new Set([...uncommitted, ...committed]);
    changed = [...files].filter((f) => CODE_RE.test(f) && /^(apps|packages)\//.test(f)).length;
  } catch { /* */ }
  if (!needsNudge({ changedCode: changed, transcriptText: blob })) process.exit(0);

  const msg = `You changed ${changed} code file(s) under apps/|packages/ but no verification command (tsc --noEmit / tests / biome) appears in this turn. Run the scoped check before finishing.`;
  // A required reminder must re-enter the active goal rather than return an
  // exit-code failure that can pause a persisted Codex /goal.
  process.stdout.write(JSON.stringify(stopNudgeOutput(msg, input)));
  process.exit(0);
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) main();
