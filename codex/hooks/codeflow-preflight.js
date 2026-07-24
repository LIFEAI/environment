#!/usr/bin/env node
/**
 * Codex PreToolUse hook for CodeFlow enforcement.
 *
 * This is intentionally a Codex adapter, not a direct Claude hook copy:
 * Codex supports PreToolUse deny via hookSpecificOutput.permissionDecision,
 * but does not reliably inject additionalContext during PreToolUse.
 */
'use strict';

const http = require('node:http');
const https = require('node:https');

const BASE = process.env.CODEFLOW_BASE_URL || 'http://127.0.0.1:3109';
const TIMEOUT_MS = Number(process.env.CODEFLOW_HOOK_TIMEOUT_MS || 3500);
const STDIN_TIMEOUT_MS = Number(process.env.CODEFLOW_HOOK_STDIN_TIMEOUT_MS || 5000);
const MODEL_CLIENT = process.env.CODEFLOW_MODEL_CLIENT || 'codex';

function postJson(path, body) {
  return new Promise((resolve) => {
    let url;
    try {
      url = new URL(path, BASE);
    } catch {
      return resolve({ ok: false, status: 0, body: { error: 'bad_url' } });
    }
    const client = url.protocol === 'https:' ? https : url.protocol === 'http:' ? http : null;
    if (!client) return resolve({ ok: false, status: 0, body: { error: 'unsupported_protocol' } });

    const data = JSON.stringify(body || {});
    const req = client.request({
      method: 'POST',
      hostname: url.hostname,
      port: url.port || (url.protocol === 'https:' ? 443 : 80),
      path: url.pathname + (url.search || ''),
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(data),
      },
      timeout: TIMEOUT_MS,
    }, (res) => {
      let buf = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => { buf += chunk; });
      res.on('end', () => {
        let parsed = null;
        try { parsed = JSON.parse(buf); } catch { parsed = { raw: buf }; }
        resolve({ ok: res.statusCode >= 200 && res.statusCode < 300, status: res.statusCode, body: parsed });
      });
    });

    req.on('error', (err) => resolve({ ok: false, status: 0, body: { error: err.code || err.message } }));
    req.on('timeout', () => {
      req.destroy();
      resolve({ ok: false, status: 0, body: { error: 'timeout' } });
    });
    req.write(data);
    req.end();
  });
}

async function readEvent() {
  return new Promise((resolve) => {
    let input = '';
    let settled = false;
    let timer = null;
    const finish = () => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      try { resolve(JSON.parse(input || '{}')); } catch { resolve({}); }
    };
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => { input += chunk; });
    process.stdin.on('end', finish);
    process.stdin.on('error', finish);
    process.stdin.resume();
    timer = setTimeout(finish, STDIN_TIMEOUT_MS);
    if (typeof timer.unref === 'function') timer.unref();
  });
}

function asObject(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
}

function getToolName(event) {
  return String(
    event.tool_name ||
    event.toolName ||
    event.tool ||
    event.name ||
    event.recipient_name ||
    event?.call?.name ||
    ''
  );
}

function getToolInput(event) {
  return asObject(
    event.tool_input ||
    event.toolInput ||
    event.input ||
    event.arguments ||
    event.args ||
    event?.call?.arguments ||
    {}
  );
}

function collectStrings(value, out = []) {
  if (typeof value === 'string') {
    out.push(value);
  } else if (Array.isArray(value)) {
    for (const item of value) collectStrings(item, out);
  } else if (value && typeof value === 'object') {
    for (const item of Object.values(value)) collectStrings(item, out);
  }
  return out;
}

function extractPatchFiles(input) {
  const text = collectStrings(input).join('\n');
  const files = [];
  const seen = new Set();
  const re = /^\*\*\* (?:Add|Update|Delete) File: (.+)$/gm;
  let match;
  while ((match = re.exec(text))) {
    const file = match[1].trim();
    if (file && !seen.has(file)) {
      seen.add(file);
      files.push(file);
    }
  }
  return files;
}

