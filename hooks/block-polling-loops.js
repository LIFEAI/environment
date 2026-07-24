#!/usr/bin/env node
// PreToolUse hook — blocks for/seq/sleep polling loops in Bash commands.
// Hard rule: use Monitor tool or run_in_background; never write polling loops.
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

  // Detect: for <var> in $(seq ...  ... sleep ...
  const pollingLoop = /for\s+\w+\s+in\s+\$\(seq\b[\s\S]{0,200}?\bsleep\b/;

  if (pollingLoop.test(command)) {
    const response = {
      decision: 'block',
      reason: [
        '⛔ POLLING LOOP BLOCKED.',
        '',
        'for/seq/sleep polling loops are not permitted.',
        'Maximum any single sleep/delay: 10 seconds. No multi-minute timers.',
        '',
        'Use instead:',
        '  • Monitor tool — stream deployment events live',
        '  • run_in_background — fire and wait for notification',
        '  • until curl ...; do sleep 2; done — bounded health-wait (no seq) is OK',
        '',
        'Never write for/seq/sleep polling loops.'
      ].join('\n')
    };
    process.stdout.write(JSON.stringify(response));
    process.exit(0);
  }

  process.exit(0);
});
