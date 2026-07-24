#!/bin/bash
# SessionStart hook — verify local infrastructure before agent work.
#
# IMPORTANT: a SessionStart hook CANNOT hard-abort a Claude Code session — a non-zero
# exit is not honored as a block (proven 2026-06-14: the guard exited 1 at the
# agent-readiness step and the session started anyway). So on failure we do NOT pretend
# to abort. Instead we raise a loud, unmissable STOP banner on stdout, which Claude Code
# injects into the session as context for both Dave and the agent. The banner IS the gate.

REPO_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
GUARD_LOG="$REPO_ROOT/.codex/agent-startup-guard.log"
skip_corpus_sync=0

# ONE shared SessionStart entry for BOTH engines (no per-engine wrapper).
# Engine is passed by the hook ("claude" | "codex"); defaults to claude.
# ANY warm pool lane — x-codex-N OR claude-N — is auto-detected from the cwd leaf so
# the guard can prove it READY for edits via -CodexLane. This is the SECOND freshness
# gate behind wt-pool.mjs claim(): if a session lands in a pool lane WITHOUT going
# through claim() (or claim's ensureFresh somehow didn't fire), Get-CodexLaneStatus
# still re-proves the lane is 0/0 vs a freshly-fetched origin/develop (auto-rebasing a
# behind-only lane) and FAILS startup otherwise — closing the "started working, 15
# commits behind" bypass for BOTH engines' lanes. (-CodexLane is legacy naming; the
# proof is engine-agnostic.) Passing `-Force [-CodexLane <lane>]` as DISTINCT argv to
# `pwsh -File` binds them as NAMED params (the path verified to work) — this is
# precisely what the old codex-startup-guard.ps1 got wrong by array-splatting
# `@('-Force', ...)` into the first positional [int] parameter.
ENGINE="${1:-claude}"
lane_args=()
cwd_leaf="$(basename "$(pwd -W 2>/dev/null || pwd)")"
if [[ "$cwd_leaf" =~ ^(x-codex|claude)-[0-9]+$ ]]; then
  lane_args=(-CodexLane "$cwd_leaf")
fi

# Render a compact ✅/❌ table from THIS run's guard-log lines (passed in $1). A
# component is ✅ iff it logged "<key>: ready" this run; otherwise ❌ with its last
# line as the detail. Adds a working-tree-validity row (catches the stranded-cwd
# bug — a dir with no .git) and a footer stating the CURRENT pool-full rule.
render_startup_table() {
  # $2 deferred=1 means THIS run did not do the bring-up itself — it short-circuited
  # to a concurrent/fresh guard run (mutex held elsewhere, or services proven fresh).
  # In that case a service's ready line may live just BEFORE this run's log slice (the
  # concurrent run wrote it), so falling back to only "$lines" shows a FALSE ❌ while the
  # summary says "verified ready". When deferred, read the recent full log and show ✅ if
  # the concurrent run has that service ready, else ⏳ (verifying) — never a false ❌.
  local lines="$1" deferred="${2:-0}" keys labels i key label mark detail
  keys=(clauth codeflow rdc-skills dev-center corpus environment-repo agent-readiness dev-tools)
  labels=("clauth daemon" "CodeFlow" "rdc-skills" "Dev Center" "Corpus root" "Environment repo" "Agent readiness" "Dev tools")
  # Startup-sequence version — single source of truth in .rdc/startup-version.json. Shown for
  # BOTH engines (Codex reuses this table via cell-init.ps1) so Dave can eyeball at a glance
  # that a Claude session and a Codex session are running the SAME startup/hook contract.
  local sv; sv="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$REPO_ROOT/.rdc/startup-version.json" 2>/dev/null | head -1)"
  printf '\n── %s startup ── v%s ────────────────────────────────\n' "${ENGINE^}" "${sv:-UNKNOWN}"
  for i in "${!keys[@]}"; do
    key="${keys[$i]}"; label="${labels[$i]}"
    if printf '%s\n' "$lines" | grep -qa "] ${key}: ready"; then
      mark="✅"
      detail="$(printf '%s\n' "$lines" | grep -a "] ${key}: ready" | tail -1 | sed -E "s/.*${key}: ready ?//")"
      [ -z "$detail" ] && detail="ready"
    elif [ "$deferred" = "1" ] && tail -n 150 "$GUARD_LOG" 2>/dev/null | grep -qa "] ${key}: ready"; then
      mark="✅"
      detail="ready (concurrent startup check)"
    elif [ "$deferred" = "1" ]; then
      mark="⏳"
      detail="verifying via concurrent startup check (not a failure)"
    else
      mark="❌"
      detail="$(printf '%s\n' "$lines" | grep -a "] ${key}:" | tail -1 | sed -E 's/^\[[^]]*\] *[^:]*: *//')"
      [ -z "$detail" ] && detail="no ready line this run"
    fi
    printf '  %s  %-16s %s\n' "$mark" "$label" "$detail"
  done
  # Working-tree validity: main/sv tree, or a git-registered worktree, else stranded.
  local cwd root_w
  cwd="$(pwd -W 2>/dev/null || pwd)"
  root_w="$(cd "$REPO_ROOT" && pwd -W 2>/dev/null || echo "$REPO_ROOT")"
  if [ "${cwd,,}" = "${root_w,,}" ]; then
    printf '  %s  %-16s %s\n' "✅" "Working tree" "$cwd (main / supervisor tree)"
  elif [ -e "$cwd/.git" ] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '  %s  %-16s %s\n' "✅" "Working tree" "$cwd (registered worktree)"
  else
    printf '  %s  %-16s %s\n' "❌" "Working tree" "$cwd — NOT a valid worktree (no .git); work from $root_w"
  fi
  printf '  ┄ isolated-or-SV: a worker session runs in a pool worktree; the supervisor runs on the main tree. Log: .codex/agent-startup-guard.log\n\n'
}

