#!/usr/bin/env node
// PreToolUse hook — blocks credential exposure via echo/cat of /v/ endpoints
// and blocks clauth_inject tool invocation entirely.
// Hard rule: never print clauth /v/<service> to stdout; never use clauth_inject.
// Schema: write { decision: 'block', reason } to stdout + exit 0.
'use strict';

const BLOCK_REASON = [
  '⛔ CREDENTIAL EXPOSURE BLOCKED.',
  '',
  'Never assign /v/<service> output to a variable or echo it to stdout.',
  'Credentials piped to echo/cat are logged in the conversation transcript JSONL.',
  '',
  'Use inline injection instead:',
  '  curl -H "Authorization: Bearer $(curl -s http://127.0.0.1:52437/v/<svc>)" ...',
  '',
  'clauth_inject returns raw credentials into the conversation transcript — never use it.',
  'See AGENTS.md section: Credentials.'
].join('\n');

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

  // Always block clauth_inject regardless of matcher
  if (toolName === 'clauth_inject') {
    process.stdout.write(JSON.stringify({ decision: 'block', reason: BLOCK_REASON }));
    process.exit(0);
  }

  // For Bash only: check echo/cat patterns that expose /v/ credentials
  if (toolName !== 'Bash') {
    process.exit(0);
  }

  const command = (parsed.tool_input && parsed.tool_input.command) || '';

  // Patterns that expose raw /v/<service> output:
  //   echo $(curl -s .../v/cloudflare)
  //   cat <(curl -s .../v/...)
  //   curl .../v/... | echo
  //   curl .../v/... | cat
  const exposurePatterns = [
    /echo\s.*52437\/v\//,
    /\bcat\b.*52437\/v\//,
    /curl.*52437\/v\/.*\|\s*(echo|cat)\b/
  ];

  for (const pattern of exposurePatterns) {
    if (pattern.test(command)) {
      process.stdout.write(JSON.stringify({ decision: 'block', reason: BLOCK_REASON }));
      process.exit(0);
    }
  }

  process.exit(0);
});
