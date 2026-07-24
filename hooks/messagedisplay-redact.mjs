#!/usr/bin/env node
/**
 * MessageDisplay — redact secrets from ON-SCREEN assistant text (2026-07-11).
 * Complements posttool-secret-redact.mjs (which guards tool OUTPUT). This scrubs the model's
 * own rendered message so a secret it echoes never flashes on screen. Display-only: the
 * transcript is unchanged. Reuses the shared redactor. Never blocks. Kill-switch: SECRET_REDACT=0.
 */
import { readFileSync } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { redactSecrets } from './posttool-secret-redact.mjs';

function main() {
  if (process.env.SECRET_REDACT === '0') process.exit(0);
  let input = {};
  try { input = JSON.parse(readFileSync(0, 'utf8')); } catch { process.exit(0); }
  const text = input.message ?? input.display_content ?? input.content ?? input.text;
  if (typeof text !== 'string' || !text) process.exit(0);
  const { redacted, count } = redactSecrets(text);
  if (count > 0) {
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: { hookEventName: 'MessageDisplay', displayContent: redacted },
    }));
  }
  process.exit(0);
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) main();
