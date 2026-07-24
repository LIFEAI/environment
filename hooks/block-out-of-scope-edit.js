#!/usr/bin/env node
// PreToolUse hook — hard-blocks Edit/Write/MultiEdit to paths a scoped worker cell
// does not own. Cell scope is enforced, not discipline-only.
//
// Mirrors block-node-modules-write.js: read JSON from stdin, write a decision to
// stdout, exit 0. NEVER exit 2.
//
// FAIL-OPEN on every ambiguity (missing/unparseable manifest, no path, unknown
// role, glob error): print nothing, exit 0. Block ONLY on a positive `forbidden`
// glob match for a known scoped cell.
//
// Canonical scope source: .claude/context/cell-scope-manifest.json
'use strict';

const fs = require('fs');
const path = require('path');

// Tiny glob matcher supporting `**` (any depth incl zero segments) and `*`
// (any chars within a single path segment). No new npm dependency.
function globToRegExp(glob) {
  // Escape regex metachars except * which we expand ourselves.
  let re = '';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*') {
      if (glob[i + 1] === '*') {
        // `**` — match any number of characters incl path separators.
        // Consume an optional trailing slash so `a/**` also matches `a`.
        i++;
        if (glob[i + 1] === '/') {
          i++;
          re += '(?:.*/)?';
        } else {
          re += '.*';
        }
      } else {
        // single `*` — match within a segment (no slash).
        re += '[^/]*';
      }
    } else if ('\\^$.|?+()[]{}'.includes(c)) {
      re += '\\' + c;
    } else {
      re += c;
    }
  }
  return new RegExp('^' + re + '$');
}

function globMatch(glob, target) {
  try {
    return globToRegExp(glob).test(target);
  } catch (_) {
    return false;
  }
}

// Identify which git tree an absolute path (or cwd) belongs to. Returns
// `{ kind:'lane', root }` for a sibling worktree (.../regen-root.wt/<name>),
// `{ kind:'main', root }` for the main integration tree (.../regen-root), or
// null for anything outside a regen-root tree. The `.wt` case is matched FIRST
// so a lane path never falls through to the main-tree branch.
function treeRootOf(p) {
  const s = String(p).replace(/\\/g, '/');
  const lane = s.match(/^(.*\/regen-root\.wt\/[^/]+)(?:\/|$)/);
  if (lane) return { kind: 'lane', root: lane[1] };
  const main = s.match(/^(.*\/regen-root)(?:\/|$)/);
  if (main) return { kind: 'main', root: main[1] };
  return null;
}

