/**
 * Truth Gate unit tests. Proves the gate BLOCKS unevidenced capability claims and
 * every invalid-receipt failure mode, and ALLOWS structural-only text and a valid
 * fresh signed receipt. Runs fully offline (no live runtime) via a fixed secret +
 * temp receipts dir. node --test.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, mkdirSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import path from 'path';
import { evaluate, hasClaimToken, nextStrikeState, lastAssistantText, parserBlindSpot, STRIKE_THRESHOLD, stopContinuationOutput } from '../truth-gate.mjs';
import { sign } from '../lib/receipt.mjs';

const SECRET = 'test-secret-not-real';
const SHA = '5ce86ff0c';
const NOW = Date.parse('2026-06-18T12:00:00Z');

function freshReceipt(over = {}) {
  const r = {
    claim: 'retrieval functional for cs2 memory',
    running_git_sha: SHA,
    source_git_sha: SHA,
    source_eq_running: true,
    nonce: 'needle-7f3a-untracked',
    ingest_path_exercised: 'live',
    read_path: 'FlowMemory.getFlowMemory',
    queries: [{ q: 'needle-7f3a', returned_target: true, count: 1, latency_ms: 180 }],
    all_targets_returned: true,
    ts: new Date(NOW - 60_000).toISOString(), // 1 min old
    ...over,
  };
  r.sig = sign(r, SECRET);
  return r;
}

function dirWith(receipt) {
  const dir = mkdtempSync(path.join(tmpdir(), 'tg-'));
  mkdirSync(dir, { recursive: true });
  if (receipt) writeFileSync(path.join(dir, 'r.json'), JSON.stringify(receipt));
  return dir;
}

const opts = (dir) => ({ receiptsDir: dir, actualRunningSha: SHA, nowMs: NOW, secret: SECRET, maxAgeMin: 30 });

test('blocked Stop gates select the Codex continuation payload for a Codex turn', () => {
  assert.deepEqual(stopContinuationOutput('correct the claim', { turn_id: 'turn-1' }), {
    continue: true,
    systemMessage: 'correct the claim',
  });
});

test('blocked Stop gates select Claude non-error feedback for a Claude turn', () => {
  assert.deepEqual(stopContinuationOutput('correct the claim', { hook_event_name: 'Stop' }), {
    hookSpecificOutput: {
      hookEventName: 'Stop',
      additionalContext: 'correct the claim',
    },
  });
});

test('structural-only text does NOT block (no claim token)', () => {
  assert.equal(hasClaimToken('Committed d9cb346c4; tsc clean; 34 tests green; rows ingested.'), false);
  const dir = dirWith(null);
  assert.equal(evaluate('Wrote the file and committed. tsc passes.', opts(dir)).block, false);
  rmSync(dir, { recursive: true, force: true });
});

test('capability claim with NO receipt BLOCKS', () => {
  const dir = dirWith(null);
  const r = evaluate('The fix works end-to-end now.', opts(dir));
  assert.equal(r.block, true);
  assert.match(r.reason, /no verifier receipt/);
  rmSync(dir, { recursive: true, force: true });
});

test('capability claim with a VALID fresh signed receipt PASSES', () => {
  const dir = dirWith(freshReceipt());
  assert.equal(evaluate('Coverage is 100% and it works end-to-end.', opts(dir)).block, false);
  rmSync(dir, { recursive: true, force: true });
});

test('tampered receipt (bad HMAC) BLOCKS', () => {
  const r = freshReceipt();
  r.all_targets_returned = true;
  r.claim = 'TAMPERED after signing'; // signature no longer matches
  const dir = dirWith(r);
  const res = evaluate('it works', opts(dir));
  assert.equal(res.block, true);
  assert.match(res.reason, /HMAC|signature/i);
  rmSync(dir, { recursive: true, force: true });
});

test('hand-written receipt with NO sig BLOCKS', () => {
  const r = freshReceipt();
  delete r.sig;
  const dir = dirWith(r);
  assert.equal(evaluate('it works', opts(dir)).block, true);
  rmSync(dir, { recursive: true, force: true });
});

test('receipt with a MISS (all_targets_returned=false) BLOCKS', () => {
  const dir = dirWith(freshReceipt({ all_targets_returned: false }));
  const res = evaluate('100% coverage', opts(dir));
  assert.equal(res.block, true);
  assert.match(res.reason, /all_targets_returned|MISS/i);
  rmSync(dir, { recursive: true, force: true });
});

test('stale receipt (> maxAge) BLOCKS', () => {
  const dir = dirWith(freshReceipt({ ts: new Date(NOW - 60 * 60_000).toISOString() })); // 60 min old
  assert.equal(evaluate('it works', opts(dir)).block, true);
  rmSync(dir, { recursive: true, force: true });
});

test('source != running git_sha BLOCKS (stale dist class)', () => {
  const dir = dirWith(freshReceipt({ source_eq_running: false }));
  assert.equal(evaluate('it works', opts(dir)).block, true);
  rmSync(dir, { recursive: true, force: true });
});

test('receipt for a DIFFERENT running sha BLOCKS', () => {
  const dir = dirWith(freshReceipt());
  const res = evaluate('it works', { ...opts(dir), actualRunningSha: 'deadbeef0' });
  assert.equal(res.block, true);
  assert.match(res.reason, /running_git_sha/);
  rmSync(dir, { recursive: true, force: true });
});

test('claim-token detector flags the exact words that lied this session', () => {
  assert.equal(hasClaimToken('inference coverage 100%'), true);
  assert.equal(hasClaimToken('ingested 100%'), true);
  assert.equal(hasClaimToken('the brain now works'), true);
  assert.equal(hasClaimToken('deployed to production'), true);
  // structural facts must NOT trip it
  assert.equal(hasClaimToken('1872 rows ingested into codeflow_akg_nodes'), false);
  assert.equal(hasClaimToken('tsc clean, 34 tests green, committed'), false);
});

// --- 2026-07-09 leak closure: broadened claim tripwire catches the phrasings that leaked,
//     while STRUCTURAL facts still pass untouched.
test('broadened claim patterns catch the leaked feature-turn phrasings', () => {
  assert.equal(hasClaimToken('successfully deployed the SME seed pipeline'), true);
  assert.equal(hasClaimToken('the grammar engine is now wired and up and running'), true);
  assert.equal(hasClaimToken('all 34 tests passing'), true);
  assert.equal(hasClaimToken('everything is connected'), true);
  assert.equal(hasClaimToken('ready for production'), true);
  assert.equal(hasClaimToken('retrieval verified end-to-end'), true);
  // STRUCTURAL facts must STILL pass (no false-positive lockout under hard-refuse)
  assert.equal(hasClaimToken('Committed 325243f4c; tsc clean; 34 tests green; 1,018 rows ingested.'), false);
  assert.equal(hasClaimToken('PR #49 opened; 3 migrations applied; ran needle-verify (MISS reported).'), false);
  assert.equal(hasClaimToken('set up the config file and committed'), false);
});

// --- 2026-07-09 fail-closed canary: schema drift (assistant msgs but no extractable text)
test('parserBlindSpot true only when assistant msgs exist but none yield text', () => {
  const mk = (rows) => {
    const dir = mkdtempSync(path.join(tmpdir(), 'tg-bs-'));
    const f = path.join(dir, 't.jsonl');
    writeFileSync(f, rows.map((r) => JSON.stringify(r)).join('\n') + '\n');
    return { f, dir };
  };
  // drift: assistant messages present, all tool-only / no text anywhere → blind spot
  const drift = mk([
    { message: { role: 'user', content: 'go' } },
    { message: { role: 'assistant', content: [{ type: 'tool_use', id: 'a', name: 'Bash', input: {} }] } },
    { message: { role: 'assistant', content: [{ type: 'tool_use', id: 'b', name: 'Edit', input: {} }] } },
  ]);
  assert.equal(parserBlindSpot(drift.f), true);
  rmSync(drift.dir, { recursive: true, force: true });
  // healthy: at least one assistant message has text → NOT a blind spot
  const healthy = mk([
    { message: { role: 'assistant', content: [{ type: 'text', text: 'Committed abc; tsc clean.' }] } },
    { message: { role: 'assistant', content: [{ type: 'tool_use', id: 'c', name: 'Bash', input: {} }] } },
  ]);
  assert.equal(parserBlindSpot(healthy.f), false);
  rmSync(healthy.dir, { recursive: true, force: true });
  // empty / no assistant messages → NOT a blind spot (benign, nothing to gate)
  const empty = mk([{ message: { role: 'user', content: 'hi' } }]);
  assert.equal(parserBlindSpot(empty.f), false);
  rmSync(empty.dir, { recursive: true, force: true });
  assert.equal(parserBlindSpot('C:/nonexistent/none.jsonl'), false);
});

// --- regression fix: read the last assistant TEXT even when the final message is tool-only
test('lastAssistantText scans back past a tool-only final assistant message', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'tg-tx-'));
  const f = path.join(dir, 't.jsonl');
  // final assistant message is tool_use only (no text) — the 2026-07-05 fail-open case
  writeFileSync(f, [
    JSON.stringify({ message: { role: 'user', content: 'do it' } }),
    JSON.stringify({ message: { role: 'assistant', content: [{ type: 'text', text: 'The build works end-to-end ✅' }] } }),
    JSON.stringify({ type: 'attachment', attachment: {} }),
    JSON.stringify({ message: { role: 'assistant', content: [{ type: 'tool_use', id: 'x', name: 'Bash', input: {} }] } }),
  ].join('\n') + '\n');
  assert.equal(lastAssistantText(f), 'The build works end-to-end ✅'); // NOT '' → gate can fire
  assert.equal(hasClaimToken(lastAssistantText(f)), true);
  rmSync(dir, { recursive: true, force: true });
});

test('lastAssistantText returns the true final text when it IS text', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'tg-tx2-'));
  const f = path.join(dir, 't.jsonl');
  writeFileSync(f, [
    JSON.stringify({ message: { role: 'assistant', content: [{ type: 'text', text: 'first' }] } }),
    JSON.stringify({ message: { role: 'assistant', content: [{ type: 'text', text: 'Committed abc123; tsc clean.' }] } }),
  ].join('\n') + '\n');
  assert.equal(lastAssistantText(f), 'Committed abc123; tsc clean.');
  rmSync(dir, { recursive: true, force: true });
});

// --- 2026-07-09: parse Codex rollout transcripts (payload.role + output_text parts), not
//     just Claude's {message:{content:[{type:'text'}]}}. Validated against real ~/.codex rollouts.
test('lastAssistantText parses a Codex rollout transcript (payload + output_text)', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'tg-codex-'));
  const f = path.join(dir, 'rollout.jsonl');
  writeFileSync(f, [
    JSON.stringify({ type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'do it' }] } }),
    JSON.stringify({ type: 'response_item', payload: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'The deploy works end-to-end ✅' }], phase: 'final_answer' } }),
  ].join('\n') + '\n');
  assert.equal(lastAssistantText(f), 'The deploy works end-to-end ✅');
  assert.equal(hasClaimToken(lastAssistantText(f)), true);
  assert.equal(parserBlindSpot(f), false); // has assistant text → not a blind spot
  rmSync(dir, { recursive: true, force: true });
});

// --- strike counter: escalate + release at STRIKE_THRESHOLD, reset on a clean pass
test('nextStrikeState increments on block, escalates at threshold, resets on pass', () => {
  assert.deepEqual(nextStrikeState(0, true), { strikes: 1, escalate: false });
  assert.deepEqual(nextStrikeState(1, true), { strikes: 2, escalate: false });
  assert.deepEqual(nextStrikeState(2, true), { strikes: 3, escalate: true }); // N=3 → escalate
  // a clean pass resets, regardless of prior count
  assert.deepEqual(nextStrikeState(2, false), { strikes: 0, escalate: false });
  assert.deepEqual(nextStrikeState(5, false), { strikes: 0, escalate: false });
  // honors a custom threshold
  assert.deepEqual(nextStrikeState(0, true, 1), { strikes: 1, escalate: true });
  // tolerates garbage prior state
  assert.deepEqual(nextStrikeState(undefined, true), { strikes: 1, escalate: false });
  assert.equal(STRIKE_THRESHOLD, 3);
});