function editBody(files, toolName) {
  const body = {
    files,
    model_client: MODEL_CLIENT,
  };
  if (process.env.CODEFLOW_WORK_ITEM_ID) {
    body.work_item_id = process.env.CODEFLOW_WORK_ITEM_ID;
  }
  if (toolName) {
    body.service = String(toolName).slice(0, 120);
  }
  return body;
}

function pickRoute(event) {
  const rawName = getToolName(event);
  const toolName = rawName.toLowerCase();
  const input = getToolInput(event);

  if (toolName.includes('apply_patch')) {
    const files = extractPatchFiles(input);
    if (!files.length) return null;
    return {
      path: '/api/codeflow/preflight/edit',
      eventKind: 'preflight_edit',
      toolName: rawName || 'apply_patch',
      body: editBody(files, rawName || 'apply_patch'),
    };
  }

  if (toolName === 'edit' || toolName === 'write' || toolName === 'multiedit' || toolName === 'notebookedit' || toolName.endsWith('.edit') || toolName.endsWith('.write')) {
    const file = input.file_path || input.path || input.filename;
    if (!file) return null;
    return {
      path: '/api/codeflow/preflight/edit',
      eventKind: 'preflight_edit',
      toolName: rawName,
      body: editBody([file], rawName),
    };
  }

  if (toolName === 'read' || toolName.endsWith('.read') || toolName.includes('read_mcp_resource')) {
    const file = input.file_path || input.path || input.uri;
    if (!file) return null;
    return {
      path: '/api/codeflow/preflight/read',
      eventKind: 'preflight_read',
      toolName: rawName,
      body: { file, model_client: MODEL_CLIENT },
    };
  }

  if (toolName === 'grep' || toolName === 'glob' || toolName.includes('rg') || toolName.includes('search')) {
    const pattern = input.pattern || input.query || input.q || '';
    const paths = input.path ? [input.path] : [];
    return {
      path: '/api/codeflow/preflight/search',
      eventKind: 'preflight_search',
      toolName: rawName,
      body: { pattern: String(pattern).slice(0, 500), path: paths[0], model_client: MODEL_CLIENT },
    };
  }

  if (toolName === 'bash' || toolName === 'shell' || toolName === 'shell_command' || toolName.includes('shell_command') || toolName.includes('exec_command')) {
    const command = String(input.command || input.cmd || input.script || '');
    const parsed = parseShellReadOrSearch(command);
    if (!parsed) return null;
    return {
      path: '/api/codeflow/preflight/search',
      eventKind: 'raw_search',
      toolName: rawName || 'shell_command',
      body: { pattern: parsed.pattern, model_client: MODEL_CLIENT },
    };
  }

  return null;
}

function shellTokens(command) {
  const tokens = [];
  const re = /"([^"\\]*(?:\\.[^"\\]*)*)"|'([^']*)'|([^\s|;&]+)/g;
  let match;
  while ((match = re.exec(String(command || '')))) {
    tokens.push(match[1] ?? match[2] ?? match[3] ?? '');
  }
  return tokens;
}

function optionNeedsValue(tool, token) {
  if (!token || token === '--') return false;
  if (tool === 'rg') {
    return /^(?:-g|--glob|-t|--type|-T|--type-not|-C|--context|-A|--after-context|-B|--before-context|-m|--max-count|--sort|--sortr|--type-add)$/i.test(token);
  }
  if (tool === 'grep') {
    return /^(?:-e|--regexp|-f|--file|-A|--after-context|-B|--before-context|-C|--context|--include|--exclude|--exclude-dir)$/i.test(token);
  }
  return false;
}

function parseShellReadOrSearch(command) {
  const tools = new Set(['rg', 'grep', 'cat', 'head', 'tail', 'sed', 'awk', 'find', 'ls', 'get-content', 'select-string', 'get-childitem']);
  const tokens = shellTokens(command);
  const index = tokens.findIndex((token) => tools.has(String(token).toLowerCase()));
  if (index < 0) return null;
  const tool = String(tokens[index]).toLowerCase();
  let skipValue = false;
  for (let i = index + 1; i < tokens.length; i += 1) {
    const token = tokens[i];
    if (!token) continue;
    if (skipValue) {
      skipValue = false;
      continue;
    }
    if (token === '--') continue;
    if (optionNeedsValue(tool, token)) {
      if (tool === 'grep' && (token === '-e' || token === '--regexp')) {
        const next = tokens[i + 1];
        return next ? { tool, pattern: next } : null;
      }
      skipValue = true;
      continue;
    }
    if (token.startsWith('-')) continue;
    return { tool, pattern: token };
  }
  return null;
}

