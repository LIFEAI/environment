#!/usr/bin/env node
/**
 * PostToolUse — redact secrets from tool OUTPUT before the model/transcript sees them (2026-07-11).
 * Our existing block-clauth-exposure guards STDOUT the agent tries to print; this guards the
 * INBOUND path: a Read of a .env, a `curl` response carrying a token, an MCP payload with a
 * key — redacted before it enters context. Best practice: keep secrets out of the model + JSONL.
 * Engine-agnostic: Claude PostToolUse (`tool_output`) + Codex PostToolUse (`tool_response`).
 * Advisory: exit 0 with updatedToolOutput. Kill-switch: env SECRET_REDACT=0.
 */
import { readFileSync } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

// (label, regex). Order matters: specific before generic. All global+multiline.
const PATTERNS = [
  ['private-key', /-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----/g],
  ['aws-akia', /\bAKIA[0-9A-Z]{16}\b/g],
  ['gh-token', /\bgh[pousr]_[A-Za-z0-9]{36,}\b/g],
  ['slack-token', /\bxox[baprs]-[0-9A-Za-z-]{10,}\b/g],
  ['anthropic-key', /\bsk-ant-[A-Za-z0-9_-]{20,}\b/g],
  ['openai-key', /\bsk-[A-Za-z0-9]{20,}\b/g],
  ['jwt', /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/g],
  // key/value assignments: api_key= / "token": "..." / bearer <...> / password=...
  ['assigned-secret', /\b(api[_-]?key|secret|token|password|passwd|access[_-]?key|bearer|authorization)\b["']?\s*[:=]\s*["']?([A-Za-z0-9_\-\.=/+]{16,})/gi],
];

/** Pure: redact secrets in text. Returns { redacted, count }. Exported for tests. */
export function redactSecrets(text) {
  if (typeof text !== 'string' || !text) return { redacted: text ?? '', count: 0 };
  let count = 0;
  let out = text;
  for (const [label, re] of PATTERNS) {
    out = out.replace(re, (m, g1, g2) => {
      // For assigned-secret keep the key name + operator, redact only the value.
      if (label === 'assigned-secret') {
        // reconstruct "key: " prefix, redact value
        const keyPart = m.slice(0, m.length - g2.length);
        count++;
        return `${keyPart}«REDACTED:${label}»`;
      }
      count++;
      return `«REDACTED:${label}»`;
    });
  }
  return { redacted: out, count };
}

function extractOutput(input) {
  // Claude: tool_output (string or object). Codex: tool_response.
  const raw = input.tool_output ?? input.tool_response ?? input.tool_result;
  if (raw == null) return { text: null, wasString: false };
  if (typeof raw === 'string') return { text: raw, wasString: true };
  try { return { text: JSON.stringify(raw), wasString: false }; } catch { return { text: null, wasString: false }; }
}

function main() {
  if (process.env.SECRET_REDACT === '0') process.exit(0);
  let input = {};
  try { input = JSON.parse(readFileSync(0, 'utf8')); } catch { process.exit(0); }
  const { text } = extractOutput(input);
  if (!text) process.exit(0);
  const { redacted, count } = redactSecrets(text);
  if (count > 0) {
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PostToolUse',
        updatedToolOutput: redacted,
        additionalContext: `⚠️ ${count} secret-like value(s) redacted from this tool output before it entered context.`,
      },
    }));
  }
  process.exit(0);
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) main();
