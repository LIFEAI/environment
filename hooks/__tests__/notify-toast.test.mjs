/** Notification alert — classifier tests (2026-07-11). */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { classifyNotification } from '../notify-toast.mjs';

test('alerts when the agent needs input', () => {
  assert.equal(classifyNotification({ hook_event_name: 'Notification', notification_type: 'permission_prompt' }).alert, true);
  assert.equal(classifyNotification({ hook_event_name: 'Notification', notification_type: 'agent_needs_input' }).alert, true);
  assert.equal(classifyNotification({ hook_event_name: 'Notification', notification_type: 'idle_prompt' }).alert, true);
});

test('alerts on Stop/SubagentStop with the final message', () => {
  const c = classifyNotification({ hook_event_name: 'Stop', last_assistant_message: 'done' });
  assert.equal(c.alert, true);
  assert.match(c.body, /done/);
});

test('does not alert on benign notifications', () => {
  assert.equal(classifyNotification({ hook_event_name: 'Notification', notification_type: 'auth_success' }).alert, false);
  assert.equal(classifyNotification({ hook_event_name: 'Notification', notification_type: 'agent_completed' }).alert, false);
});
