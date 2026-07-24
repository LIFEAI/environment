/**
 * Completion Gate — decision tests (2026-07-09).
 * Proves the gate blocks the three abandonment fingerprints and ignores tooling churn /
 * untracked noise, so it does not false-lock ordinary sessions.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { trackedDirty, hasDeferLanguage, evaluateCompletion, IGNORE_PREFIXES, isSharedMainTree, toRepoRel, gitAddTargets, parseOwnedFiles, stopContinuationOutput } from '../enforce-completion.mjs';

test('trackedDirty flags staged/modified tracked files, ignores untracked + tooling paths', () => {
  const porcelain = [
    ' M .rdc/logs/env-sync/latest.log', // tooling — ignored
    'M  docs/obsidian/systems.md',       // post-commit sync — ignored
    ' M CLAUDE.md',                      // sync-managed — ignored
    '?? output/',                        // untracked — ignored
    '?? .rdc/reports/x.md',              // untracked — ignored
    'A  .codex/CODEX.md',                // staged tracked — BLOCKS
    ' M apps/prt/src/page.tsx',          // modified tracked — BLOCKS
  ].join('\n');
  assert.deepEqual(trackedDirty(porcelain), ['.codex/CODEX.md', 'apps/prt/src/page.tsx']);
});

test('trackedDirty handles rename arrows (takes the new path)', () => {
  assert.deepEqual(trackedDirty('R  old/a.ts -> packages/ui/a.ts'), ['packages/ui/a.ts']);
});

test('a clean-except-tooling tree does NOT block', () => {
  const porcelain = ' M .rdc/logs/env-sync/latest.log\n?? output/\n?? .rdc/reports/pool.md';
  assert.equal(evaluateCompletion({ porcelain, lastText: 'Committed abc123; tsc exit 0.' }).block, false);
});

test('offer-to-defer language BLOCKS', () => {
  for (const t of [
    'Done. Want me to also wire the rest?',
    'Say the word and I\'ll add it.',
    'Next steps: hook up the Codex side.',
    'One optional remainder: the CODEX.md directive.',
    'Shall I proceed with the migration?',
    'Let me know if you\'d like me to continue.',
  ]) {
    assert.equal(hasDeferLanguage(t), true, `should flag defer: ${t}`);
    assert.equal(evaluateCompletion({ lastText: t }).block, true, `should block: ${t}`);
  }
});

test('honest structural completion does NOT trip defer detector', () => {
  for (const t of [
    'Committed 0e9affd1b; core tests exit 0 (15/15). All items in scope are committed.',
    'This is genuinely out of scope: it needs a separate epic and Dave\'s approval.',
    'Blocked: Supabase MCP is down; reported and awaiting reconnect.',
  ]) {
    assert.equal(hasDeferLanguage(t), false, `should NOT flag: ${t}`);
  }
});

test('unchecked required checklist items BLOCK', () => {
  const d = evaluateCompletion({ lastText: 'committed.', pendingChecklist: ['tsc-clean', 'smoke-test'] });
  assert.equal(d.block, true);
  assert.match(d.reasons.join(' '), /checklist/);
});

test('all-clear passes; multiple fingerprints accumulate reasons', () => {
  assert.equal(evaluateCompletion({ porcelain: '?? output/', lastText: 'committed abc.' }).block, false);
  const d = evaluateCompletion({ porcelain: 'A  apps/x/a.ts', lastText: 'want me to finish?', pendingChecklist: ['t1'] });
  assert.equal(d.block, true);
  assert.equal(d.reasons.length, 3);
});

test('unfinished-work Stop gate selects the Codex continuation payload', () => {
  assert.deepEqual(stopContinuationOutput('continue the goal', { turn_id: 'turn-1' }), {
    continue: true,
    systemMessage: 'continue the goal',
  });
});

test('unfinished-work Stop gate selects Claude non-error feedback', () => {
  assert.deepEqual(stopContinuationOutput('continue the goal', { hook_event_name: 'Stop' }), {
    hookSpecificOutput: {
      hookEventName: 'Stop',
      additionalContext: 'continue the goal',
    },
  });
});

test('IGNORE_PREFIXES covers the known tooling churn paths', () => {
  for (const p of ['.rdc/logs/', 'docs/obsidian/', 'CLAUDE.md', '.rdc/knowledge/mdk/', '.rdc/reports/codeflow-screenshots/']) assert.ok(IGNORE_PREFIXES.includes(p));
});

test('MDK index + CodeFlow screenshots do NOT trigger the dirty gate (Codex 5.6 item 7)', () => {
  const porcelain = [
    'M  .rdc/knowledge/mdk/index/claude.md.json',
    ' M .rdc/reports/codeflow-screenshots/foo.png',
    ' M apps/prt/a.ts', // real work — still blocks
  ].join('\n');
  assert.deepEqual(trackedDirty(porcelain), ['apps/prt/a.ts']);
});

// --- Session attribution in the shared main tree (2026-07-12, option-2) -------------

test('isSharedMainTree: main tree true, lane false, subdir/other repo false', () => {
  assert.equal(isSharedMainTree('C:/Dev/regen-root'), true);
  assert.equal(isSharedMainTree('C:\\Dev\\regen-root'), true);   // backslashes
  assert.equal(isSharedMainTree('C:/Dev/regen-root/'), true);    // trailing slash
  assert.equal(isSharedMainTree('C:/Dev/regen-root.wt/claude-1'), false); // lane
  assert.equal(isSharedMainTree('C:/Dev/regen-root.wt/x-codex-2'), false);
  assert.equal(isSharedMainTree('C:/Dev/regen-root/apps/prt'), false);    // subdir → whole-tree
  assert.equal(isSharedMainTree('C:/Dev/other-repo'), false);             // unrelated → whole-tree
});

test('toRepoRel: absolute-inside → relative, outside/other → null, relative passthrough', () => {
  const root = 'C:/Dev/regen-root';
  assert.equal(toRepoRel('C:/Dev/regen-root/apps/prt/a.ts', root), 'apps/prt/a.ts');
  assert.equal(toRepoRel('C:\\Dev\\regen-root\\apps\\prt\\a.ts', root), 'apps/prt/a.ts'); // backslashes
  assert.equal(toRepoRel('apps/prt/a.ts', root), 'apps/prt/a.ts');       // already relative
  assert.equal(toRepoRel('./scripts/x.mjs', root), 'scripts/x.mjs');     // leading ./
  assert.equal(toRepoRel('"apps/prt/a.ts"', root), 'apps/prt/a.ts');     // quoted
  assert.equal(toRepoRel('C:/Dev/regen-root.wt/claude-1/apps/a.ts', root), null); // a lane, not this tree
  assert.equal(toRepoRel('C:/Dev/regen-root', root), null);              // the root itself
  assert.equal(toRepoRel('', root), null);
});

test('gitAddTargets: explicit files harvested, flags/./-A/globs skipped, chains handled', () => {
  assert.deepEqual(gitAddTargets('git add apps/a.ts packages/b.ts'), ['apps/a.ts', 'packages/b.ts']);
  assert.deepEqual(gitAddTargets('git add -A'), []);
  assert.deepEqual(gitAddTargets('git add .'), []);
  assert.deepEqual(gitAddTargets('git add -- apps/a.ts'), ['apps/a.ts']); // -- separator skipped as flag
  assert.deepEqual(gitAddTargets('cd x && git add apps/a.ts && git commit -m y'), ['apps/a.ts']);
  assert.deepEqual(gitAddTargets('echo hi'), []);
});

test('parseOwnedFiles: Edit/Write/MultiEdit paths + git add targets become the owned set', () => {
  const root = 'C:/Dev/regen-root';
  const jsonl = [
    JSON.stringify({ message: { role: 'assistant', content: [
      { type: 'text', text: 'working' },
      { type: 'tool_use', name: 'Write', input: { file_path: 'C:/Dev/regen-root/apps/mine/x.ts' } },
    ] } }),
    JSON.stringify({ message: { role: 'assistant', content: [
      { type: 'tool_use', name: 'Edit', input: { file_path: 'C:/Dev/regen-root/packages/ui/y.ts' } },
      { type: 'tool_use', name: 'Bash', input: { command: 'git add scripts/z.mjs && git commit -m q' } },
    ] } }),
    JSON.stringify({ message: { role: 'user', content: [{ type: 'text', text: 'ignored' }] } }),
    'not json — skipped',
  ].join('\n');
  const owned = parseOwnedFiles(jsonl, root);
  assert.deepEqual([...owned].sort(), ['apps/mine/x.ts', 'packages/ui/y.ts', 'scripts/z.mjs']);
});

test('attribution: in main tree, a neighbor\'s WIP is filtered out; own file still blocks', () => {
  const porcelain = ' M apps/neighbor/parallel.tsx\n M apps/mine/x.ts';
  const owned = new Set(['apps/mine/x.ts']);
  // Neighbor-only owned set → neighbor file suppressed, own file blocks.
  const d1 = evaluateCompletion({ porcelain, lastText: 'committed.', attributeToSession: true, ownedFiles: new Set(['apps/mine/x.ts']) });
  assert.equal(d1.block, true);
  assert.match(d1.reasons[0], /apps\/mine\/x\.ts/);
  assert.doesNotMatch(d1.reasons[0], /parallel\.tsx/);
  // Session owned NOTHING dirty → no block despite a neighbor's WIP.
  const d2 = evaluateCompletion({ porcelain: ' M apps/neighbor/parallel.tsx', lastText: 'committed.', attributeToSession: true, ownedFiles: new Set() });
  assert.equal(d2.block, false);
  void owned;
});

test('attribution OFF (lane) or owned=null (unreadable transcript) → whole-tree unchanged', () => {
  const porcelain = ' M apps/neighbor/parallel.tsx';
  // Lane: attributeToSession false → whole-tree still blocks.
  assert.equal(evaluateCompletion({ porcelain, lastText: 'committed.' }).block, true);
  // Main tree but null owned set (parse miss) → fall back to whole-tree, still blocks.
  assert.equal(evaluateCompletion({ porcelain, lastText: 'committed.', attributeToSession: false, ownedFiles: null }).block, true);
});
