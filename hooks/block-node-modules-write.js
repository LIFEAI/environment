#!/usr/bin/env node
// PreToolUse hook — blocks Edit/Write/MultiEdit to any path inside node_modules/.
// Hard rule: NEVER edit node_modules/. Source for @lifeaitools/clauth -> C:/Dev/clauth/.
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
  if (!['Edit', 'Write', 'MultiEdit'].includes(toolName)) {
    process.exit(0);
  }

  // file_path for Write/Edit, path for MultiEdit
  const rawPath = (parsed.tool_input && (parsed.tool_input.file_path || parsed.tool_input.path)) || '';
  const normalised = rawPath.replace(/\\/g, '/');

  if (normalised.includes('/node_modules/') || normalised.startsWith('node_modules/')) {
    const response = {
      decision: 'block',
      reason: [
        '⛔ NODE_MODULES WRITE BLOCKED — NEVER edit node_modules/.',
        '',
        'node_modules/ is managed by pnpm. Manual edits are overwritten on install.',
        '',
        'If you need to patch a package:',
        '  • For @lifeaitools/clauth: edit source at C:/Dev/clauth/, bump version,',
        '    commit/tag, then npm publish. There is no auto-publish webhook.',
        '  • For any other package: use `pnpm patch` or open a PR upstream.',
        '',
        'Never edit node_modules/ directly.'
      ].join('\n')
    };
    process.stdout.write(JSON.stringify(response));
    process.exit(0);
  }

  process.exit(0);
});
