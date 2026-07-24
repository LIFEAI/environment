/**
 * Truth Gate — signed receipt library (P1, Dave's hardened spec 2026-06-18).
 *
 * A receipt is the ONLY thing that unlocks a capability claim. It is minted ONLY
 * by scripts/needle-verify.mjs after that verifier hit the LIVE runtime with a
 * FRESH NONCE the agent did not choose, and proved three-store consistency
 * (AKG rows -> readable -> end-to-end retrievable). The agent authors nothing
 * that unlocks a claim.
 *
 * HMAC over the canonical receipt fields. Secret comes from clauth
 * (`truth-gate-secret`) via the daemon, or env TRUTH_GATE_SECRET. HONEST LIMIT:
 * on a single-operator box the agent can also read the secret, so this is not
 * unforgeable against a determined operator-agent — it kills the ACCIDENTAL
 * overclaim class and forces any fake to be deliberate multi-step deception that
 * still has to beat the nonce + live-git_sha + three-store checks. Dave's review
 * is the ultimate backstop (spec §0, §6).
 */
import crypto from 'crypto';
import { execSync } from 'child_process';

/** Canonical field order signed by the HMAC. Order matters — keep stable. */
const SIGNED_FIELDS = [
  'claim',
  'running_git_sha',
  'source_git_sha',
  'source_eq_running',
  'nonce',
  'ingest_path_exercised',
  'read_path',
  'queries',
  'all_targets_returned',
  'ts',
];

export function canonical(receipt) {
  const picked = {};
  for (const k of SIGNED_FIELDS) picked[k] = receipt[k] ?? null;
  return JSON.stringify(picked);
}

export function getSecret() {
  if (process.env.TRUTH_GATE_SECRET) return process.env.TRUTH_GATE_SECRET;
  try {
    // clauth daemon, plain-text value. Never printed.
    const v = execSync('curl -s -m 3 http://127.0.0.1:52437/v/truth-gate-secret', {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
    return v || null;
  } catch {
    return null;
  }
}

export function sign(receipt, secret = getSecret()) {
  if (!secret) throw new Error('truth-gate: no HMAC secret (clauth truth-gate-secret / TRUTH_GATE_SECRET)');
  return crypto.createHmac('sha256', secret).update(canonical(receipt)).digest('hex');
}

export function verifySig(receipt, secret = getSecret()) {
  if (!secret || !receipt?.sig) return false;
  let expected;
  try { expected = sign(receipt, secret); } catch { return false; }
  const a = Buffer.from(expected, 'hex');
  const b = Buffer.from(String(receipt.sig), 'hex');
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

/**
 * Validate a receipt for a claim, against the actually-running git_sha.
 * Returns { ok, reason }. ALL must hold:
 *   - HMAC valid (not hand-written)
 *   - source_eq_running === true AND running_git_sha === actualRunningSha
 *   - all_targets_returned === true (every needle query returned its target)
 *   - ts within maxAgeMin (fresh, not a stale receipt from a prior build)
 */
export function validateForClaim(receipt, { actualRunningSha, maxAgeMin = 30, nowMs, secret } = {}) {
  if (!receipt || typeof receipt !== 'object') return { ok: false, reason: 'no receipt' };
  if (!verifySig(receipt, secret)) return { ok: false, reason: 'bad/absent HMAC signature (hand-written receipt?)' };
  if (receipt.source_eq_running !== true) return { ok: false, reason: 'source_eq_running != true (stale dist vs source)' };
  if (actualRunningSha && receipt.running_git_sha !== actualRunningSha) {
    return { ok: false, reason: `receipt running_git_sha ${receipt.running_git_sha} != actually-running ${actualRunningSha}` };
  }
  if (receipt.all_targets_returned !== true) return { ok: false, reason: 'all_targets_returned != true (a needle MISS)' };
  const t = Date.parse(receipt.ts);
  if (Number.isNaN(t)) return { ok: false, reason: 'unparseable ts' };
  const now = typeof nowMs === 'number' ? nowMs : Date.now();
  if (now - t > maxAgeMin * 60_000) return { ok: false, reason: `receipt stale (> ${maxAgeMin}m old)` };
  return { ok: true };
}
