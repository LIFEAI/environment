/** Codex consolidated guards — pure decision tests (2026-07-11). */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { evaluateGuard } from '../../codex/hooks/codex-guards.mjs';

const block = (ctx, rule) => { const v = evaluateGuard(ctx); assert.equal(v.block, true, JSON.stringify(ctx)); if (rule) assert.equal(v.rule, rule); };
const allow = (ctx) => assert.equal(evaluateGuard(ctx).block, false, JSON.stringify(ctx));

test('blocks push to main and force-push', () => {
  block({ cmd: 'git push origin main' }, 'push-main');
  block({ cmd: 'git push --force origin develop' }, 'push-force');
  block({ cmd: 'git push -f' }, 'push-force');
  block({ cmd: 'git commit --no-verify -m x' }, 'no-verify');
});

test('blocks full monorepo build, allows filtered', () => {
  block({ cmd: 'pnpm build' }, 'full-build');
  block({ cmd: 'turbo run build' }, 'full-build');
  allow({ cmd: 'pnpm --filter @regen/prt build' });
  allow({ cmd: 'npx tsc --noEmit' });
});

test('blocks dangerous rm -rf targets, allows scoped', () => {
  block({ cmd: 'rm -rf /' }, 'rm-rf-danger');
  block({ cmd: 'rm -rf ~' }, 'rm-rf-danger');
  block({ cmd: 'rm -rf $HOME' }, 'rm-rf-danger');
  allow({ cmd: 'rm -rf ./dist' });
  allow({ cmd: 'rm -rf node_modules/.cache' });
});

test('allows selective PowerShell Remove-Item literal file cleanup only', () => {
  allow({ cmd: 'Remove-Item -LiteralPath C:\\Users\\DaveLadouceur\\.codeflow\\router-health.json -Force' });
  allow({ cmd: 'pwsh.exe -Command "Remove-Item -LiteralPath C:\\Temp\\one-file.tmp -Force"' });
  allow({ cmd: "$p = Join-Path $env:TEMP 'one-file.tmp'; Remove-Item -LiteralPath $p -Force" });
  allow({ cmd: 'rg -n "Remove-Item" scripts .codex .claude' });
  block({ cmd: 'Remove-Item -Path C:\\Temp\\* -Force' }, 'remove-item-danger');
  block({ cmd: 'Remove-Item -LiteralPath C:\\Temp -Recurse -Force' }, 'remove-item-danger');
  block({ cmd: 'Remove-Item -LiteralPath $HOME -Force' }, 'remove-item-danger');
  block({ cmd: 'Remove-Item -LiteralPath C:\\ -Force' }, 'remove-item-danger');
  block({ cmd: 'Remove-Item -LiteralPath ..\\outside.tmp -Force' }, 'remove-item-danger');
});

test('blocks node_modules writes + coolify direct', () => {
  block({ file: 'C:/Dev/regen-root/node_modules/foo/x.js' }, 'node-modules-write');
  block({ cmd: 'curl https://deploy.regendevcorp.com/api/v1/deploy' }, 'coolify-direct');
  allow({ file: 'apps/prt/src/x.ts' });
});

test('blocks git reset --hard only inside a pool worktree', () => {
  block({ cmd: 'git reset --hard HEAD~1', cwd: 'C:/Dev/regen-root.wt/x-codex-2' }, 'reset-hard-pool');
  allow({ cmd: 'git reset --hard HEAD~1', cwd: 'C:/Dev/regen-root' }); // SV main tree not gated by this rule
});

test('allows ordinary commands', () => {
  for (const cmd of ['ls -la', 'git status', 'git push origin wt/x-codex-2', 'node scripts/x.mjs', 'git commit -m "feat: x"']) allow({ cmd });
});
