#!/usr/bin/env node
/**
 * Completion Gate — Stop hook (2026-07-09).
 * Approved: "All three (+ checklist)" + "Hard-refuse + kill-switch". Interview: 2026-07-09.
 * Directive #0 (Dave): finish all work this session; never postpone or END BY OFFERING.
 *
 * A hook cannot read the task's intended scope, so it cannot prove "all work is done". It
 * CAN block the Stop on the observable FINGERPRINTS of abandonment:
 *   1. Orphaned working-tree changes — tracked files modified/staged but uncommitted
 *      (the .codex/CODEX.md failure). Untracked '??' and tooling-managed paths are excluded.
 *   2. Offer-to-defer language in the final assistant message ("want me to…", "shall I…",
 *      "say the word and I'll…", "next steps:", "optional remainder", …).
 *   3. Unchecked REQUIRED checklist items on a work_item this session claimed (best-effort;
 *      fails OPEN if Supabase is unreachable — never wedge on a network blip).
 *
 * Hard-continue: emit a structured Stop continuation while any fingerprint is present.
 * This preserves the gate without pausing a persisted Codex goal. Escapes (always available):
 *   - env COMPLETION_GATE=0                          → disable entirely
 *   - touch .rdc/completion-waivers/<session>.wip    → declare intentional WIP, release once
 *   - commit/stash the tracked changes, remove the defer language, tick the checklist.
 *
 * Session attribution in the SHARED main tree (2026-07-12, Approved: option-2 —
 * "Attribute by tool-log"; interview + Dave delegation this session): the SV/main
 * integration tree (…/regen-root) is a SHARED checkout, so a whole-tree `git status` there
 * flags a PARALLEL session's WIP as THIS session's abandonment (the recurring false
 * positive). When isSharedMainTree(cwd) is true we therefore ATTRIBUTE — keep only
 * tracked-dirty files this session actually owned: its Edit/Write/MultiEdit/NotebookEdit
 * tool paths + explicit `git add` targets (the staged-but-uncommitted .codex/CODEX.md
 * failure mode). If the transcript is unreadable we FALL BACK to whole-tree (never suppress
 * detection on a parse miss). In a lane worktree (…/regen-root.wt/<lane>) the whole tree IS
 * the session's scope, so the check is UNCHANGED there — and whole-tree still catches
 * Bash/script-generated files, the one gap tool-log attribution accepts in the main tree.
 * SV is Claude-only (Codex always runs isolated lanes), so this branch never affects Codex.
 *
 * Stop only (NOT SubagentStop): subagents share the tree and would false-block on the
 * parent's state.
 */
import { readFileSync, existsSync, appendFileSync, mkdirSync } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { execSync } from 'child_process';
import { lastAssistantText } from './truth-gate.mjs';

// Tooling-managed tracked paths that churn on their own (post-commit sync:docs, env logs).
// A change confined to these is NOT unfinished agent work.
export const IGNORE_PREFIXES = [
  '.rdc/logs/',
  'docs/obsidian/',
  '.claude/context/app-deployments.md',
  'CLAUDE.md',
  // Generated/regenerated tracked artifacts that churn without being agent work — flagged by
  // Codex 5.6 review 2026-07-11 as false-positive candidates: the MDK knowledge index (rebuilt
  // from source docs) and committed CodeFlow proof screenshots.
  '.rdc/knowledge/mdk/',
  '.rdc/reports/codeflow-screenshots/',
];

// --- Session attribution (shared main tree only) --------------------------------
// The file-writing tools whose `file_path`/`notebook_path` mark a path as THIS session's.
const EDIT_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit']);