# Mark where the guard log ends now, so afterward we can emit ONLY this run's lines.
startup_log_mark="$(wc -l < "$GUARD_LOG" 2>/dev/null || echo 0)"

# Run the startup guard. The guard itself restarts clauth, rdc-skills, CodeFlow, and the
# Dev Center as needed and exits non-zero if any component cannot be brought up.
# Capture stdout so we can detect a deferral (mutex held elsewhere / fresh short-circuit)
# while still showing it to the session. The guard runs to completion before we render.
# Resolve startup guard from $LIFEAI_ENV (environment repo) with monorepo fallback
GUARD_SCRIPT="${LIFEAI_ENV:-C:/Dev/lifeai-env}/guards/agent-startup-guard.ps1"
[ ! -f "$GUARD_SCRIPT" ] && GUARD_SCRIPT="$REPO_ROOT/scripts/agent-startup-guard.ps1"
guard_out="$(pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
  -File "$GUARD_SCRIPT" -Force "${lane_args[@]}")"
guard_status=$?
printf '%s\n' "$guard_out"

# This run deferred to a concurrent/fresh guard run iff it emitted one of the
# short-circuit lines instead of running the per-service bring-up itself. In that case
# the checklist must read the recent log, not just this run's slice (else false ❌).
deferred=0
if printf '%s' "$guard_out" | grep -qiE 'another startup check is already running|agent-startup: ready$'; then
  deferred=1
fi

# Stream each guard step into the session. The guard records per-step status
# (clauth, rdc-skills, codeflow, dev-center, corpus, agent-readiness) to GUARD_LOG;
# emit just this run's lines (timestamp stripped, begin/end banners dropped) so Dave
# and the agent see what came up — not only the one-line summary below.
if [ -f "$GUARD_LOG" ]; then
  run_lines="$(tail -n +"$((startup_log_mark + 1))" "$GUARD_LOG" 2>/dev/null | grep -av '==== agent startup guard')"
  render_startup_table "$run_lines" "$deferred"
fi

if [ $guard_status -ne 0 ]; then
  reason="$(grep -a 'FAILED:' "$GUARD_LOG" 2>/dev/null | tail -1 | sed 's/^\[[^]]*\] *//')"
  [ -z "$reason" ] && reason="agent-startup-guard exited $guard_status (see .codex/agent-startup-guard.log)"
  if printf '%s' "$reason" | grep -qi 'CORPUS ROOT UNRESOLVED'; then
    skip_corpus_sync=1
    cat <<EOF

🛑🛑🛑  STOP — CORPUS ROOT UNRESOLVED  🛑🛑🛑
Corpus-relative paths are unsafe in this session. Do NOT trust corpus lookups,
document conversion, project scaffolding, or any workflow that reads or writes
through \$CORPUS_ROOT until this is fixed.

  Failure: $reason

