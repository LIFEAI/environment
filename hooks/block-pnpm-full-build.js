#!/usr/bin/env node
// PreToolUse hook — blocks `pnpm build` without --filter on the local laptop.
// Hard rule: LOCAL BUILD SAFETY — no full monorepo pnpm build.
// Allowed: `pnpm --filter @regen/ui build` or `pnpm build --filter @regen/ui`
// Schema: write { decision: 'block', reason } to stdout + exit 0.
'use strict';

let input = '';
process.stdin.resume();
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => { input += c; });
process.stdin.on('end', () => {
  let parsed;
  try {
    parsed = JSON.parse(input);
  } catch (_) {
    process.exit(0);
  }

  const toolName = parsed.tool_name || '';
  if (toolName !== 'Bash') {
    process.exit(0);
  }

  const command = (parsed.tool_input && parsed.tool_input.command) || '';

  // Match `pnpm build` only when --filter is NOT present anywhere in the command.
  // This covers:
  //   pnpm build                       → BLOCK
  //   pnpm run build                   → BLOCK
  //   pnpm --filter @regen/ui build    → allow (has --filter)
  //   pnpm build --filter @regen/ui   → allow (has --filter)
  const hasBuild = /\bpnpm\b.*\bbuild\b/.test(command);
  const hasFilter = /--filter\b/.test(command);

  if (hasBuild && !hasFilter) {
    const response = {
      decision: 'block',
      reason: [
        '⛔ FULL MONOREPO BUILD BLOCKED — LOCAL BUILD SAFETY rule.',
        '',
        'Running `pnpm build` without --filter starts ALL apps simultaneously.',
        'This creates too many concurrent Node processes on the local laptop.',
        '',
        'Run only ONE scoped build at a time:',
        '  pnpm --filter @regen/<app> build',
        '',
        'For type-checking only (preferred): npx tsc --noEmit',
        'Do not start another build/test/dev process until the current one exits.'
      ].join('\n')
    };
    process.stdout.write(JSON.stringify(response));
    process.exit(0);
  }

  process.exit(0);
});
