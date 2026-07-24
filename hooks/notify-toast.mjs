#!/usr/bin/env node
/**
 * Notification + Stop — desktop alert for unattended/overnight runs (2026-07-11).
 * Fires a Windows toast (best-effort, no external module) when the agent needs input or
 * finishes, and logs every notification to .rdc/logs/notifications.jsonl. So when nobody is
 * watching the terminal (rdc:overnight), a permission prompt or turn-end still surfaces.
 * Engine-agnostic. Never blocks (exit 0). Kill-switch: env NOTIFY_TOAST=0.
 */
import { readFileSync, appendFileSync, mkdirSync } from 'fs';
import { execFile } from 'child_process';
import path from 'path';
import { fileURLToPath } from 'url';

/** Pure: decide whether/what to alert. Exported for tests. */
export function classifyNotification(input) {
  const ev = String(input.hook_event_name || '').toLowerCase();
  const type = String(input.notification_type || '').toLowerCase();
  const msg = String(input.message || input.last_assistant_message || '').slice(0, 160);
  if (ev === 'stop' || ev === 'subagentstop') {
    return { alert: true, title: 'Claude/Codex — turn finished', body: msg || 'The agent stopped and is waiting.' };
  }
  // Notification event: alert on the ones that mean "human needed".
  if (/permission|needs_input|idle|elicitation_dialog|approval/.test(type)) {
    return { alert: true, title: 'Agent needs you', body: msg || type || 'Waiting for input/permission.' };
  }
  return { alert: false };
}

function toast(title, body) {
  // Win10+ toast via PowerShell, no BurntToast module required. Best-effort, detached.
  const ps = `
$ErrorActionPreference='SilentlyContinue'
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
$t=[Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
$n=$t.GetElementsByTagName('text')
$n.Item(0).AppendChild($t.CreateTextNode(${JSON.stringify(title)}))|Out-Null
$n.Item(1).AppendChild($t.CreateTextNode(${JSON.stringify(body)}))|Out-Null
$toast=[Windows.UI.Notifications.ToastNotification]::new($t)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Claude Code').Show($toast)`;
  try {
    const child = execFile('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', ps], { windowsHide: true }, () => {});
    child.unref?.();
  } catch { /* best effort */ }
}

function main() {
  if (process.env.NOTIFY_TOAST === '0') process.exit(0);
  let input = {};
  try { input = JSON.parse(readFileSync(0, 'utf8')); } catch { process.exit(0); }
  const repoRoot = input.cwd || process.cwd();
  const c = classifyNotification(input);
  try {
    mkdirSync(path.join(repoRoot, '.rdc', 'logs'), { recursive: true });
    appendFileSync(path.join(repoRoot, '.rdc', 'logs', 'notifications.jsonl'),
      JSON.stringify({ ts: new Date().toISOString(), event: input.hook_event_name, type: input.notification_type, alert: c.alert }) + '\n');
  } catch { /* */ }
  if (c.alert && process.platform === 'win32') toast(c.title, c.body);
  process.exit(0);
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) main();
