#!/usr/bin/env node
/**
 * PreCompact — snapshot volatile session state before context compaction (2026-07-11).
 * Compaction re-injects CLAUDE.md but NOT .claude/rules/ or in-flight work state, so an
 * agent can "forget" the active branch, uncommitted files, and which rules applied. This
 * writes a snapshot that compact-restore.mjs re-injects on the post-compact SessionStart.
 * Engine-agnostic: Claude PreCompact + Codex PreCompact (managed). Never blocks (exit 0).
 */
import { readFileSync, writeFileSync, mkdirSync, readdirSync, existsSync } from 'fs';
import { execSync } from 'child_process';
import path from 'path';
import { fileURLToPath } from 'url';

export function snapshotPath(repoRoot, sessionId) {
  const safe = String(sessionId || 'unknown').replace(/[^a-z0-9_-]/gi, '_');
  return path.join(repoRoot, '.rdc', 'compact-snapshots', `${safe}.md`);
}

/** Pure: render the snapshot markdown. Exported for tests. */
export function renderSnapshot({ branch, changed, commits, rules, trigger, ts }) {
  return [
    `# Compaction snapshot (${trigger || 'auto'}) — ${ts}`,
    '',
    `**Branch:** ${branch || '(unknown)'}`,
    '',
    '**Uncommitted/changed files (do not lose these):**',
    ...(changed && changed.length ? changed.slice(0, 40).map((f) => `- ${f}`) : ['- (clean tree)']),
    '',
    '**Recent commits this session:**',
    ...(commits && commits.length ? commits.slice(0, 8).map((c) => `- ${c}`) : ['- (none)']),
    '',
    `**Active .claude/rules/ (NOT auto-re-injected post-compaction — reference by path):** ${rules && rules.length ? rules.join(', ') : '(none found)'}`,
  ].join('\n');
}

function sh(cmd, cwd) { try { return execSync(cmd, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 5000 }).trim(); } catch { return ''; } }

function main() {
  let input = {};
  try { input = JSON.parse(readFileSync(0, 'utf8')); } catch { /* */ }
  const repoRoot = input.cwd || process.cwd();
  const sessionId = input.session_id || input.sessionId || 'unknown';
  const branch = sh('git rev-parse --abbrev-ref HEAD', repoRoot);
  const changed = sh('git status --porcelain', repoRoot).split('\n').map((l) => l.trim()).filter(Boolean).filter((l) => !l.startsWith('??')).map((l) => l.slice(2).trim());
  const commits = sh('git log --oneline -8 --since="12 hours ago"', repoRoot).split('\n').filter(Boolean);
  let rules = [];
  try { rules = readdirSync(path.join(repoRoot, '.claude', 'rules')).filter((f) => f.endsWith('.md')); } catch { /* */ }
  const md = renderSnapshot({ branch, changed, commits, rules, trigger: input.trigger, ts: new Date().toISOString() });
  try {
    const p = snapshotPath(repoRoot, sessionId);
    mkdirSync(path.dirname(p), { recursive: true });
    writeFileSync(p, md + '\n');
  } catch { /* best effort */ }
  process.exit(0);
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) main();
