import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const script = readFileSync(path.resolve(__dirname, '..', 'cell-init.ps1'), 'utf8');

test('codex role is included in automatic worktree isolation', () => {
  assert.match(
    script,
    /\$autoWorktree\s*=\s*\$isCell\s*-or\s*\$Role\s*-eq\s*'codex'/,
  );
  assert.match(script, /if \(\$autoWorktree -or \$Worktree\)/);
  assert.match(script, /\$Role -eq 'codex' -and \$Instance/);
  assert.match(script, /\$Role -eq 'codex'\) \{ 'x-codex' \}/);
});

test('cell-init does not ShellExecute pnpm.ps1 during startup', () => {
  assert.doesNotMatch(script, /Start-Process\s+pnpm\b/i);
  assert.doesNotMatch(script, /Start-Process\s+-FilePath\s+\$pnpm\b/i);
});

test('cell-init delegates worktree creation to wt.mjs only', () => {
  assert.doesNotMatch(script, /git\s+-C\s+\$repo\s+worktree\s+add/i);
  assert.match(script, /node\s+\$wtScript\s+add\s+\$worktreeName/);
});

test('automatic isolated roles fail loud instead of falling back to main', () => {
  assert.match(script, /if \(\$autoWorktree\) \{/);
  assert.match(script, /Refusing to run \$Role in the shared main tree/);
  assert.match(script, /throw "isolated worktree setup failed for \$worktreeName"/);
  assert.doesNotMatch(script, /Cell will run in the SHARED tree/);
});

test('codex role supports isolated resume startup', () => {
  assert.match(script, /\[string\]\$Resume\s*=\s*''/);
  assert.match(script, /codex --cd \$activeRoot .* resume --last/);
  assert.match(script, /codex --cd \$activeRoot .* resume \$Resume/);
});