function emitAllow() {
  process.stdout.write('{}');
}

function emitDeny(reason) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason,
    },
  }));
}

function isPlannedMaintenanceResponse(resp) {
  const body = resp && resp.body;
  return resp && resp.status === 503 && (
    body?.error?.code === 'codeflow_planned_maintenance' ||
    body?.upgrade?.paused === true ||
    body?.upgrade?.mode === 'planned_maintenance'
  );
}

function routeAllowedDuringPlannedMaintenance(route) {
  return route?.eventKind === 'preflight_read'
    || route?.eventKind === 'preflight_search'
    || route?.eventKind === 'raw_search';
}

function plannedMaintenanceMessage(resp) {
  const retry = resp?.body?.error?.retry_after_seconds || resp?.body?.upgrade?.retry_after_seconds || 30;
  const fallback = resp?.body?.upgrade?.fallback?.search || 'grep';
  return `[codeflow PLANNED-DOWNTIME] CodeFlow is intentionally paused for planned maintenance; use file-tree reads/search using ${fallback}. Retry CodeFlow work after ${retry}s.`;
}

function emitPlannedMaintenanceDecision(route, resp) {
  const message = plannedMaintenanceMessage(resp);
  if (!routeAllowedDuringPlannedMaintenance(route)) {
    emitDeny(`${message} ${route?.toolName || 'tool'} is deferred during planned downtime.`);
    return;
  }
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      additionalContext: message,
    },
  }));
}

async function run() {
  const event = await readEvent();
  const route = pickRoute(event);
  if (!route) {
    emitAllow();
    return;
  }

  const resp = await postJson(route.path, route.body);
  if (isPlannedMaintenanceResponse(resp)) {
    emitPlannedMaintenanceDecision(route, resp);
    return;
  }
  if (process.env.CODEFLOW_HOOK_DEBUG) {
    process.stderr.write(`[codex-codeflow-preflight] ${route.eventKind} ${route.path} ok=${resp.ok} status=${resp.status} session=${resp.body && resp.body.context_session_id ? resp.body.context_session_id : 'n/a'}\n`);
  }
  let policy = resp.body && resp.body.policy;

  if (!policy && route.eventKind === 'raw_search') {
    const polResp = await postJson('/api/codeflow/policy/check', {
      kind: 'raw_search',
      model_client: MODEL_CLIENT,
      context_session_id: resp.body && resp.body.context_session_id,
    });
    if (process.env.CODEFLOW_HOOK_DEBUG) {
      process.stderr.write(`[codex-codeflow-preflight] policy raw_search ok=${polResp.ok} status=${polResp.status} decision=${polResp.body && polResp.body.decision ? polResp.body.decision : 'n/a'}\n`);
    }
    policy = polResp.body;
  }

  if (!resp.ok && resp.status === 0) {
    const polResp = await postJson('/api/codeflow/policy/check', {
      kind: 'codeflow_unavailable',
      model_client: MODEL_CLIENT,
    });
    policy = polResp.ok ? polResp.body : { decision: 'record_bypass', reason: 'codeflow_unreachable_and_policy_unreachable' };
  }

  const decision = (policy && policy.decision) || 'allow';
  const reason = (policy && policy.reason) || 'no_policy';
  const sessionId = (resp.body && resp.body.context_session_id) || 'n/a';

  if (decision === 'block' || decision === 'require_preflight') {
    emitDeny(`[codeflow] ${decision} for ${route.toolName} (${route.eventKind}): ${reason}. Context session: ${sessionId}.`);
    return;
  }

  emitAllow();
}

module.exports = {
  pickRoute,
  parseShellReadOrSearch,
  optionNeedsValue,
};

if (require.main === module) {
  run().catch((err) => {
    process.stderr.write(`[codex-codeflow-preflight] hook error: ${err.message}\n`);
    emitAllow();
  });
}
