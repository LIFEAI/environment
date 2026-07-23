#!/usr/bin/env pwsh
# cell-init.ps1 - regen-root terminal cell startup (PowerShell 7)
# Ported from cell-init.cmd on 2026-05-15.
# Approved: option-1 - Full port (SV + Claude). Interview: 2026-05-15 in session.
# Updated: 2026-06-25 - WP-2 worktree isolation. Each non-sv/non-specialist cell
#   enters its own crash-isolated sibling worktree at C:/Dev/regen-root.wt/<role>
#   (branch cell/<role>) via wt.mjs BEFORE launching claude. Restartable: relaunch
#   re-attaches to the existing worktree (idempotent). Graceful fallback to main tree
#   on wt.mjs error. Approved: worktree-isolation-recoverability-2026-06-25 plan.
# Usage: pwsh.exe -NoLogo -NoExit -ExecutionPolicy Bypass -File cell-init.ps1 <role> [-Worktree]
param(
  [string]$Role = 'sv',
  [switch]$Worktree,  # for sv/specialist: if passed, enter a worktree instead of main tree
  [string]$Resume = '',
  [string]$Instance = ''
)

if (-not $env:REGEN_ROOT) {
  Write-Host "`e[31mFATAL: REGEN_ROOT environment variable is not set.`e[0m"
  Write-Host "Set it to your monorepo root, e.g.:"
  Write-Host "  [Environment]::SetEnvironmentVariable('REGEN_ROOT', 'C:\Dev\regen-root', 'User')"
  Write-Host "Then restart your terminal."
  return
}
$repo = $env:REGEN_ROOT
$wtScript = Join-Path $repo 'scripts\wt.mjs'

# --- ROLE DEFINITIONS ---
$roles = @{
  'sv' = @{
    Label = 'SUPERVISOR'; Color = 32; Scope = 'Repo root -- monitors all cells'
    Paths = '.'
    Prompt = 'You are the SUPERVISOR cell. You have full repo access. Coordinate across all packages and apps.'
  }
  'cell-portal' = @{
    Label = 'PORTAL'; Color = 34; Scope = 'Frontend apps + packages/ui + models'
    Paths = 'apps/prt apps/rdc apps/place-fund apps/lifeai apps/regenity apps/future-city apps/rccs-admin apps/design-system packages/ui models'
    Prompt = 'You are the PORTAL cell. Only work on frontend apps: apps/prt, apps/rdc, apps/place-fund, apps/lifeai, apps/regenity, apps/future-city, apps/rccs-admin, apps/design-system, packages/ui, and models/. Do not modify backend packages or infrastructure.'
  }
  'cell-data' = @{
    Label = 'DATA'; Color = 36; Scope = 'Supabase, virtue-engine, pal, hail, daf-intelligence'
    Paths = 'packages/supabase packages/virtue-engine packages/pal packages/hail apps/daf-intelligence'
    Prompt = 'You are the DATA cell. Only work on: packages/supabase, packages/virtue-engine, packages/pal, packages/hail, apps/daf-intelligence. Do not modify frontend apps or infrastructure.'
  }
  'cell-cs2' = @{
    Label = 'CS2'; Color = 35; Scope = 'CS 2.0 packages + models'
    Paths = 'packages/cs2 packages/quad-pixel packages/planetary-ontology models'
    Prompt = 'You are the CS2 cell. Only work on CS 2.0 computational primitives: packages/cs2, packages/quad-pixel, packages/planetary-ontology, and models/. This is architecture work -- languages, compilers, memory systems -- not web app features.'
  }
  'cell-mktg' = @{
    Label = 'MARKETING'; Color = 33; Scope = 'Marketing engine, canvas, sites, email'
    Paths = 'apps/rdc-marketing-engine apps/canvas sites packages/email-templates'
    Prompt = 'You are the MARKETING cell. Only work on: apps/rdc-marketing-engine, apps/canvas, sites/, packages/email-templates. Do not modify core packages or other apps.'
  }
  'cell-infra' = @{
    Label = 'INFRA'; Color = 37; Scope = 'Coolify, CI, deployment, root config'
    Paths = '.'
    Prompt = 'You are the INFRA cell. Focus on deployment, Coolify, CI/CD, root config, scripts/, and infrastructure. Do not modify app business logic or UI components.'
  }
  'specialist' = @{
    Label = 'SPECIALIST'; Color = 31; Scope = 'Repo-wide: reviews, cleanup, docs, audits'
    Paths = '.'
    Prompt = 'You are the SPECIALIST cell. You do repo-wide reviews, cleanup, documentation, and audits. You have full access but your role is quality assurance, not feature development.'
  }
  'codex' = @{
    Label = 'CODEX'; Color = 36; Scope = 'Isolated worktree — Codex CLI'
    Paths = '.'
    Prompt = ''
  }
}

if (-not $roles.ContainsKey($Role)) {
  Write-Host "Unknown role: $Role"
  Write-Host "Valid: $($roles.Keys -join ', ')"
  return
}
$r = $roles[$Role]
$env:CELL_ROLE = $Role

