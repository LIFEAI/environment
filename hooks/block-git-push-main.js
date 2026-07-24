#!/usr/bin/env node
// PreToolUse hook — blocks `git push` to `main` and any force-push.
// Hard rule: NEVER auto-commit to `main`. NEVER force-push.
//
// The ONLY sanctioned path to main is `rdc:deploy <slug> promote` (Mode 5 in
// C:/Dev/rdc-skills/skills/deploy/SKILL.md). That path is exempt BY MECHANISM,
// not by an env carve-out: it never raw-pushes main — it opens a PR and
// admin-merges (`gh pr merge --admin`). Any RAW `git push …main` is therefore a
// non-sanctioned mutation and is hard-blocked here, always. (Decision 2026-07-11,
// Dave: keep the raw-push block; no bypass token.)
//
// The promote path additionally MUST back-merge the same change to develop
// (anti-drift guarantee — SKILL.md Mode 5). A promote that lands on main but not
// develop is incomplete; that obligation is enforced in the skill, not this hook.
//
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

  // Block: git push to main (any form: origin main, upstream main, HEAD:main, refs/heads/main)
  const pushToMain = /git\s+push\b.*\bmain\b/;
  // Block: force-push (--force or -f)
  const forcePush = /git\s+push\b.*(--force|\s-f\b)/;

  if (pushToMain.test(command)) {
    const response = {
      decision: 'block',
      reason: [
        '⛔ PUSH TO MAIN BLOCKED — NEVER auto-commit to `main`.',
        '',
        '`main` is production and requires explicit user approval before any push.',
        'All automated work commits to `develop`. Push to `develop`, then open a PR.',
        '',
        'If you need to promote to main: get explicit go-ahead from Dave first.',
        'Never force-push main under any circumstances.'
      ].join('\n')
    };
    process.stdout.write(JSON.stringify(response));
    process.exit(0);
  }

  if (forcePush.test(command)) {
    const response = {
      decision: 'block',
      reason: [
        '⛔ FORCE-PUSH BLOCKED — NEVER force-push.',
        '',
        'Force-pushing rewrites remote history and can destroy teammates\' work.',
        'If you need to update a branch: rebase locally, then push without --force.',
        '',
        'If you believe force-push is truly required: get explicit go-ahead from Dave.',
        'Do not use --force-with-lease as a workaround — it is also blocked by policy.'
      ].join('\n')
    };
    process.stdout.write(JSON.stringify(response));
    process.exit(0);
  }

  process.exit(0);
});
