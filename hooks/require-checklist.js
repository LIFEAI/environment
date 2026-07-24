#!/usr/bin/env node
// PreToolUse hook — enforces "plan before substantive code work".
//
// Blocks an Edit/Write/MultiEdit to a SOURCE-CODE file when the session is
// already multi-step (>= MIN_TOOL_CALLS prior tool calls) but no checklist
// (TaskCreate / TodoWrite) has been created yet. The escape is trivial and is
// exactly the desired behavior: call TaskCreate to list the steps, then edit.
//
// Scoped to logic/source extensions only — docs, markup, styles, JSON/YAML,
// and anything under .claude/ are never blocked (avoids false positives on
// quick doc/config edits). Fails OPEN on any error so a broken hook can never
// wedge editing.
//
// Approved: option-1 — Checklist-first enforcement hook. Interview: 2026-06-02 in this session
'use strict';

const MIN_TOOL_CALLS = 4; // below this, treat as a one-shot edit — don't gate
const CODE_EXT = /\.(ts|tsx|js|jsx|mjs|cjs|py|go|rs|java|rb|php|c|cc|cpp|h|hpp|cs|swift|kt|sh|ps1|sql)$/i;

let input = '';
process.stdin.resume();
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => { input += c; });
process.stdin.on('end', () => {
  try {
    const parsed = JSON.parse(input);
    const tool = parsed.tool_name || '';
    if (!/^(Edit|Write|MultiEdit)$/.test(tool)) return process.exit(0);

    const fp = (parsed.tool_input && (parsed.tool_input.file_path || parsed.tool_input.path)) || '';
    const norm = fp.replace(/\\/g, '/');
    // Never gate config / docs / non-code surfaces.
    if (norm.includes('/.claude/') || !CODE_EXT.test(norm)) return process.exit(0);

    // Read the session transcript to check (a) how many tool calls have happened
    // and (b) whether a checklist tool was used.
    const tp = parsed.transcript_path;
    if (!tp) return process.exit(0); // no transcript -> fail open
    let text = '';
    try { text = require('fs').readFileSync(tp, 'utf8'); } catch (_) { return process.exit(0); }

    const CHECKLIST_RE = /"name"\s*:\s*"(TaskCreate|TodoWrite)"/;
    if (CHECKLIST_RE.test(text)) return process.exit(0); // a plan exists — allow

    // Subagent fix: when this hook runs inside a dispatched subagent, the harness
    // hands us the PARENT transcript (frozen at dispatch), so the subagent's own
    // TaskCreate/TodoWrite calls — which live in sibling files under the session
    // dir (e.g. <sessiondir>/subagents/agent-*.jsonl) — are invisible to the read
    // above, making the gate unsatisfiable from inside a subagent. Scan sibling
    // .jsonl transcripts in the session tree for a checklist before blocking.
    try {
      const fs = require('fs');
      const path = require('path');
      const sessionDir = path.dirname(tp);
      const stack = [sessionDir];
      let scanned = 0;
      while (stack.length && scanned < 200) {
        const dir = stack.pop();
        let entries = [];
        try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (_) { continue; }
        for (const ent of entries) {
          const full = path.join(dir, ent.name);
          if (ent.isDirectory()) { stack.push(full); continue; }
          if (!ent.name.endsWith('.jsonl') || full === tp) continue;
          scanned++;
          let sib = '';
          try { sib = fs.readFileSync(full, 'utf8'); } catch (_) { continue; }
          if (CHECKLIST_RE.test(sib)) return process.exit(0); // checklist found in a sibling transcript — allow
        }
      }
    } catch (_) { /* fall through to block — fail closed only after honest scan */ }

    const toolCalls = (text.match(/"type"\s*:\s*"tool_use"/g) || []).length;
    if (toolCalls < MIN_TOOL_CALLS) return process.exit(0); // one-shot — don't nag

    const response = {
      decision: 'block',
      reason: [
        '⛔ PLAN-FIRST — no checklist exists for this multi-step session.',
        '',
        `You are about to edit a source file (${norm.split('/').pop()}) and this session`,
        `already has ${toolCalls} tool calls, but no checklist was ever created.`,
        '',
        'Per .claude/rules (require-task-checklist + plan-first): multi-step code work',
        'must START with a visible checklist. Call TaskCreate to list the steps you intend',
        '— including how you will VERIFY the change against the real user action — then',
        'retry this edit. (Docs, config, and .claude/ edits are never gated by this hook.)'
      ].join('\n')
    };
    process.stdout.write(JSON.stringify(response));
    process.exit(0);
  } catch (_) {
    process.exit(0); // fail open
  }
});
