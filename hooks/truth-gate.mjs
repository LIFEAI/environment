#!/usr/bin/env node
/**
 * Truth Gate — Stop hook (anti-lie enforcement, P1).
 * Spec: .rdc/plans/anti-lie-enforcement.md (hardened design by a peer Opus
 * observer, 2026-06-18). Approved: full-plan-P1-P5. Interview: 2026-06-18.
 *
 * Keystone of the system: a structured Stop continuation prevents the turn from
 * ending, forcing the agent to keep working instead of finishing on an
 * unverified success without pausing an active Codex goal.
 *
 * Logic: if the final assistant message asserts a CAPABILITY claim (banned claim
 * tokens — done/works/live/100%/coverage|ingested near a number/…), it is BLOCKED
 * unless a FRESH, HMAC-VALID receipt exists that (a) was minted by needle-verify
 * (the agent did not author it), (b) pins source_git_sha == running_git_sha ==
 * the actually-running brain, and (c) all_targets_returned === true (no MISS).
 *
 * The agent cannot satisfy this by writing prose. The only exits are: a real
 * green receipt, OR removing/downgrading the capability claim to a structural
 * fact ("rows ingested" not "it retrieves"). Honest reporting always passes.
 */
import { readFileSync, existsSync, readdirSync, appendFileSync, writeFileSync, mkdirSync } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { execSync } from 'child_process';
import { validateForClaim } from './lib/receipt.mjs';

// Banned capability tokens (case-insensitive). coverage/ingested NEAR A NUMBER are
// the prime triggers — those are the exact words that lied this session.
const CLAIM_PATTERNS = [
  /\b(it|this|that|everything|the \w+) (now |currently )?works\b/i,
  /\bnow works\b/i,
  /\b(fully|now) (working|functional)\b/i,
  /\b(the )?(fix|feature|bug|issue|change) (works|is fixed|is resolved|is done|is complete)\b/i,
  /\bworks end[- ]to[- ]end\b/i,
  /\b(verified|confirmed|proven) (working|to work|fixed)\b/i,
  /\b\d+(\.\d+)?\s*%\s*(working|functional|complete|coverage|done|passing|retriev\w+|ingested)\b/i,
  /\b(coverage|ingested|retrieval)\s*(is|=|:)?\s*\d+(\.\d+)?\s*%/i,
  /\b(deployed (to|and) (prod|production|live|working))\b/i,
  /\bnow (live|deployed) (and|on|in)\b/i,
  /✅/,
  // 2026-07-09 leak closure (Dave): claude-6 + codex-3 shipped feature turns that read
  // hasClaim=false because the wrap-up avoided the exact banned words. These are the
  // high-signal capability phrasings the tripwire was missing. Kept narrow so STRUCTURAL
  // facts ("34 tests green", "rows ingested", "PR opened") still pass untouched.
  /\b(successfully|now)\s+(deployed|implemented|built|created|wired|integrated|configured|set up)\b/i,
  /\bup and running\b/i,
  /\bready\s+(for|to)\s+(prod|production|deploy|ship|use|go)\b/i,
  /\ball\s+(\d[\d,]*\s+)?(tests?|checks?|gates?)\b[^.\n]{0,40}\b(pass|passing|green|succeed)/i,
  /\beverything\s+(is\s+)?(working|passing|green|wired|connected|integrated)\b/i,
  /\b(end[- ]to[- ]end|e2e)\s+(working|passing|verified|functional)\b/i,
  /\b(working|passing|verified|confirmed|proven|functional)\s+(end[- ]to[- ]end|e2e)\b/i,
  /\b(is|are|now)\s+(fully\s+)?operational\b/i,
  /\bgreen across the board\b/i,
];

export function hasClaimToken(text) {
  return CLAIM_PATTERNS.some((re) => re.test(text));
}

/**
 * Schema-drift canary (2026-07-09, Dave: full-scope hardening).
 * Returns true when the transcript HAS assistant-role messages but NONE of them yield
 * extractable text under the current parser — the exact 2026-07-05 fail-open signature
 * (a Claude transcript schema change that makes lastAssistantText() return '' for every
 * message, so claims leak silently). A benign tool-only / not-yet-flushed turn has
 * withText===0 too, but so does a real turn under a broken parser — the distinguisher is
 * that a HEALTHY session accumulates SOME text over its life. We therefore treat
 * assistantMsgs>0 && withText===0 across the WHOLE transcript as drift and fail CLOSED.
 */
