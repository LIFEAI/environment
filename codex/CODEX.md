# Regen Root — Codex Delta
> **AGENTS.md is the shared source of truth** — read it first before this file.
> [`AGENTS.md`](file:///C:/Dev/regen-root/AGENTS.md) covers stack, session start, CodeFlow, credentials, work items, branch rules, and behavioral rules.
> This file contains ONLY Codex-specific additions.

---

## Default Model & Keyless Image Generation (gpt-image-2)

Default Codex model is **`gpt-5.5`** (set in `~/.codex/config.toml`). Do **not** leave
the default on `gpt-5.3-codex-spark` — the coding model does **not** carry the hosted
`image_generation` (gpt-image-2) tool, so an image request silently falls back to MCP
or renders at a fixed ~1672×941. Verified: same request under `codex-spark` → 1672×941;
under `gpt-5.5` with the recipe below → true `3840×2160`.

**Fully keyless** — runs on the ChatGPT **Pro** subscription (OAuth in `~/.codex/auth.json`),
**no `OPENAI_API_KEY`**. Preconditions:
`codex login status` → `Logged in using ChatGPT`; `codex features list | grep image_generation` → `stable true`.

### The four things that make size actually apply
gpt-image-2 through Codex ignores size **unless all four hold** (codex bug #19175 — a
size hint in the prompt text alone is ignored):
1. `--enable image_generation`
2. `-c model=gpt-5.5` (a model that carries the tool)
3. explicit instruction: **"use the built-in image_gen tool DIRECTLY; do not write API keys, scripts, or MCP"**
4. name the target `size` (`2048x2048` = 2K, `3840x2160` = 4K) in the instruction

### Pattern A — text → image (verified 3840×2160)
```bash
echo "Use the built-in image_gen tool DIRECTLY at size 3840x2160 (4K). No API keys/scripts/MCP. \
Copy the PNG to output/imagegen/<name>.png and reply with only that path + pixel dims. \
Prompt: <dense art-directed prompt>." | \
codex exec --enable image_generation --dangerously-bypass-approvals-and-sandbox --cd "$PWD" -c model=gpt-5.5
```

### Pattern B — image → image / upscale / edit (attach source with `-i`)
Attach one or more source images with `-i <FILE>` (repeatable); the built-in tool
re-renders **from** them. Use this to upscale an existing render to 4K or edit it while
preserving composition:
```bash
echo "Use the built-in image_gen tool DIRECTLY to re-render the ATTACHED image at size 3840x2160 (4K), \
preserving its composition, subject, palette, and lighting (upscale/re-render, not a new scene). \
No API keys/scripts/MCP. Save to output/imagegen/<name>-4k.png and reply with only the path + dims." | \
codex exec -i "input/source.png" --enable image_generation --dangerously-bypass-approvals-and-sandbox --cd "$PWD" -c model=gpt-5.5
```

### Notes
- **Latency ~2–5 min** — Codex reasons before the tool fires. Use a Bash timeout ≥ 300000 ms; run in background.
- **Output lands twice:** the tool writes `~/.codex/generated_images/<session-id>/ig_*.png`, and the instruction's copy step writes your named path. If the copy step is skipped, grab the newest `ig_*.png` from the session dir.
- **Sizes:** `1024x1024`, `1536x1024`, `1024x1536`, `2048x2048`, `2048x1152`, `3840x2160`, `2160x3840`, `auto`. Constraints: max edge ≤3840, both edges multiples of 16, ratio ≤3:1; **>2560×1440 is experimental**.
- **Local-only.** This keyless path needs the local `codex` login; it cannot run in a remote container. The deployed **regen-media MCP `generate_gpt_image`** tool is the server-side equivalent and needs `OPENAI_API_KEY` (paid) — see [`mcp-servers/regen-media/CLAUDE.md`](file:///C:/Dev/regen-root/mcp-servers/regen-media/CLAUDE.md).
- Full gpt-image-2 CLI/API reference: `~/.codex/skills/.system/imagegen/references/{cli,image-api}.md`.

---

## Codex Worktree

Codex default: `C:\Dev\regen-root.wt\x-codex` on `wt/x-codex`.
Claude default: `C:\Dev\regen-root` on `develop`.
Each agent uses its own worktree — never share a working tree with a running session.

Your `wt/x-codex` lane is reset to fresh `origin/develop` by the pool when claimed — but the supervisor main tree is NOT auto-reset. Always `git fetch && git status -sb` and pull before reasoning about file contents (AGENTS.md §Session Start step 0). `truth=behind_remote` means stale local files even when `git status` looks clean.

**Always land to develop after committing.** Commit on your lane branch, then
immediately run `node scripts/land.mjs` to land on develop. Never leave work
stranded on the lane branch — stranded commits are lost work. Never raw
`git push origin develop` (hook blocks it). Deploy to PM2 dev if the change
touches a deployable app. Never push to `main`.

---

## Goal Mode

- `/goal` mode is the default for long-horizon implementation work (Studio rebuilds, theme refactors, multi-step RDC execution).
- `/goal` does not replace RDC discipline: plan docs, work items, and falsifiable test plans are still required.
- If the local Codex build does not expose `/goal`, report that explicitly instead of silently downgrading behavior.
- `[shell_environment_policy] inherit = "all"` and `goals = true` must be set in `.codex/config.toml`.

---

## Temporal Context Protocol

Codex SessionStart runs [`scripts/temporal-context.mjs start --engine codex`](file:///C:/Dev/regen-root/scripts/temporal-context.mjs) and managed Stop records [`.rdc/last_seen.json`](file:///C:/Dev/regen-root/.rdc/last_seen.json). If startup output is not visible in the transcript, run `node scripts/temporal-context.mjs start --engine codex` before intake. Treat its real clock, previous marker, git delta, and CodeFlow diff as the only chronology evidence; elapsed time by itself is not proof that anything changed.

---

## Deliverables Manifest Gate

Before starting any project, epic, or multi-work-item implementation, Codex MUST show Dave the deliverables table in chat. Not optional, even in `/goal` mode.

Required columns: Work item ID · Deliverable/screen/endpoint/artifact · Route or file path · Acceptance check · Verification evidence required · Status.

For UI work, list every screen and state as separate rows. If the user names a count such as "20 screens", the table must contain exactly that many rows or explicitly mark missing/unknown rows. Do not write code until this table has been shown.

---

## Planning Requirements

`rdc:plan` must create: epic with `p_definition_of_done`, child work items per package, falsifiable test plan as checklist items.
Types (`assert`+`smoke` mandatory; `visual` for UI; `contract` for new exports/API shapes): `test-assert-*` · `test-smoke-*` · `test-visual-*` · `test-contract-*`.
Required items must be ticked with `update_checklist_item`. `update_work_item_status(..., 'done')` rejects unchecked required items.

---

## Credentials

Full credential rules: [AGENTS.md §Credentials & Supabase](file:///C:/Dev/regen-root/AGENTS.md).
Health check: `curl.exe -s http://127.0.0.1:52437/ping`. If down, restart once: `& .\scripts\restart-clauth.bat` then re-ping. If still down, stop and ask Dave.

---

## Build Safety

No full `pnpm build` without `--filter` — hooks enforce this for both engines
(Claude via [`.claude/settings.json`](file:///C:/Dev/regen-root/.claude/settings.json),
Codex via managed [`.codex/requirements.managed.toml`](file:///C:/Dev/regen-root/.codex/requirements.managed.toml)
installed at `C:\ProgramData\OpenAI\Codex\requirements.toml`).
Use `npx tsc --noEmit` for type checks; scoped builds only: `pnpm --filter @regen/<app> build`.

---

## Work Items

Full protocol: see [AGENTS.md §Work Items](file:///C:/Dev/regen-root/AGENTS.md) and [`.claude/rules/work-items-rpc.md`](file:///C:/Dev/regen-root/.claude/rules/work-items-rpc.md).

---

## Truth Gate & RDC-Compliance Commit Gate — MANDATORY every turn

Codex Stop, SubagentStop, PreToolUse, PermissionRequest, PreCompact, and PostToolUse
guards are managed hooks, not per-worktree trust hooks. The repo mirror is
[`.codex/requirements.managed.toml`](file:///C:/Dev/regen-root/.codex/requirements.managed.toml);
the live policy is `C:\ProgramData\OpenAI\Codex\requirements.toml`. Startup drift checks
verify that live policy and `pnpm env:patch` reinstalls it when missing or stale.

1. **Truth Gate runs as a managed Stop hook.** Do not end on a capability claim
   ("works", "100%", "deployed and working", "up and running", "verified end-to-end",
   etc.) unless a valid needle receipt exists. The always-available exit is to
   **downgrade to a structural fact** — "PR #N opened", "tsc exit 0", "N rows ingested",
   "committed <sha>". Honest structural reporting is the correct, expected outcome.
2. **Every code commit is gated at commit time.** [`.githooks/commit-msg`](file:///C:/Dev/regen-root/.githooks/commit-msg)
   → [`scripts/rdc-commit-gate.mjs`](file:///C:/Dev/regen-root/scripts/rdc-commit-gate.mjs)
   **rejects** any commit staging `apps/`|`packages/`|`sites/`|`models/` files that lacks a
   `Work-Item: <uuid>` trailer (or an explicit, audited `RDC-Bypass: <reason>` trailer). Add
   the trailer from the epic/task you claimed via `insert_work_item` / `get_open_epics`. This
   is engine-agnostic — it fires on your `git commit` exactly as it does for Claude and a
   human. Do not work around it; run the RDC lifecycle (epic → work items → CodeFlow finalize
   → implementation report → validator closure). The plan's markdown checklist is NOT the
   gate — the `work_items` RPC lifecycle + CodeFlow finalize is.

---

## Local Terminal Recovery

For stuck WezTerm windows: [`·claude/rules/terminal-recovery.md`](file:///C:/Dev/regen-root/.claude/rules/terminal-recovery.md).
Preserve running panes first. Suspend/resume `wezterm-gui.exe` with `NtSuspendProcess`/`NtResumeProcess` before killing anything.
