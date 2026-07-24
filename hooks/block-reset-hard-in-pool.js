#!/usr/bin/env node
// PreToolUse hook — blocks reintroducing `git reset --hard` into the lane-sync scripts.
//
// WHY: on 2026-07-05 a `git reset --hard origin/develop` in wt-pool.mjs `ensureFresh`
// silently destroyed committed-but-unlanded lane work (claude-8 rdc-website feature,
// x-codex-1 codeflow fix). The sanctioned lane-sync primitive is
// `syncLaneToOriginDevelop` (rebase --autostash, never reset). This guard keeps
// `reset --hard` from creeping back into either sync point. (review WP-1 guardrail.)
//
// Scope: ONLY the two pool-sync scripts. Any other file may use reset --hard freely.
// Schema: write { decision: 'block', reason } to stdout + exit 0 to block; exit 0 silently to allow.
'use strict';

const GUARDED = ['scripts/wt-pool.mjs', 'scripts/agent-startup-guard.ps1', 'pool/wt-pool.mjs', 'guards/agent-startup-guard.ps1'];
// Matches shell/pwsh `reset --hard` AND the execFileSync array form `'reset', '--hard'`.
const RESET_HARD = /reset['"\s,]+(?:['"])?--hard/;

let input = '';
process.stdin.resume();
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => { input += c; });
process.stdin.on('end', () => {
  let parsed;
  try { parsed = JSON.parse(input); } catch (_) { process.exit(0); }

  const toolName = parsed.tool_name || '';
  if (!['Edit', 'Write', 'MultiEdit'].includes(toolName)) process.exit(0);

  const ti = parsed.tool_input || {};
  const rawPath = (ti.file_path || ti.path || '').replace(/\\/g, '/');
  if (!GUARDED.some((g) => rawPath.endsWith(g))) process.exit(0);

  // Gather the text this edit would INTRODUCE.
  let added = '';
  if (typeof ti.content === 'string') added += ti.content;              // Write
  if (typeof ti.new_string === 'string') added += '\n' + ti.new_string; // Edit
  if (Array.isArray(ti.edits)) added += '\n' + ti.edits.map((e) => e && e.new_string || '').join('\n'); // MultiEdit

  if (RESET_HARD.test(added)) {
    process.stdout.write(JSON.stringify({
      decision: 'block',
      reason: [
        '⛔ `git reset --hard` BLOCKED in the lane-sync path.',
        '',
        `${rawPath} is a pool lane-sync script. reset --hard here silently DESTROYS`,
        'committed-but-unlanded lane work (2026-07-05 incident: claude-8, x-codex-1).',
        '',
        'Use the sanctioned primitive instead:',
        '  syncLaneToOriginDevelop(dir)  // rebase --autostash origin/develop, never resets',
        '  or the CLI:  node scripts/wt-pool.mjs sync-lane <path>',
        '',
        'It fast-forwards behind-only, REPLAYS unlanded commits, autostashes a dirty tree,',
        'and on conflict aborts + surfaces — it never discards work.',
        '',
        'If you genuinely need a hard reset elsewhere, do it in a different file.'
      ].join('\n')
    }));
    process.exit(0);
  }
  process.exit(0);
});