// Strip a leading `.../regen-root.wt/<name>/` or `.../regen-root/` prefix so an
// absolute worktree/main-tree path becomes repo-relative, then canonicalize by
// collapsing `.` / `..` segments. Already-relative paths pass through the same
// canonicalization. Returns the repo-relative POSIX path; a path that escapes
// the repo root via `..` is returned still beginning with `..` so the caller can
// fail-closed for scoped cells.
function toRepoRelative(p) {
  let s = String(p).replace(/\\/g, '/');
  // worktree prefix: .../regen-root.wt/<name>/
  const wt = s.match(/^.*\/regen-root\.wt\/[^/]+\/(.+)$/);
  if (wt) s = wt[1];
  else {
    // main-tree prefix: .../regen-root/
    const main = s.match(/^.*\/regen-root\/(.+)$/);
    if (main) s = main[1];
  }
  // strip a leading ./ if present
  s = s.replace(/^\.\//, '');
  // Canonicalize `.`/`..` segments so traversal cannot defeat the globs.
  // path.posix.normalize collapses interior `..`; a leading `..` that escapes
  // the repo root is preserved (e.g. `../x` stays `../x`).
  let norm = path.posix.normalize(s);
  // normalize may yield a trailing slash for dir-like inputs; drop it.
  if (norm.length > 1 && norm.endsWith('/')) norm = norm.slice(0, -1);
  return norm;
}

// True when a canonicalized repo-relative path escapes the repo root, i.e. it
// still resolves above the root via `..`. These are `..` exactly, `../...`, or
// `..\...`-derived paths.
function escapesRepoRoot(rel) {
  return rel === '..' || rel.startsWith('../');
}

// Resolve the active cell role: env var → cwd inference → unknown (_default).
function resolveRole() {
  const env = process.env.CELL_ROLE;
  if (env && env.trim()) return env.trim();

  const cwd = process.cwd().replace(/\\/g, '/');
  // worktree: .../regen-root.wt/<name>
  const wt = cwd.match(/\/regen-root\.wt\/([^/]+)/);
  if (wt) {
    const name = wt[1];
    // warm-pool slots (claude-N / x-codex-N) → default; x-codex → codex
    if (/^claude-\d+$/.test(name) || /^x-codex-\d+$/.test(name)) return '_default';
    if (name === 'x-codex') return 'codex';
    return name; // e.g. cell-portal → cell-portal
  }
  // main integration tree: .../regen-root (no .wt)
  if (/\/regen-root$/.test(cwd)) return 'sv';

  return '_default';
}

let input = '';
process.stdin.resume();
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => { input += c; });
process.stdin.on('end', () => {
  try {
    const parsed = JSON.parse(input);

    const toolName = parsed.tool_name || '';
    if (!['Edit', 'Write', 'MultiEdit'].includes(toolName)) {
      process.exit(0);
    }

    const rawPath =
      (parsed.tool_input && (parsed.tool_input.file_path || parsed.tool_input.path)) || '';
    if (!rawPath) process.exit(0); // no path → fail-open

    // ── Tree-boundary enforcement (ALL sessions, independent of cell role) ──
    // A session running inside a lane worktree (.../regen-root.wt/<name>) may
    // only write files inside THAT SAME lane. An absolute write into the main
    // integration tree — or into another lane's worktree — is how an isolated
    // lane silently corrupts the shared tree (the recurring failure mode). This
    // check is role-independent on purpose: warm-pool lanes (claude-N/x-codex-N)
    // resolve to the full-access `_default` role, so package-scope alone would
    // never confine them. Relative paths resolve within the lane cwd and carry
    // no tree prefix → treeRootOf(rawPath) is null → not blocked here (the safe
    // pattern). The SV/main session (cwd = main tree) is never a lane → exempt.
    const sessionTree = treeRootOf(process.cwd());
    if (sessionTree && sessionTree.kind === 'lane') {
      const targetTree = treeRootOf(rawPath);
      if (targetTree && targetTree.root.toLowerCase() !== sessionTree.root.toLowerCase()) {
        const response = {
          decision: 'block',
          reason:
            `⛔ CROSS-TREE WRITE BLOCKED — this session runs in the isolated lane ` +
            `${sessionTree.root}, but the write targets a DIFFERENT tree ` +
            `(${targetTree.root}). Lanes must only edit files inside their own ` +
            `worktree. Use a path under ${sessionTree.root}/ (or a relative path) ` +
            `and never edit the main tree from a lane. Route shared-tree work to ` +
            `the Supervisor cell.`
        };
        process.stdout.write(JSON.stringify(response));
        process.exit(0);
      }
    }

    const target = toRepoRelative(rawPath);

    const role = resolveRole();

    // Load manifest relative to this hook file: .claude/hooks → repo root.
    const manifestPath = path.resolve(__dirname, '..', 'context', 'cell-scope-manifest.json');
    const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));

    const roleEntry = manifest[role] || manifest._default;
    if (!roleEntry || !Array.isArray(roleEntry.forbidden) || roleEntry.forbidden.length === 0) {
      process.exit(0); // full-access role → fail-open
    }

    // Fail-CLOSED: a scoped cell whose canonicalized target escapes the repo root
    // via `..` cannot be proven in-scope — block it. (Full-access roles already
    // returned above, so reaching here means this IS a scoped cell.)
    if (escapesRepoRoot(target)) {
      const response = {
        decision: 'block',
        reason:
          `⛔ OUT-OF-SCOPE EDIT BLOCKED — ${target} escapes the repo root via ` +
          `path traversal (..) and cannot be proven in-scope for cell ${role}. ` +
          `Route this change to the Supervisor/Infra cell.`
      };
      process.stdout.write(JSON.stringify(response));
      process.exit(0);
    }

    const blocked = roleEntry.forbidden.some(glob => globMatch(glob, target));
    if (blocked) {
      const response = {
        decision: 'block',
        reason:
          `⛔ OUT-OF-SCOPE EDIT BLOCKED — ${target} is infra/SV-only — ` +
          `you are in cell ${role}. Route this change to the Supervisor/Infra cell.`
      };
      process.stdout.write(JSON.stringify(response));
      process.exit(0);
    }

    process.exit(0);
  } catch (_) {
    // FAIL-OPEN on any error — never wedge a legitimate edit.
    process.exit(0);
  }
});