# --- BANNER ---
$bar = '=' * 50
Write-Host ''
Write-Host "`e[$($r.Color)m$bar`e[0m"
Write-Host "`e[$($r.Color)m  $($r.Label)`e[0m"
Write-Host "`e[$($r.Color)m  $($r.Scope)`e[0m"
Write-Host "`e[$($r.Color)m$bar`e[0m"
Write-Host ''

# --- WORKTREE RESOLUTION ---
# Roles that enter a dedicated crash-isolated worktree: all cell-* roles and codex.
# Roles that stay on the main tree by default: sv, specialist.
# sv/specialist may optionally pass -Worktree to enter their own worktree.
$useWorktree = $false
$worktreeName = $null
$activeRoot = $repo  # start on main tree; updated below if worktree is used

$isCell = $Role.StartsWith('cell-')
$autoWorktree = $isCell -or $Role -eq 'codex'
if ($autoWorktree -or $Worktree) {
  # Worktree name = role name for automatic roles, except Codex gets an
  # x-prefixed physical identity so it cannot collide with Claude-owned names.
  # Optional sv/specialist worktrees get a cell-* prefix.
  $worktreeName = if ($Role -eq 'codex' -and $Instance) { $Instance } elseif ($Role -eq 'codex') { 'x-codex' } elseif ($autoWorktree) { $Role } else { "cell-$Role" }
  $wtDir = "C:\Dev\regen-root.wt\$worktreeName"

  # Codex launches via codex-worktree-launch.ps1 -> wt-pool, which has ALREADY
  # claimed + reset-to-fresh + installed deps + worktree-locked this exact lane and
  # passed it as -Instance. Re-running wt.mjs add here only duplicated the reattach +
  # env-propagation output (the "skipped twice" blocks). Adopt the prepared lane
  # directly instead.
  if ($Role -eq 'codex' -and $Instance -and (Test-Path -LiteralPath $wtDir)) {
    Write-Host "`e[90m-- Worktree (prepared by wt-pool) ----------------`e[0m"
    Write-Host "`e[32m  Lane ready: $wtDir`e[0m"
    Write-Host ''
    $useWorktree = $true
    $activeRoot = $wtDir
    Set-Location $activeRoot
    # fall through to lockfile + banners + launch below
  } else {

  Write-Host "`e[90m-- Worktree setup ($worktreeName) -------------------`e[0m"

  # Call wt.mjs add <name> --no-install to create/re-attach fast.
  # pnpm install was run at creation time; reattach is instant.
  # Use --no-install on relaunch to avoid blocking the cell startup on a full install.
  # A fresh worktree (first launch) will run pnpm install via the full path below.
  $wtExitCode = 0
  try {
    # First probe: does the worktree dir already exist?
    if (Test-Path $wtDir) {
      # Re-attach path: fast, just print status. wt.mjs add is idempotent.
      node $wtScript add $worktreeName --no-install
      $wtExitCode = $LASTEXITCODE
    } else {
      # Fresh worktree: full add (includes pnpm install + env propagation).
      node $wtScript add $worktreeName
      $wtExitCode = $LASTEXITCODE
    }
  } catch {
    $wtExitCode = 1
    Write-Host "`e[33mWARN: wt.mjs threw: $_`e[0m"
  }

  if ($wtExitCode -eq 0 -and (Test-Path $wtDir)) {
    $useWorktree = $true
    $activeRoot = $wtDir
    Write-Host "`e[32m  Worktree ready: $wtDir`e[0m"
  } else {
    if ($autoWorktree) {
      Write-Host "`e[31m  FATAL: isolated worktree setup failed (exit $wtExitCode).`e[0m"
      Write-Host "`e[31m  Refusing to run $Role in the shared main tree: $repo`e[0m"
      Write-Host "`e[31m  Fix the worktree error above, then relaunch this terminal profile.`e[0m"
      throw "isolated worktree setup failed for $worktreeName"
    }
    Write-Host "`e[33m  WARN: optional worktree setup failed (exit $wtExitCode) -- falling back to main tree ($repo)`e[0m"
    Write-Host "`e[33m  Supervisor/specialist will run in the SHARED tree.`e[0m"
  }
  Write-Host ''
  }
}

# Move into the active working directory (worktree or main tree).
Set-Location $activeRoot

# --- LOCKFILE (actual PID + branch + worktree path) ---
$stateDir = Join-Path $repo '.cell-state'
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir | Out-Null }
$branch = (git -C $activeRoot rev-parse --abbrev-ref HEAD 2>$null)
@(
  "PID=$PID"
  "STARTED=$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')"
  "BRANCH=$branch"
  "ROLE=$Role"
  "TREE=$activeRoot"
  "WORKTREE=$useWorktree"
) | Set-Content -Path (Join-Path $stateDir "$worktreeName.lock") -Encoding ascii

