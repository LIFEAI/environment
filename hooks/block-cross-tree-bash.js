#!/usr/bin/env node
// PreToolUse(Bash) hook — hard-blocks a LANE session from operating on a
// DIFFERENT git worktree via `cd` or `git -C` into the main integration tree
// (or another lane). This is the shell sibling of block-out-of-scope-edit.js's
// cross-tree WRITE guard: a session isolated in .../regen-root.wt/<name> that
// runs `cd C:/Dev/regen-root && git commit ...` commits into the SHARED tree on
// the wrong branch — the recurring "global shitshow". Confine lanes to their
// own tree at the tool layer instead of relying on discipline.
//
// Contract (mirrors the other block-* hooks): read JSON from stdin, print a
// decision to stdout, ALWAYS exit 0 (never exit 2). FAIL-OPEN on every
// ambiguity — only block on an UNAMBIGUOUS cross-tree `cd`/`git -C` target.
//
// Only LANE sessions are confined. The SV/main session (cwd = main tree) and
// any non-repo cwd are exempt — they legitimately operate on the main tree.
'use strict';

// Identify which git tree an absolute path (or cwd) belongs to. `.wt` first so a
// lane path never falls through to the main-tree branch. Returns null for
// anything outside a regen-root tree (relative tokens, other repos, etc.).
function treeRootOf(p) {
  const s = String(p).replace(/\\/g, '/');
  const lane = s.match(/^(.*\/regen-root\.wt\/[^/]+)(?:\/|$)/);
  if (lane) return { kind: 'lane', root: lane[1] };
  const main = s.match(/^(.*\/regen-root)(?:\/|$)/);
  if (main) return { kind: 'main', root: main[1] };
  return null;
}

// Pull candidate path tokens from `cd <path>` and `git ... -C <path>` in a shell
// command string. Heuristic and deliberately conservative — anything it does not
// recognize simply is not flagged (fail-open). Quotes are tolerated; tokens end
// at whitespace or a shell operator.
function crossTreeTargets(cmd, sessionRoot) {
  const targets = [];
  const push = (tok) => {
    if (!tok) return;
    const t = treeRootOf(tok);
    if (t && t.root.toLowerCase() !== sessionRoot.toLowerCase()) targets.push(tok);
  };
  // `cd <path>` — path token immediately after cd.
  let m;
  const cdRe = /\bcd\s+["']?([^\s"'|&;><]+)/g;
  while ((m = cdRe.exec(cmd)) !== null) push(m[1]);
  // `git ... -C <path>` — -C may follow other git global flags before it.
  const gitRe = /\bgit\b[^\n|&;]*?\s-C\s+["']?([^\s"'|&;><]+)/g;
  while ((m = gitRe.exec(cmd)) !== null) push(m[1]);
  return targets;
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

    const offenders = crossTreeTargets(cmd, sessionTree.root);
    if (offenders.length) {
      const response = {
        decision: 'block',
        reason:
          `⛔ CROSS-TREE SHELL BLOCKED — this session runs in the isolated lane ` +
          `${sessionTree.root}, but the command navigates into a DIFFERENT tree ` +
          `(${offenders.join(', ')}). Do NOT 'cd' or 'git -C' into the main tree ` +
          `or another lane — a commit/push from there lands on the wrong branch ` +
          `in the shared tree. Stay inside ${sessionTree.root}; route shared-tree ` +
          `work to the Supervisor cell.`
      };
      process.stdout.write(JSON.stringify(response));
      process.exit(0);
    }

    process.exit(0);
  } catch (_) {
    // FAIL-OPEN on any error — never wedge a legitimate command.
    process.exit(0);
  }
});
