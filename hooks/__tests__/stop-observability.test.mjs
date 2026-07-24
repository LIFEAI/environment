/** Stop test-nudge + cost-log — pure logic tests (2026-07-11). */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { needsNudge, stopNudgeOutput } from '../stop-test-nudge.mjs';
import { sumUsage } from '../session-cost-log.mjs';

test('needsNudge: code changed + no verify command → nudge', () => {
  assert.equal(needsNudge({ changedCode: 2, transcriptText: 'I edited the file and committed.' }), true);
});
test('needsNudge: code changed but tsc/test ran → no nudge', () => {
  assert.equal(needsNudge({ changedCode: 2, transcriptText: 'ran npx tsc --noEmit, exit 0' }), false);
  assert.equal(needsNudge({ changedCode: 3, transcriptText: 'node --test passed 12' }), false);
  assert.equal(needsNudge({ changedCode: 1, transcriptText: 'biome lint clean' }), false);
});
test('needsNudge: no code changed → never nudge', () => {
  assert.equal(needsNudge({ changedCode: 0, transcriptText: 'just docs' }), false);
});

test('Stop nudge emits the Codex continuation envelope for a Codex turn', () => {
  assert.deepEqual(stopNudgeOutput('run the scoped check', { turn_id: 'turn-1' }), {
    continue: true,
    systemMessage: 'Reminder: run the scoped check',
  });
});

test('Stop nudge emits Claude non-error feedback for a Claude turn', () => {
  assert.deepEqual(stopNudgeOutput('run the scoped check', { hook_event_name: 'Stop' }), {
    hookSpecificOutput: {
      hookEventName: 'Stop',
      additionalContext: 'Reminder: run the scoped check',
    },
  });
});

test('sumUsage totals Claude usage blocks', () => {
  const lines = [
    JSON.stringify({ message: { role: 'assistant', usage: { input_tokens: 100, output_tokens: 50 } } }),
    JSON.stringify({ message: { role: 'assistant', usage: { input_tokens: 200, output_tokens: 80 } } }),
  ];
  const u = sumUsage(lines);
  assert.equal(u.input, 300); assert.equal(u.output, 130); assert.equal(u.msgs, 2);
});
test('sumUsage reads Codex cumulative total_token_usage (last-wins, real shape)', () => {
  const lines = [
    JSON.stringify({ type: 'token_count', info: { total_token_usage: { input_tokens: 100, output_tokens: 40 } } }),
    'not json',
    // cumulative running total grows — take the LAST, do not sum
    JSON.stringify({ payload: { type: 'token_count', info: { total_token_usage: { input_tokens: 26776, output_tokens: 236 } } } }),
  ];
  const u = sumUsage(lines);
  assert.equal(u.input, 26776); assert.equal(u.output, 236);
});