# --- GIT STATUS ---
Write-Host "`e[90m-- Git ------------------------------------------`e[0m"
Write-Host "  Branch: `e[1m$branch`e[0m"
$changes = @(git -C $activeRoot status --porcelain 2>$null).Where({ $_ }).Count
if ($changes -eq 0) { Write-Host "  Working tree: `e[32mclean`e[0m" }
else { Write-Host "  Working tree: `e[33m$changes changes`e[0m" }
Write-Host ''

# --- WORKTREE STATUS BANNER ---
if ($useWorktree) {
  Write-Host "`e[90m-- Worktree --------------------------------------`e[0m"
  Write-Host "  `e[32mISOLATED`e[0m tree: `e[1m$activeRoot`e[0m"
  Write-Host "  Branch: `e[1m$branch`e[0m  (isolated from shared C:\Dev\regen-root)"
  Write-Host "  Crash/abort: uncommitted work is PRESERVED -- relaunch to re-attach."
  Write-Host ''
} else {
  Write-Host "`e[90m-- Worktree --------------------------------------`e[0m"
  Write-Host "  `e[33mMAIN tree`e[0m: `e[1m$activeRoot`e[0m  (shared -- not crash-isolated)"
  Write-Host ''
}

# --- SCOPE-FILTERED RECENT COMMITS ---
Write-Host "`e[90m-- Recent commits ($($r.Label)) ---------------------`e[0m"
if ($r.Paths -eq '.') {
  git -C $activeRoot log --oneline -5 2>$null
} else {
  git -C $activeRoot log --oneline -5 -- $r.Paths.Split(' ') 2>$null
}
Write-Host ''

# --- CELL PROMPT ---
$global:RDC_CELL_COLOR = $r.Color
$global:RDC_CELL_LABEL = $r.Label
function global:prompt {
  "`e[$($global:RDC_CELL_COLOR)m[$($global:RDC_CELL_LABEL)]`e[0m $($PWD.Path)> "
}

# --- LAUNCH CLAUDE CODE WITH CELL SCOPE ---
# Windows: disable the fullscreen alternate-screen renderer. Its interval-driven
# re-render storm outpaces ConPTY, blocks the Node input loop, and cascades a
# freeze across every tab of the shared WindowsTerminal process.
# Refs: anthropics/claude-code #59992, #23211.
$env:CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN = '1'

# Surface the startup status table in the VISIBLE terminal for EVERY pane, before launch.
# It cannot be left to the engine for either role:
#   - Codex's harness does NOT surface SessionStart-hook stdout at all.
#   - Claude Code delivers SessionStart-hook stdout only to the session CONTEXT, not to
#     the visible terminal, so a claude pane (sv + every cell role) starts BLIND to
#     startup status. This was the root cause the 228ee3185 mis-fix missed: it patched
#     start-agent-cockpit.ps1's unused claude/--resume branch, but the SV pane (dropdown
#     and cockpit) launches THROUGH here as a fresh --append-system-prompt session.
# Run the shared session-start.sh with the matching engine before launch. For codex the
# engine's SessionStart hook no longer runs the guard, so this is its single run. For
# claude the engine's hook still runs the guard afterward; the guard's own mutex makes
# that second run a cheap defer.
$startEngine = if ($Role -eq 'codex') { 'codex' } else { 'claude' }
$bashExe = 'C:/Program Files/Git/bin/bash.exe'
if (Test-Path -LiteralPath $bashExe) {
  & $bashExe "$repo/.claude/hooks/session-start.sh" $startEngine
} else {
  Write-Host "`e[33m  WARN: $bashExe not found - cannot emit startup status table.`e[0m"
}

Write-Host "`e[90m-- Launching $($r.Label) -------------`e[0m"
Write-Host ''
try {
  # Claude and other TUIs can enable DEC focus reporting. If that mode leaks
  # back to the shell, focus changes show up as ESC[I / ESC[O and can corrupt
  # the next prompt or trigger accidental input. Reset it around the TUI.
  [Console]::Out.Write("`e[?1004l")
  if ($Role -eq 'codex' -and $Resume) {
    if ($Resume -eq 'last') { codex --cd $activeRoot --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust resume --last }
    else { codex --cd $activeRoot --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust resume $Resume }
  } elseif ($Role -eq 'codex') { codex --cd $activeRoot --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust }
  else { claude --append-system-prompt $r.Prompt }
} finally {
  [Console]::Out.Write("`e[?1004l")
  if ($Role -eq 'codex') {
    # Codex has no SessionEnd hook; run the expensive worktree/process cleanup
    # once after the Codex process exits instead of once at every turn Stop.
    try {
      & "$repo/scripts/cleanup-agent-jobs.ps1" -RepoRoot $repo -MinAgeSeconds 15 -CleanAgentBrowsers -CleanAgentDevServers
    } catch {
      Write-Host "`e[33mWARN: session-exit cleanup failed: $_`e[0m"
    }
  }
}
