#!/usr/bin/env node
// PreToolUse hook — blocks RDC_TEST=1 build short-circuit in Bash commands.
// Zero-trust enforcement: the validator gate cannot be bypassed by setting RDC_TEST=1
// from within a live session or agent command.
//
// Approved: option-A — CodeFlow audit FLAG batch remediation. Interview: 2026-05-16 in this session
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

  // Only applies to Bash tool calls
  const toolName = parsed.tool_name || '';
  if (toolName !== 'Bash') {
    process.exit(0);
  }

  const command = (parsed.tool_input && parsed.tool_input.command) || '';

  // Detect RDC_TEST=1 in any form that could short-circuit the build gate
  // Patterns: RDC_TEST=1, export RDC_TEST=1, env RDC_TEST=1 <cmd>, RDC_TEST=1 node ..., etc.
  const shortCircuitPattern = /\bRDC_TEST\s*=\s*1\b/;

  if (shortCircuitPattern.test(command)) {
    const response = {
      decision: 'block',
      reason: [
        '⛔ BUILD GATE BLOCKED — RDC_TEST=1 short-circuit is not permitted in live sessions.',
        '',
        'Setting RDC_TEST=1 bypasses the validator gate. The build short-circuit exists ONLY',
        'for the rdc:build skill\'s internal dry-run self-test (invoked by rdc:self-test).',
        '',
        'If you are running a legitimate self-test: use `/rdc:self-test` — the skill sets',
        'this variable in its own controlled subprocess. Do not set it manually.',
        '',
        'If you are trying to skip the validator gate on a real build: that is not allowed.',
        'The gate exists because skipping it has caused undetected regressions. Run the',
        'full build and let the validator complete.'
      ].join('\n')
    };
    process.stdout.write(JSON.stringify(response));
    process.exit(0);
  }

  process.exit(0);
});