export function parserBlindSpot(transcriptPath) {
  if (!transcriptPath || !existsSync(transcriptPath)) return false;
  const lines = readFileSync(transcriptPath, 'utf8').split('\n').filter(Boolean);
  let assistantMsgs = 0;
  let withText = 0;
  for (const l of lines) {
    let obj;
    try { obj = JSON.parse(l); } catch { continue; }
    const msg = obj.message ?? obj.payload ?? obj;
    if (msg?.role !== 'assistant') continue;
    assistantMsgs++;
    const c = msg.content;
    if (typeof c === 'string' ? c.trim() : Array.isArray(c) && c.some((p) => (p?.type === 'text' || p?.type === 'output_text') && p.text?.trim())) {
      withText++;
    }
  }
  return assistantMsgs > 0 && withText === 0;
}

export function lastAssistantText(transcriptPath) {
  if (!transcriptPath || !existsSync(transcriptPath)) return '';
  const lines = readFileSync(transcriptPath, 'utf8').split('\n').filter(Boolean);
  for (let i = lines.length - 1; i >= 0; i--) {
    let obj;
    try { obj = JSON.parse(lines[i]); } catch { continue; }
    // Claude: {message:{role,content}}. Codex rollout: {type:'response_item',payload:{type:'message',role,content}}.
    const msg = obj.message ?? obj.payload ?? obj;
    if (msg?.role !== 'assistant') continue;
    const c = msg.content;
    let t = '';
    if (typeof c === 'string') t = c;
    // Claude text part: {type:'text',text}. Codex assistant part: {type:'output_text',text}.
    else if (Array.isArray(c)) t = c.filter((p) => p?.type === 'text' || p?.type === 'output_text').map((p) => p.text || '').join('\n');
    // KEY FIX (2026-07-05 regression): a turn's final assistant message can be TOOL-ONLY
    // (no text part). The old code returned that message's empty text and gave up, so the
    // gate read '' and failed open. Instead, keep scanning back to the last assistant
    // message that actually HAS text — the real final response to gate on.
    if (t.trim()) return t;
  }
  return '';
}

/** Newest receipt JSON in receiptsDir, or null. */
export function newestReceipt(receiptsDir) {
  if (!existsSync(receiptsDir)) return null;
  const files = readdirSync(receiptsDir).filter((f) => f.endsWith('.json'));
  let best = null;
  let bestT = -Infinity;
  for (const f of files) {
    try {
      const rec = JSON.parse(readFileSync(path.join(receiptsDir, f), 'utf8'));
      const t = Date.parse(rec.ts);
      if (!Number.isNaN(t) && t > bestT) { bestT = t; best = rec; }
    } catch { /* skip */ }
  }
  return best;
}

/** Pure decision: returns {block, reason}. Exported for tests. */
export function evaluate(text, { receiptsDir, actualRunningSha, nowMs, secret, maxAgeMin } = {}) {
  if (!hasClaimToken(text)) return { block: false };
  const receipt = newestReceipt(receiptsDir);
  if (!receipt) {
    return {
      block: true,
      reason:
        'Your message makes a CAPABILITY claim (works / 100% / coverage|ingested+number / deployed-and-working / ✅) but there is no verifier receipt. PRIMARY EXIT — downgrade to the STRUCTURAL fact and label it structural-only: "PR #N opened", "M migrations applied", "tsc exit 0", "rows ingested". Reporting STRUCTURAL_ONLY or MISS is a correct, expected outcome that ends the turn cleanly. Mint a receipt with `node scripts/needle-verify.mjs` (live runtime, fresh nonce, three-store check) ONLY if the claim is specifically about codeflow-brain retrieval/coverage — coordinator/status claims (PR, deploy, migration) have NO needle path and must NOT mint one.',
    };
  }
  const v = validateForClaim(receipt, { actualRunningSha, nowMs, secret, maxAgeMin });
  if (!v.ok) {
    return {
      block: true,
      reason: `Capability claim present, and the newest receipt does not pass: ${v.reason}. PRIMARY EXIT — downgrade the claim to a STRUCTURAL fact ("PR #N opened", "M migrations applied", "tsc exit 0") and report structural-only; this ends the turn cleanly and is the correct path for coordinator/status claims, which have NO needle receipt. Do NOT mint or refresh a needle receipt to clear a non-retrieval claim — that is the gaming this gate exists to stop. Re-run needle-verify ONLY for a genuine codeflow-brain retrieval/coverage claim against the running source. (A passing receipt requires HMAC validity, source==running git_sha, all_targets_returned, and freshness.)`,
    };
  }
  return { block: false };
}

