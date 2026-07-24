#!/usr/bin/env node
// PreToolUse hook — HARD-BLOCK deploy-intent when the target app's PUBLISH.md has no
// valid <!-- DEPLOY --> block (or hardcodes a port instead of `port: registry`).
//
// Contract: .claude/rules/app-deploy-manifest.md (Approved 2026-07-05, Dave).
// A DEPLOY block that nothing reads is theater — this forces it to exist and be current
// BEFORE anything deploys. Fail-open: only blocks when the target positively resolves to a
// PUBLISH.md that lacks a valid block. Unknown/ambiguous targets are allowed (logged).
//
// Schema: write { decision: 'block', reason } to stdout + exit 0 to block.
'use strict';

const fs = require('fs');
const path = require('path');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const SCAN_ROOTS = ['apps', 'sites', 'models', 'packages', 'mcp-servers'];

let input = '';
process.stdin.resume();
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => { input += c; });
process.stdin.on('end', () => {
  let parsed;
  try { parsed = JSON.parse(input); } catch (_) { process.exit(0); }

  const tool = parsed.tool_name || '';
  const ti = parsed.tool_input || {};

  // ── 1. Detect deploy-intent + extract target token(s) ──────────────────────
  const targets = new Set();
  let intent = false;

  if (tool === 'Bash') {
    const cmd = ti.command || '';
    // pm2 start/restart/reload ... --only <a,b>  OR  pm2 start <name>
    const only = cmd.match(/pm2\s+(?:start|restart|reload)\b[^\n]*--only\s+([^\s'"]+)/);
    if (only) { intent = true; only[1].split(',').forEach((t) => targets.add(t)); }
    // rdc:deploy <slug> typed into a shell
    const rdc = cmd.match(/rdc:deploy\s+([a-z0-9][a-z0-9-]*)/i);
    if (rdc) { intent = true; targets.add(rdc[1]); }
  } else if (tool === 'Skill') {
    const skill = (ti.skill || '').toLowerCase();
    if (skill === 'deploy' || skill === 'rdc:deploy' || skill === 'rdc-deploy') {
      intent = true;
      const first = String(ti.args || '').trim().split(/\s+/)[0];
      if (first) targets.add(first);
    }
  }

  if (!intent || targets.size === 0) process.exit(0);

  // ── 2. Build PUBLISH.md index (token → file, file → validity) ──────────────
  const index = new Map(); // normalized token -> file path
  const files = [];
  for (const base of SCAN_ROOTS) {
    const root = path.join(REPO_ROOT, base);
    let dirs = [];
    try { dirs = fs.readdirSync(root); } catch (_) { continue; }
    for (const d of dirs) {
      const p = path.join(root, d, 'PUBLISH.md');
      if (fs.existsSync(p)) files.push({ file: p, dir: d });
    }
  }

  const norm = (t) => String(t).replace(/^@[^/]+\//, '').toLowerCase();
  const record = {}; // file -> { valid, hardcodedPort }
  for (const { file, dir } of files) {
    let text = '';
    try { text = fs.readFileSync(file, 'utf8'); } catch (_) { continue; }
    const block = text.match(/<!-- DEPLOY -->[\s\S]*?<!-- \/DEPLOY -->/);
    const hasBlock = !!block;
    const b = block ? block[0] : '';
    const portLine = b.match(/^port:\s*(.+)$/m);
    const hardcodedPort = !!(portLine && !/registry/i.test(portLine[1]));
    const valid = hasBlock && /runtime:/.test(b) && /health_path:/.test(b) && !hardcodedPort;
    record[file] = { valid, hasBlock, hardcodedPort };

    // token keys: dir basename, entity_slug, block slug(s), pm2 names in start_command
    index.set(norm(dir), file);
    const es = text.match(/^entity_slug:\s*([^\s#]+)/m);
    if (es) index.set(norm(es[1]), file);
    const slugsComment = b.match(/#\s*slugs?:\s*([^\n—-]+)/);
    if (slugsComment) slugsComment[1].split(',').forEach((s) => index.set(norm(s.trim()), file));
    const start = b.match(/^start_command:\s*.*--only\s+([^\s'"]+)/m);
    if (start) start[1].split(',').forEach((n) => index.set(norm(n), file));
  }

  // ── 3. For each resolvable target, block if its block is missing/invalid ────
  for (const t of targets) {
    const file = index.get(norm(t));
    if (!file) continue; // unknown target → fail open
    const r = record[file];
    if (r && !r.valid) {
      const rel = path.relative(REPO_ROOT, file).replace(/\\/g, '/');
      const why = !r.hasBlock
        ? 'has NO <!-- DEPLOY --> block'
        : r.hardcodedPort
          ? 'hardcodes a port (must be `port: registry`)'
          : 'has an incomplete <!-- DEPLOY --> block';
      const response = {
        decision: 'block',
        reason: [
          `⛔ DEPLOY BLOCKED — target "${t}" ${why}.`,
          `   ${rel}`,
          '',
          'Every deployable MUST carry a valid <!-- DEPLOY --> block before it can deploy.',
          '(.claude/rules/app-deploy-manifest.md — Approved 2026-07-05).',
          '',
          'Fix — regenerate the block from the registry (port stays in the DB):',
          '  node scripts/gen-deploy-blocks.mjs --slug ' + t,
          '',
          'If the app is not in app_deployments yet, register it first (apps + app_deployments),',
          'then run the generator. Do NOT hand-write a port — it resolves from app_deployments.pm2_port.',
        ].join('\n'),
      };
      process.stdout.write(JSON.stringify(response));
      process.exit(0);
    }
  }

  process.exit(0);
});
