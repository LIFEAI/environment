#!/usr/bin/env node
// PreToolUse(Bash) hook — stops a LANE session from landing on `develop` in an
// UNCOORDINATED way. Worker lanes run isolated in .../regen-root.wt/<name> on
// their own `wt/<lane>` branch, but agent-bootstrap.md historically told them to
// `git push origin develop` — so N lanes raced the same branch, colliding and
// clobbering (autostash conflicts, lost work). The fix is coordination, not a
// wall: this hook blocks the RAW push/checkout of develop from a lane and hands
// back the ONE sanctioned command — `node scripts/land.mjs` — a serialized,
// tsc-gated, auto-rebasing merge-queue that lands safely with no human merge.
//
// Contract (mirrors block-cross-tree-bash.js): read JSON from stdin, print a
// decision to stdout, ALWAYS exit 0. FAIL-OPEN on every ambiguity. Only LANE
// sessions are confined — the SV/main tree lands on develop legitimately.
//
// What is blocked (lane cwd only):
//   - git push ... develop        (any remote/ref form mentioning develop)
//   - git checkout develop        (branch switch — a back-door onto develop)
//   - git switch develop
// What is NOT touched (fail-open):
//   - git push origin wt/<lane>   (pushing your OWN branch — encouraged)
//   - git fetch origin develop / git rebase origin/develop  (land.mjs's own steps)
//   - node scripts/land.mjs       (the sanctioned path — no "git push develop" text)
//   - git checkout develop -- <file>  (path restore, not a branch switch)
'use strict';

// Which git tree does an absolute path (or cwd) belong to? `.wt` first so a lane
// path never falls through to the main-tree branch. null = outside any regen-root
// tree (fail-open).
function treeRootOf(p) {
  const s = String(p).replace(/\\/g, '/');
  const lane = s.match(/^(.*\/regen-root\.wt\/[^/]+)(?:\/|$)/);
  if (lane) return { kind: 'lane', root: lane[1] };
  const main = s.match(/^(.*\/regen-root)(?:\/|$)/);
  if (main) return { kind: 'main', root: main[1] };
  return null;
}

// True when the command is an UNCOORDINATED land onto develop from a lane.
// Deliberately conservative — only unambiguous offenders are flagged.
function offendingReason(cmd) {
  // git push ... develop  — but not a fetch/rebase (those name develop legitimately).
  // Match a push whose argument list contains the develop ref in any form:
  //   git push origin develop | git push origin HEAD:develop | git push -u origin develop
  if (/\bgit\s+push\b[^\n|&;]*\bdevelop\b/.test(cmd)) {
    return 'push';
  }
  // git checkout develop / git switch develop — a branch switch onto develop.
  // Exclude the `-- <path>` restore form (develop followed later by `--`).
  if (/\bgit\s+(?:checkout|switch)\s+develop(?:\s|$)/.test(cmd) && !/\bcheckout\s+develop\s+--/.test(cmd)) {
    return 'checkout';
  }
  return null;
}

let input = '';
process.stdin.resume();
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => { input += c; });
process.stdin.on('end', () => {
  try {
    const parsed = JSON.parse(input);
    if ((parsed.tool_name || '') !== 'Bash') process.exit(0);
    const cmd = parsed.tool_input && parsed.tool_input.command;
    if (!cmd || typeof cmd !== 'string') process.exit(0); // no command → fail-open

    const sessionTree = treeRootOf(process.cwd());
    // Only lane sessions are confined. Main/SV and non-repo cwd → fail-open.
    if (!sessionTree || sessionTree.kind !== 'lane') process.exit(0);

    const kind = offendingReason(cmd);
    if (!kind) process.exit(0);

    const lane = sessionTree.root.split('/').pop();
    const verb = kind === 'push'
      ? `push directly to \`develop\``
      : `check out \`develop\``;

    const response = {
      decision: 'block',
      reason: [
        `⛔ LANE → DEVELOP BLOCKED — do not ${verb} from an isolated lane (${lane}).`,
        '',
        'Multiple lanes racing `develop` collide and clobber each other. Instead,',
        'let the serialized auto-land wrapper land your commits safely — no human,',
        'no manual merge:',
        '',
        '  1. Commit on your own branch:   git commit -am "feat(scope): ..."',
        `  2. (optional) publish the branch: git push origin ${lane}`,
        '  3. Land to develop:             node scripts/land.mjs',
        '',
        '`land.mjs` takes a cross-lane lock, rebases your commits onto the latest',
        'origin/develop, runs a tsc gate, then fast-forward-pushes — so develop can',
        'never be clobbered and stays green. On a genuine content conflict it stops',
        'and reports rather than forcing.',
        '',
        'clauth (separate repo, no worktree): push a feature branch there —',
        'never straight to clauth `develop`/`main`.'
      ].join('\n')
    };
    process.stdout.write(JSON.stringify(response));
    process.exit(0);
  } catch (_) {
    // FAIL-OPEN on any error — never wedge a legitimate command.
    process.exit(0);
  }
});
