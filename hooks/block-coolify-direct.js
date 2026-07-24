#!/usr/bin/env node
// PreToolUse hook — blocks direct curl calls to Coolify /applications/ endpoints.
// Hard rule: never call Coolify REST API directly; use /rdc:deploy instead.
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

  // Block direct curl to Coolify /applications/ paths (start, restart, deploy, etc.)
  const coolifyDirect = /curl.*deploy\.regendevcorp\.com.*\/applications\//;

  if (coolifyDirect.test(command)) {
    const response = {
      decision: 'block',
      reason: [
        '⛔ DIRECT COOLIFY REST CALL BLOCKED.',
        '',
        'Never call /applications/<uuid>/start|restart|deploy directly.',
        'Direct API calls bypass health checks, cache purge, and progress monitoring.',
        '',
        'Run all deploys through the skill:',
        '  /rdc:deploy <slug>          — dev deploy to PM2',
        '  /rdc:deploy <slug> promote  — production promote (requires Dave go-ahead)',
        '',
        'The skill handles health checks, cache purge, and progress monitoring.'
      ].join('\n')
    };
    process.stdout.write(JSON.stringify(response));
    process.exit(0);
  }

  process.exit(0);
});