Fix the corpus root, then start a new session:
  • Expected env:   CORPUS_ROOT=C:/rdc-gdrive/global-corpus
  • Hydrate:        make global-corpus "Available offline" in Google Drive
  • Full guard:     powershell -File scripts/agent-startup-guard.ps1 -Force
  • Log:            .codex/agent-startup-guard.log
🛑🛑🛑  -----------------------------------  🛑🛑🛑

EOF
  else
    cat <<EOF

🛑🛑🛑  STOP — LOCAL ENVIRONMENT NOT READY  🛑🛑🛑
The startup guard could not bring the environment up cleanly. Do NOT treat clauth,
CodeFlow, Dev Center, or corpus paths as confirmed — credential, codeflow,
corpus, and deploy ops are unsafe until this clears.

  Failure: $reason

Restart the environment, then start a new session:
  • Desktop:        double-click "Restart clauth"
  • Full guard:     powershell -File scripts/agent-startup-guard.ps1 -Force
  • Readiness only: pnpm agent:readiness
  • Log:            .codex/agent-startup-guard.log
🛑🛑🛑  ---------------------------------------  🛑🛑🛑

EOF
  fi
  # No exit here on purpose — the banner above is the STOP sign. Exiting non-zero would
  # only print a swallowed hook error without blocking the session.
else
  if [ "${#lane_args[@]}" -gt 0 ]; then
    echo "agent-startup: clauth, CodeFlow, corpus root, and Dev Center verified ready; ${ENGINE} lane ${cwd_leaf} ready for edits"
  else
    echo "agent-startup: clauth, CodeFlow, corpus root, and Dev Center verified ready"
  fi
fi

# Inspect only the current, bounded operational-log window. This is intentionally
# best-effort: SessionStart must surface an incident without holding the session open.
run_codeflow_log_sentinel() {
  local sentinel="$REPO_ROOT/scripts/codeflow-log-sentinel.mjs" output status
  [ -f "$sentinel" ] || return 0
  if command -v timeout >/dev/null 2>&1; then
    output="$(timeout 4s node "$sentinel" --remote-alert --since 24h 2>/dev/null)"
    status=$?
  else
    node "$sentinel" --remote-alert --since 24h >/tmp/codeflow-log-sentinel.$$ 2>/dev/null &
    local pid=$! elapsed=0
    while kill -0 "$pid" 2>/dev/null && [ "$elapsed" -lt 4 ]; do sleep 1; elapsed=$((elapsed + 1)); done
    if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; status=124; else wait "$pid"; status=$?; fi
    output="$(cat /tmp/codeflow-log-sentinel.$$ 2>/dev/null)"
    rm -f /tmp/codeflow-log-sentinel.$$
  fi
  case "$status" in
    0) echo "codeflow-log-sentinel: clean 24h window" ;;
    2) printf 'CODEFLOW LOG ESCALATION (24h): %s\n' "$output" ;;
    124) echo "codeflow-log-sentinel: skipped after strict 4s timeout" ;;
    *) echo "codeflow-log-sentinel: unavailable (nonblocking)" ;;
  esac
}
run_codeflow_log_sentinel

# Sync deployment registry from Supabase (best-effort, never blocks the session)
if [ -f "$REPO_ROOT/scripts/sync-claude-apps.mjs" ]; then
  node "$REPO_ROOT/scripts/sync-claude-apps.mjs" >/dev/null 2>&1 && echo "sync:docs: refreshed" || echo "sync:docs: skipped (no Supabase key)"
fi

# Self-provision the local corpus cache from the Google Drive master (best-effort, fully
# detached so it NEVER blocks startup). On a fresh box (e.g. Carbon7) with no local-corpus
# this does the full mirror in the background; thereafter the script's freshness guard makes
# it a sub-second no-op. Exits 0 on its own when H: is not mounted (headless boxes).
SYNC_CORPUS="${LIFEAI_ENV:-C:/Dev/lifeai-env}/sync/sync-corpus.ps1"
[ ! -f "$SYNC_CORPUS" ] && SYNC_CORPUS="$REPO_ROOT/scripts/sync-corpus.ps1"
if [ -f "$SYNC_CORPUS" ]; then
  if [ "$skip_corpus_sync" -eq 1 ]; then
    echo "corpus: sync skipped (CORPUS_ROOT unresolved)"
  else
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -Command \
      "Start-Process pwsh -WindowStyle Hidden -ArgumentList '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File','$SYNC_CORPUS'" \
      >/dev/null 2>&1 && echo "corpus: sync launched (background)" || echo "corpus: sync launch skipped"
  fi
fi