/** True only for the SHARED main integration tree (…/regen-root), NOT a …/regen-root.wt/<lane>. */
export function isSharedMainTree(cwd) {
  const root = String(cwd || '').replace(/\\/g, '/').replace(/\/+$/, '');
  if (/\/regen-root\.wt\//i.test(root + '/')) return false; // a lane worktree — whole-tree is correct there
  return /\/regen-root$/i.test(root);                        // the main tree exactly (a subdir/other repo → false → whole-tree)
}

/** Normalize a tool/`git add` path to a repo-relative POSIX path matching git porcelain output. */
export function toRepoRel(p, repoRoot) {
  if (!p) return null;
  let s = String(p).trim().replace(/^["']+|["']+$/g, '').replace(/\\/g, '/');
  if (!s) return null;
  const root = String(repoRoot || '').replace(/\\/g, '/').replace(/\/+$/, '');
  const isAbs = /^[a-zA-Z]:\//.test(s) || s.startsWith('/');
  if (isAbs) {
    if (!root) return null;
    const sl = s.toLowerCase(), rl = root.toLowerCase();
    if (sl === rl) return null;
    if (sl.startsWith(rl + '/')) s = s.slice(root.length + 1);
    else return null; // absolute path outside this tree → not attributable to it
  }
  s = s.replace(/^\.\//, '').replace(/^\/+/, '');
  if (!s || s.startsWith('..')) return null;
  return s;
}

/** Explicit file targets of any `git add` in a bash command (skips flags, `.`, `-A`, globs). */
export function gitAddTargets(command) {
  const out = [];
  if (!command) return out;
  for (const seg of String(command).split(/\s*(?:&&|\|\||[;|]|>>|>)\s*/)) {
    const m = seg.match(/(?:^|\s)git\s+add\s+(.+)$/);
    if (!m) continue;
    for (const a of m[1].trim().split(/\s+/)) {
      if (!a || a.startsWith('-') || a === '.' || a === '*') continue;
      out.push(a);
    }
  }
  return out;
}

/** Pure: set of repo-relative paths THIS session wrote, parsed from transcript JSONL text. */
export function parseOwnedFiles(transcriptText, repoRoot) {
  const owned = new Set();
  for (const line of String(transcriptText || '').split('\n')) {
    if (!line.trim()) continue;
    let obj; try { obj = JSON.parse(line); } catch { continue; }
    const msg = obj.message ?? obj.payload ?? obj;
    const c = msg?.content;
    if (!Array.isArray(c)) continue;
    for (const part of c) {
      if (part?.type !== 'tool_use') continue;
      const input = part.input || {};
      if (EDIT_TOOLS.has(part.name)) {
        const rel = toRepoRel(input.file_path || input.notebook_path, repoRoot);
        if (rel) owned.add(rel);
      } else if (part.name === 'Bash') {
        for (const t of gitAddTargets(input.command)) {
          const rel = toRepoRel(t, repoRoot);
          if (rel) owned.add(rel);
        }
      }
    }
  }
  return owned;
}

/** Read the transcript and return the owned-file Set, or null if it can't be read (→ caller keeps whole-tree). */
export function sessionOwnedFiles(transcriptPath, repoRoot) {
  if (!transcriptPath || !existsSync(transcriptPath)) return null;
  try { return parseOwnedFiles(readFileSync(transcriptPath, 'utf8'), repoRoot); }
  catch { return null; }
}

// Offer-to-defer phrasing — the "end by offering" anti-pattern Directive #0 forbids.
const DEFER_PATTERNS = [
  /\bwant me to\b/i,
  /\bshall I\b/i,
  /\bwould you like me to\b/i,
  /\bshould I (also |next )?(build|add|do|implement|wire|create|continue|proceed|finish)\b/i,
  /\bI can (also |now )?(build|add|do|implement|wire|create|finish|handle) (it|that|the)\b/i,
  /\blet me know if you(?:'d| would)? (like|want)\b/i,
  /\boptional (remainder|remaining|follow[- ]?up|next step)\b/i,
  /\bnext steps?\s*[:—-]/i,
  /\bif you'?d like,? I\b/i,
  /\bwe could (also |next )\b/i,
  /\bsay the word\b/i,
  /\bremaining (item|work|piece|task)s?\b.*\b(offer|optional|later|if you)\b/i,
];

export function hasDeferLanguage(text) {
  return !!text && DEFER_PATTERNS.some((re) => re.test(text));
}

/** Tracked files that are modified/staged (NOT untracked '??') and not in the ignore list. */
export function trackedDirty(porcelain, ignore = IGNORE_PREFIXES) {
  const out = [];
  for (const line of String(porcelain || '').split('\n')) {
    if (!line.trim()) continue;
    const xy = line.slice(0, 2);
    const file = line.slice(3).trim();
    if (xy === '??') continue;                       // untracked — excluded
    if (!file) continue;
    // Handle rename "old -> new": take the new path.
    const p = file.includes(' -> ') ? file.split(' -> ')[1].trim() : file;
    if (ignore.some((pre) => p.startsWith(pre))) continue;
    out.push(p);
  }
  return out;
}

/** Pure decision — exported for tests. */
export function evaluateCompletion({ porcelain = '', lastText = '', pendingChecklist = [], ignore = IGNORE_PREFIXES, attributeToSession = false, ownedFiles = null } = {}) {
  const reasons = [];
  let dirty = trackedDirty(porcelain, ignore);
  // In the shared main tree, keep only files THIS session owned — a neighbor's WIP is not
  // our abandonment. ownedFiles === null means "could not attribute" → keep whole-tree.
  if (attributeToSession && ownedFiles) {
    const owned = ownedFiles instanceof Set ? ownedFiles : new Set(ownedFiles);
    dirty = dirty.filter((f) => owned.has(f));
  }
  if (dirty.length) {
    reasons.push(`Uncommitted tracked changes (${dirty.length}): ${dirty.slice(0, 8).join(', ')}${dirty.length > 8 ? ', …' : ''}. Commit or stash them, or waive as intentional WIP.`);
  }
  if (hasDeferLanguage(lastText)) {
    reasons.push('Your final message OFFERS to defer work ("want me to…", "shall I…", "say the word…", "next steps:"). Directive #0: do it now, or restate it as a genuine out-of-scope boundary (why it is out of scope), not an offer.');
  }
  if (Array.isArray(pendingChecklist) && pendingChecklist.length) {
    reasons.push(`Required checklist items still unchecked on a claimed work_item: ${pendingChecklist.slice(0, 6).join(', ')}. Complete + tick them, or move the item back to blocked with a reason.`);
  }
  return { block: reasons.length > 0, reasons };
}

/**
 * Engine-specific Stop-hook continuation payload.
 *
 * Codex rejects Claude's hookSpecificOutput object, while Claude ignores
 * Codex's common continuation fields. Codex Stop input always includes the
 * documented turn_id extension; use it to emit exactly one accepted envelope.
 */
export function isCodexStopInput(input = {}) {
  return Object.hasOwn(input, 'turn_id');
}

export function stopContinuationOutput(message, input = {}) {
  if (isCodexStopInput(input)) return { continue: true, systemMessage: message };
  return {
    hookSpecificOutput: {
      hookEventName: input.hook_event_name === 'SubagentStop' ? 'SubagentStop' : 'Stop',
      additionalContext: message,
    },
  };
}

// --- best-effort: required checklist items still open on a work_item THIS session claimed ---
function pendingRequiredChecklist(sessionId) {
  if (!sessionId || sessionId === 'unknown') return [];
  try {
    const key = execSyncSafe('curl -s -m 3 http://127.0.0.1:52437/v/supabase-service').trim();
    if (!key) return [];
    const url = 'https://uvojezuorjgqzmhhgluu.supabase.co/rest/v1/rpc/execute_sql';
    // Read-only: unchecked required checklist rows on non-done items claimed by this session.
    const sql = `select jsonb_agg(c->>'id') as ids from work_items w, jsonb_array_elements(coalesce(w.checklist,'[]'::jsonb)) c where w.session_id = ${sqlLit(sessionId)} and w.status not in ('done','archived') and (c->>'required')::bool is true and coalesce((c->>'checked')::bool,false) = false`;
    const body = JSON.stringify({ query: sql });
    const res = execSyncSafe(`curl -s -m 4 -X POST ${JSON.stringify(url)} -H "apikey: ${key}" -H "Authorization: Bearer ${key}" -H "Content-Type: application/json" -d ${JSON.stringify(body)}`);
    const parsed = JSON.parse(res);
    const ids = Array.isArray(parsed) ? parsed[0]?.ids : parsed?.ids;
    return Array.isArray(ids) ? ids.filter(Boolean) : [];
  } catch {
    return []; // fail OPEN — never wedge the gate on a network/credential blip
  }
}
function sqlLit(s) { return `'${String(s).replace(/'/g, "''")}'`; }

function main() {
  let raw = '';
  try { raw = readFileSync(0, 'utf8'); } catch { /* */ }
  let input = {};
  try { input = JSON.parse(raw); } catch { /* */ }
  const repoRoot = input.cwd ?? process.cwd();
  const sessionId = input.session_id ?? input.sessionId ?? 'unknown';

  if (process.env.COMPLETION_GATE === '0') { process.exit(0); }

  // Per-session WIP waiver (mirrors the lessons-backstop .done pattern).
  const waiver = path.join(repoRoot, '.rdc', 'completion-waivers', `${String(sessionId).replace(/[^a-z0-9_-]/gi, '_')}.wip`);
  if (existsSync(waiver)) { process.exit(0); }

  let porcelain = '';
  try { porcelain = execSync('git status --porcelain', { cwd: repoRoot, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }); }
  catch { /* not a git repo / git error — dirty detector yields nothing */ }

  const tpath = input.transcript_path ?? input.transcriptPath;
  const lastText = lastAssistantText(tpath);
  const pendingChecklist = pendingRequiredChecklist(sessionId);

  // Attribute dirty-file detection to THIS session only in the shared main tree (SV), where a
  // parallel session's WIP would otherwise false-block. Lanes keep whole-tree. A null owned-set
  // (unreadable transcript) falls back to whole-tree so a parse miss never suppresses the gate.
  const attribute = isSharedMainTree(repoRoot);
  const owned = attribute ? sessionOwnedFiles(tpath, repoRoot) : null;
  const ev = evaluateCompletion({
    porcelain, lastText, pendingChecklist,
    attributeToSession: attribute && owned !== null,
    ownedFiles: owned,
  });

  // Observability line (mirrors truth-gate-debug.log) for a weekly review.
  try {
    mkdirSync(path.join(repoRoot, '.rdc', 'logs'), { recursive: true });
    appendFileSync(path.join(repoRoot, '.rdc', 'logs', 'completion-gate.log'),
      JSON.stringify({ ts: new Date().toISOString(), sessionId, block: ev.block, reasonCount: ev.reasons.length, attributed: attribute && owned !== null, ownedCount: owned ? owned.size : null }) + '\n');
  } catch { /* observability only */ }

  if (!ev.block) process.exit(0);

  const message =
    '\n🛑 COMPLETION GATE — work is not finished (Directive #0):\n' +
    ev.reasons.map((r, i) => `  ${i + 1}. ${r}`).join('\n') +
    '\n\nContinue the active goal: commit/stash · fix the wording · ' +
    `touch .rdc/completion-waivers/${String(sessionId).replace(/[^a-z0-9_-]/gi, '_')}.wip (intentional WIP) · env COMPLETION_GATE=0.`;
  process.stdout.write(JSON.stringify(stopContinuationOutput(message, input)));
  process.exit(0);
}

function execSyncSafe(cmd) {
  try { return execSync(cmd, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }); }
  catch { return ''; }
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) main();