// --- Strike counter (2026-07-05, Dave: escalate + release at N strikes) ---------
// "Refuses to fix" = the gate blocks on consecutive Stops without a clean pass in
// between. A clean pass (no claim / claim downgraded) RESETS the count to 0. When the
// count reaches STRIKE_THRESHOLD, ESCALATE: write a durable refusal record + loud human
// banner, then RELEASE (exit 0) so the agent stops grinding and Dave owns it.
export const STRIKE_THRESHOLD = 3;

/** Pure, testable: new consecutive-block count + whether to escalate. */
export function nextStrikeState(prevStrikes, blocked, threshold = STRIKE_THRESHOLD) {
  if (!blocked) return { strikes: 0, escalate: false };
  const strikes = (Number(prevStrikes) || 0) + 1;
  return { strikes, escalate: strikes >= threshold };
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

function strikeFile(repoRoot, sessionId) {
  const safe = String(sessionId || 'unknown').replace(/[^a-z0-9_-]/gi, '_');
  return path.join(repoRoot, '.rdc', 'evidence', 'truth-gate-strikes', `${safe}.json`);
}
function readStrikes(repoRoot, sessionId) {
  try { return JSON.parse(readFileSync(strikeFile(repoRoot, sessionId), 'utf8')).strikes || 0; }
  catch { return 0; }
}
function writeStrikes(repoRoot, sessionId, strikes) {
  try {
    mkdirSync(path.dirname(strikeFile(repoRoot, sessionId)), { recursive: true });
    writeFileSync(strikeFile(repoRoot, sessionId), JSON.stringify({ sessionId, strikes, ts: new Date().toISOString() }) + '\n');
  } catch { /* best effort — never let bookkeeping crash the gate */ }
}
function writeEscalation(repoRoot, sessionId, strikes, claim, reason) {
  try {
    const dir = path.join(repoRoot, '.rdc', 'evidence', 'escalations');
    mkdirSync(dir, { recursive: true });
    const safe = String(sessionId || 'unknown').replace(/[^a-z0-9_-]/gi, '_');
    writeFileSync(path.join(dir, `${safe}-truthgate.json`), JSON.stringify({
      kind: 'truth-gate-refusal', sessionId, strikes,
      claim: String(claim).slice(0, 500), reason: String(reason).slice(0, 500),
      ts: new Date().toISOString(),
    }, null, 1) + '\n');
  } catch { /* best effort */ }
}

function main() {
  let raw = '';
  try { raw = readFileSync(0, 'utf8'); } catch { /* no stdin */ }
  let input = {};
  try { input = JSON.parse(raw); } catch { /* tolerate */ }
  const repoRoot = input.cwd ?? process.cwd();
  const tpath = input.transcript_path ?? input.transcriptPath;
  const text = lastAssistantText(tpath);
  const receiptsDir = path.join(repoRoot, '.rdc', 'evidence', 'receipts');
  const sessionId = input.session_id ?? input.sessionId ?? 'unknown';
  // actualRunningSha: pin against the live brain. Best-effort; if unreachable we still
  // enforce HMAC + freshness + all_targets_returned (do NOT fail-open on a probe miss).
  let actualRunningSha;
  try {
    const h = execSyncSafe('curl -s -m 3 http://127.0.0.1:3109/health');
    if (h) actualRunningSha = (JSON.parse(h).git_sha || '').slice(0, 9) || undefined;
  } catch { /* leave undefined */ }

  // Decide.
  let blocked = false, reason = '', strikes = 0, escalated = false, exitCode = 0;
  if (!text) {
    // Empty extracted text. Benign (no assistant text yet / tool-only turn) UNLESS the
    // transcript shows a parser BLIND SPOT (assistant messages but zero text anywhere) —
    // the 2026-07-05 schema-drift fail-open. In that case FAIL CLOSED so a claim cannot
    // leak past a gate that can no longer read the turn.
    if (parserBlindSpot(tpath) && process.env.TRUTH_GATE_FAILCLOSED !== '0') {
      blocked = true;
      reason = 'PARSER BLIND SPOT — the transcript has assistant messages but no extractable text (likely a Claude transcript-schema change). Failing CLOSED so an unverified capability claim cannot leak past a gate that can no longer read the turn. Fix lastAssistantText() for the new schema, then re-run; or set env TRUTH_GATE_FAILCLOSED=0 to override once confirmed benign.';
    } else {
      exitCode = 0; // genuinely nothing to gate (no assistant text this turn)
    }
  } else {
    const ev = evaluate(text, { receiptsDir, actualRunningSha });
    blocked = ev.block; reason = ev.reason || '';
  }

  if (blocked) {
    const s = nextStrikeState(readStrikes(repoRoot, sessionId), true);
    strikes = s.strikes; escalated = s.escalate;
    writeStrikes(repoRoot, sessionId, strikes);
    if (escalated) writeEscalation(repoRoot, sessionId, strikes, text || `[${reason}]`, reason);
    // HARD-CONTINUE: keep the gate active for every unverified claim, but use
    // Codex's documented continuation payload rather than an exit-code failure.
    // Exit 2 can pause a persisted /goal instead of returning the correction to
    // the agentic loop. The escape remains structural reporting or valid proof.
    exitCode = 0;
  } else if (text) {
    writeStrikes(repoRoot, sessionId, 0); // clean pass → reset the strike streak
  }

  // ONE observability line WITH the decision — this is what the weekly review reads to catch
  // a silent fail-open (transcript_exists but textLen 0, or hasClaim with blocked=false).
  try {
    mkdirSync(path.join(repoRoot, '.rdc', 'logs'), { recursive: true });
    appendFileSync(path.join(repoRoot, '.rdc', 'logs', 'truth-gate-debug.log'),
      JSON.stringify({
        ts: new Date().toISOString(),
        event: input.hook_event_name ?? null,
        stop_hook_active: input.stop_hook_active ?? null,
        sessionId,
        transcript_exists: tpath ? existsSync(tpath) : false,
        textLen: text ? text.length : 0,
        hasClaim: text ? hasClaimToken(text) : false,
        blocked, strikes, escalated, exitCode, engine: isCodexStopInput(input) ? 'codex' : 'claude',
      }) + '\n');
  } catch { /* observability only — never affects the gate */ }

  if (blocked) {
    const message = escalated
      ?
      '\n🛑🛑🛑  TRUTH GATE — HARD-BLOCKED (ESCALATED TO HUMAN)  🛑🛑🛑\n' +
      `The agent hit the truth gate ${strikes}× in a row on an unverified claim WITHOUT fixing it.\n` +
      'The active goal REMAINS BLOCKED (Dave: hard-refuse) and a refusal record was written to\n' +
      '.rdc/evidence/escalations/. The ONLY exits are to downgrade the claim to a STRUCTURAL\n' +
      'fact ("PR #N opened", "tsc exit 0", "rows ingested") or produce a valid needle receipt.\n' +
      'Do NOT restate the same unverified claim — it will block again.\n' +
      `Last blocked reason: ${reason}\n` +
      '🛑🛑🛑  -----------------------------------  🛑🛑🛑\n'
      : `TRUTH GATE (strike ${strikes}/${STRIKE_THRESHOLD}): ${reason}`;
    process.stdout.write(JSON.stringify(stopContinuationOutput(message, input)));
  }
  process.exit(exitCode);
}

function execSyncSafe(cmd) {
  try {
    return execSync(cmd, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  } catch { return ''; }
}

// Run only when invoked directly (not when imported by tests).
const invokedDirect = process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));
if (invokedDirect) main();
