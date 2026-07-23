#!/usr/bin/env pwsh
# claude-iso.ps1 — launch Claude Code in a warm pool worktree (cd-into model).
#
# Approved: option-1 warm-pool + sv-on-main. Interview: 2026-06-27.
#
# "Force every ad-hoc Claude session to be worktree-isolated" lives HERE, at the
# launcher. Rather than the (undocumented) `claude --worktree` flag, this wrapper
# CLAIMS a warm pool slot, cd's into it, then launches PLAIN `claude`. The slot is
# released on exit. Re-attaching a warm slot is instant; a cold install is ~100s.
#
# Behavior:
#   - Already inside a sibling worktree (C:/Dev/regen-root.wt/*) OR a `-p`/--print
#     non-interactive run → pass through (plain `claude`, no claim, no cd). Cells
#     already isolate; print runs are not auto-cleaned and stay on the caller's tree.
#   - Otherwise → claim a pool slot via `node scripts/wt-pool.mjs claim` (stdout =
#     path only), cd into it, launch PLAIN `claude`, and release the slot on exit.
#
# The SUPERVISOR intentionally stays on the main tree — do NOT route sv through
# this wrapper, and do NOT alias `claude` to it in the sv shell (it needs the
# integration tree for merges/coordination).
#
# Activate (opt-in) by adding a function to your pwsh profile, e.g.:
#   function claude { & 'C:/Dev/regen-root/scripts/claude-iso.ps1' @args }
# Then relaunch the shell. Bypass once with the real binary: `claude.cmd ...`.
#
# RDC_TEST=1 → dry-run: print the intended actions (claim path, cd, claude args,
# and that NO --worktree flag is used) WITHOUT launching claude.
param([Parameter(ValueFromRemainingArguments = $true)] $Rest)

$repoRoot = 'C:/Dev/regen-root'
$cwd = (Get-Location).Path -replace '\\', '/'
$inWorktree = $cwd -like 'C:/Dev/regen-root.wt/*'
$nonInteractive = ($Rest -contains '-p') -or ($Rest -contains '--print')
# SV-GUARD: the supervisor stays on the main integration tree (merges/coordination).
# This makes a GLOBAL `function claude { claude-iso ... }` safe to install — it will
# pass through plainly in the sv shell instead of isolating the supervisor.
$isSupervisor = $env:CELL_ROLE -eq 'sv'

# --- Passthrough: supervisor, already isolated, or a -p/--print run → plain claude, no claim.
if ($isSupervisor -or $inWorktree -or $nonInteractive) {
  if ($env:RDC_TEST -eq '1') {
    Write-Host "[RDC_TEST] passthrough mode (isSupervisor=$isSupervisor inWorktree=$inWorktree nonInteractive=$nonInteractive)"
    Write-Host "[RDC_TEST] would run: claude $($Rest -join ' ')"
    Write-Host "[RDC_TEST] NO --worktree flag is used."
    exit 0
  }
  & claude.cmd @Rest
  exit $LASTEXITCODE
}

# --- Claim a warm pool slot. stdout = absolute worktree path; stderr passes through.
# Stamp THIS launcher's PID as the slot owner: if the window is hard-closed (the
# finally-release below never runs), a later claim reclaims the slot once this
# process is gone (wt-pool reclaimDead → kill(pid,0) === ESRCH).
$env:CLAUDE_OWNER_PID = $PID
$path = & node "$repoRoot/scripts/wt-pool.mjs" claim
if ($LASTEXITCODE -eq 2) {
  # Pool full. Isolated-or-SV only: there is NO un-isolated main-tree fallback for a
  # worker session. The supervisor runs on the main tree via the sv passthrough above.
  Write-Error "claude-iso: the Claude worktree pool is FULL. Close a Claude session (or raise the pool size) and relaunch. (The supervisor runs on the main tree via the sv passthrough.)"
  exit 2
}
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($path)) {
  Write-Error "claude-iso: wt-pool claim failed (exit $LASTEXITCODE)"
  exit 1
}
$path = ($path | Select-Object -Last 1).Trim()
$slot = ($path -split '[\\/]' | Where-Object { $_ } | Select-Object -Last 1)

if ($env:RDC_TEST -eq '1') {
  # Dry-run: show intended actions, then release the slot we just claimed.
  Write-Host "[RDC_TEST] claim path: $path"
  Write-Host "[RDC_TEST] cd $path"
  Write-Host "[RDC_TEST] claude $($Rest -join ' ')"
  Write-Host "[RDC_TEST] NO --worktree flag is used."
  & node "$repoRoot/scripts/wt-pool.mjs" release $slot | Out-Null
  exit 0
}

$code = 1
try {
  Set-Location -LiteralPath $path
  # Emit the startup status table in the VISIBLE terminal before launching Claude
  # (parity with cell-init's Codex path). Claude Code also runs session-start.sh as
  # its own SessionStart hook for model context; this is the user-visible copy.
  $bashExe = 'C:/Program Files/Git/bin/bash.exe'
  if (Test-Path -LiteralPath $bashExe) { & $bashExe "$repoRoot/.claude/hooks/session-start.sh" claude }
  & claude.cmd @Rest
  $code = $LASTEXITCODE
} finally {
  & node "$repoRoot/scripts/wt-pool.mjs" release $slot | Out-Null
}
exit $code
