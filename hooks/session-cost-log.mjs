#!/usr/bin/env node
/**
 * Stop — log per-session token usage + warn on runaway burn (2026-07-11).
 * Lightweight local alternative to full OpenTelemetry (no OTLP collector required): sums token
 * usage from the transcript, appends to .rdc/logs/session-cost.jsonl, and prints a warning when
 * output tokens cross a spike threshold — the signal that catches a stuck rdc:overnight loop.
 * Engine-agnostic. Never blocks (exit 0). Kill-switch: env COST_LOG=0. Threshold: COST_SPIKE_TOKENS.
 */
import { readFileSync, existsSync, appendFileSync, mkdirSync } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

/**
 * Pure: total token usage across a transcript. Handles two shapes:
 *  - Claude: per-message `usage{input_tokens,output_tokens}` — SUMMED.
 *  - Codex:  `token_count` events with a CUMULATIVE `info.total_token_usage` — LAST wins
 *            (summing would multiply-count the running total).
 * A session is one engine, so the two paths don't collide. Exported for tests.
 */
export function sumUsage(lines) {
  let cIn = 0, cOut = 0, msgs = 0;   // Claude (summed)
  let xIn = 0, xOut = 0;             // Codex (last cumulative total)
  for (const l of lines) {
    let o; try { o = JSON.parse(l); } catch { continue; }
    const m = o.message ?? o.payload ?? o;
    const u = m?.usage || o?.usage;
    if (u && typeof u === 'object') {
      cIn += Number(u.input_tokens || u.prompt_tokens || u.input || 0) || 0;
      cOut += Number(u.output_tokens || u.completion_tokens || u.output || 0) || 0;
      msgs++;
    }
    if (o?.payload?.type === 'token_count' || o?.type === 'token_count') {
      const info = o.payload?.info || o.info || {};
      const tu = info.total_token_usage || info.last_token_usage || info;
      const i = Number(tu.input_tokens || tu.total_input_tokens || 0) || 0;
      const ot = Number(tu.output_tokens || tu.total_output_tokens || 0) || 0;
      if (i || ot) { xIn = i; xOut = ot; msgs++; } // last-wins (cumulative)
    }
  }
  return { input: cIn + xIn, output: cOut + xOut, msgs };
}

function main() {
  if (process.env.COST_LOG === '0') process.exit(0);
  let input = {};
  try { input = JSON.parse(readFileSync(0, 'utf8')); } catch { process.exit(0); }
  const p = input.transcript_path || input.transcriptPath;
  if (!p || !existsSync(p)) process.exit(0);
  let lines = [];
  try { lines = readFileSync(p, 'utf8').split('\n').filter(Boolean); } catch { process.exit(0); }
  const usage = sumUsage(lines);
  const repoRoot = input.cwd || process.cwd();
  try {
    mkdirSync(path.join(repoRoot, '.rdc', 'logs'), { recursive: true });
    appendFileSync(path.join(repoRoot, '.rdc', 'logs', 'session-cost.jsonl'),
      JSON.stringify({ ts: new Date().toISOString(), sessionId: input.session_id || 'unknown', ...usage }) + '\n');
  } catch { /* */ }
  const spike = Number(process.env.COST_SPIKE_TOKENS || 1_500_000);
  if (usage.output > spike) {
    process.stderr.write(`⚠️ COST: session output tokens ${usage.output.toLocaleString()} exceeded spike threshold ${spike.toLocaleString()} — check for a runaway loop.\n`);
  }
  process.exit(0);
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) main();
