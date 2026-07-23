#!/usr/bin/env pwsh
# codex-worktree-launch.ps1 - launch Codex in a warm x-codex-N pool lane.
#
# Thin wrapper over the ONE shared pool engine (scripts/wt-pool.mjs) - the same
# engine claude-iso.ps1 uses for claude-N. There is no second pool implementation:
# wt-pool claims a lane (atomic lockfile + dead-owner reclaim), keeps it fresh
# (rebase if behind), installs deps if incomplete, and git-worktree-locks it. This
# wrapper just picks the x-codex prefix and hands the lane to cell-init to launch
# Codex. The bespoke Select-CodexLane / Global mutex / .cell-state lease are gone -
# they were a parallel re-implementation of wt-pool that drifted.
param(
  [int]$MaxWarm = 12,
  [string]$Resume = '',
  [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'

if (-not $env:REGEN_ROOT) { throw 'REGEN_ROOT environment variable is not set.' }
$repo = $env:REGEN_ROOT
$cellInit = Join-Path $repo 'scripts\cell-init.ps1'
$wtPool = Join-Path $repo 'scripts\wt-pool.mjs'
if (-not (Test-Path -LiteralPath $cellInit)) { throw "Missing startup script: $cellInit" }
if (-not (Test-Path -LiteralPath $wtPool)) { throw "Missing pool engine: $wtPool" }

# Use the official standalone launcher. It updates by switching its own managed
# runtime, so new Terminal sessions do not need to overwrite executables held by
# existing Codex jobs in npm's global package directory.
$standaloneBin = Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin'
$standaloneCodex = Join-Path $standaloneBin 'codex.exe'
if (-not (Test-Path -LiteralPath $standaloneCodex)) {
  throw "Codex standalone launcher is missing: $standaloneCodex. Install it with https://chatgpt.com/codex/install.ps1."
}
$env:PATH = "$standaloneBin;$env:PATH"
# A launcher inherited from an npm-managed Codex process can carry these markers
# into a fresh shell and cause `codex update` to select npm's locked in-place
# updater. This profile exclusively uses the standalone executable.
Remove-Item Env:CODEX_MANAGED_BY_NPM -ErrorAction SilentlyContinue
Remove-Item Env:CODEX_MANAGED_PACKAGE_ROOT -ErrorAction SilentlyContinue

# Claim an x-codex lane via the shared pool engine. stdout = absolute lane path;
# all progress on stderr. Stamp THIS launcher's PID as the slot owner so a
# hard-closed window's lane is reclaimed once this process is gone (reclaimDead).
$env:CLAUDE_OWNER_PID = $PID
$path = & node $wtPool claim --prefix x-codex --lock --size $MaxWarm
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($path)) {
  throw "Codex worktree pool claim failed (exit $LASTEXITCODE)."
}
$path = ($path | Select-Object -Last 1).Trim()
$lane = ($path -split '[\\/]' | Where-Object { $_ } | Select-Object -Last 1)

# Pool-full -> wt-pool returns the MAIN tree path. Codex must stay isolated, so
# refuse rather than run on the shared tree (parity with cell-init's codex policy).
if ((($path -replace '\\', '/')) -eq (($repo -replace '\\', '/'))) {
  throw "Codex worktree pool is full (all $MaxWarm x-codex lanes held by live sessions). Close a Codex session and retry."
}
if ($lane -notmatch '^x-codex-\d+$') {
  throw "wt-pool returned an unexpected lane '$lane' (path: $path)."
}

if ($NoLaunch) {
  Write-Output $lane
  return
}

# Hand the resolved lane to cell-init for the actual Codex launch. Release the pool
# CLAIM slot when the session exits; the git worktree-lock keeps the lane warm.
try {
  if ($Resume) { & $cellInit codex -Instance $lane -Resume $Resume }
  else { & $cellInit codex -Instance $lane }
} finally {
  & node $wtPool release $lane 2>$null | Out-Null
}
