#!/usr/bin/env node
// Universal Inbox BTW Inject — convergence layer 5 (messaging/presence).
// Generalizes collab-board-wake.js from one producer (board posts) to ALL producers
// via collab.inbox_peek(session_key) -> { pending, sources, max_priority }.
//
//   max_priority: 0 = none, 1 = normal, 2 = urgent
//   - normal mail  -> BTW (non-blocking; surfaced, never gates Stop)
//   - urgent mail  -> blocking Stop gate (bounded by MAX_REINJECTS)
//
// NOT WIRED into settings.json yet — activation (Claude .claude/hooks + Codex .codex,
// same wave) is operator-gated per the 2026-06-29 architectural interview.
// Self-test: `node universal-inbox-inject.js --self-test`

const MAX_REINJECTS = 3;

// Pure decision — no I/O, fully unit-testable (same shape contract as collab-board-wake.js).
function decisionForInbox({ event, peek, reinjectCount = 0, maxReinjects = MAX_REINJECTS }) {
  if (!peek || (peek.pending || 0) <= 0) return { decision: "approve" };
  const sources = (peek.sources || []).join(",");
  const n = peek.pending;

  if (event === "Stop" || event === "SubagentStop") {
    if ((peek.max_priority || 0) >= 2 && reinjectCount < maxReinjects) {
      return {
        decision: "block",
        reason: `URGENT: ${n} message(s) waiting (${sources}). Drain your inbox before stopping.`,
      };
    }
    // Normal mail never blocks Stop — BTW only.
    return { decision: "approve", btw: `BTW - ${n} message(s) waiting (${sources}); handle when convenient.` };
  }

  if (event === "UserPromptSubmit") {
    // BTW piggyback. Exact additionalContext wiring verified against the harness before activation.
    return {
      decision: "approve",
      additionalContext: `📬 BTW - ${n} message(s) waiting (${sources}). Handle after your current step.`,
    };
  }

  return { decision: "approve" };
}

const CLAUTH = process.env.CLAUTH_BASE_URL || "http://127.0.0.1:52437";

// Resolve peek: explicit payload (tests) -> env JSON -> live daemon /inbox/<key>/peek.
// Any failure degrades to an empty inbox (approve) — a messaging probe must never trap an agent.
async function resolvePeek(payload) {
  if (payload.peek) return payload.peek;
  if (process.env.INBOX_PEEK_JSON) {
    try { return JSON.parse(process.env.INBOX_PEEK_JSON); } catch { return null; }
  }
  const key = payload.session_key || process.env.INBOX_SESSION_KEY;
  if (!key) return null;
  try {
    const res = await fetch(`${CLAUTH}/inbox/${encodeURIComponent(key)}/peek`);
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null; // daemon endpoint not yet live -> approve
  }
}

async function main() {
  const raw = await readStdin();
  let payload = {};
  try { payload = raw ? JSON.parse(raw) : {}; } catch { payload = {}; }

  const peek = await resolvePeek(payload);
  const result = decisionForInbox({
    event: payload.hook_event_name || process.env.HOOK_EVENT || "Stop",
    peek,
    reinjectCount: Number(payload.reinjectCount ?? process.env.INBOX_REINJECT_COUNT ?? 0),
  });
  process.stdout.write(JSON.stringify(result));
}

function readStdin() {
  return new Promise((resolve) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (c) => { data += c; });
    process.stdin.on("end", () => resolve(data));
    if (process.stdin.isTTY) resolve("");
  });
}

function selfTest() {
  const cases = [
    { name: "empty -> approve", in: { event: "Stop", peek: { pending: 0, sources: [], max_priority: 0 } }, expect: "approve", noBlock: true },
    { name: "normal at Stop -> approve+btw", in: { event: "Stop", peek: { pending: 2, sources: ["board"], max_priority: 1 } }, expect: "approve", hasBtw: true },
    { name: "urgent at Stop -> block", in: { event: "Stop", peek: { pending: 1, sources: ["supervisor"], max_priority: 2 } }, expect: "block" },
    { name: "urgent but reinject cap -> approve", in: { event: "Stop", peek: { pending: 1, sources: ["supervisor"], max_priority: 2 }, reinjectCount: 3 }, expect: "approve" },
    { name: "UserPromptSubmit -> approve+context", in: { event: "UserPromptSubmit", peek: { pending: 1, sources: ["human"], max_priority: 1 } }, expect: "approve", hasCtx: true },
  ];
  let failed = 0;
  for (const c of cases) {
    const r = decisionForInbox(c.in);
    const ok =
      r.decision === c.expect &&
      (!c.hasBtw || !!r.btw) &&
      (!c.hasCtx || !!r.additionalContext);
    if (!ok) { failed++; console.error(`FAIL ${c.name}: got ${JSON.stringify(r)}`); }
    else console.log(`ok   ${c.name}`);
  }
  console.log(failed === 0 ? "universal-inbox-inject self-test passed" : `${failed} FAILED`);
  process.exit(failed === 0 ? 0 : 1);
}

if (require.main === module) {
  if (process.argv.includes("--self-test")) selfTest();
  else main().catch((e) => process.stdout.write(JSON.stringify({ decision: "approve", reason: e.message })));
}

module.exports = { MAX_REINJECTS, decisionForInbox };
