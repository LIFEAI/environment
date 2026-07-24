#!/usr/bin/env node
/**
 * SessionStart(source=compact) — re-inject the pre-compaction snapshot (2026-07-11).
 * Pairs with precompact-snapshot.mjs. Reads the snapshot for this session and returns it as
 * additionalContext so the post-compaction context regains branch / uncommitted files /
 * active rules. No-op when there is no snapshot (fresh/normal start). Never blocks.
 */
import { readFileSync, existsSync } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { snapshotPath } from './precompact-snapshot.mjs';

function main() {
  let input = {};
  try { input = JSON.parse(readFileSync(0, 'utf8')); } catch { process.exit(0); }
  const source = input.source || input.trigger || '';
  // Only inject on a compaction-driven start (Claude passes source="compact").
  if (source && source !== 'compact') process.exit(0);
  const repoRoot = input.cwd || process.cwd();
  const sessionId = input.session_id || input.sessionId || 'unknown';
  const p = snapshotPath(repoRoot, sessionId);
  if (!existsSync(p)) process.exit(0);
  let md = '';
  try { md = readFileSync(p, 'utf8'); } catch { process.exit(0); }
  if (!md.trim()) process.exit(0);
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'SessionStart',
      additionalContext: `Recovered pre-compaction state (rules are NOT auto-re-injected — re-read any you rely on):\n\n${md}`,
    },
  }));
  process.exit(0);
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) main();
