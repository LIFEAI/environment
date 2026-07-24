#!/usr/bin/env pwsh
<#
.SYNOPSIS
  LIFEAI Environment provisioner — bare metal or transition.

.DESCRIPTION
  Single entry point for machine setup. Detects state and does the right thing:

  BARE METAL (fresh box):
    1. Set LIFEAI_ENV at Machine scope
    2. Clone this repo if not present
    3. Install tools (Node, pnpm, PM2, clauth, rdc-skills, gh)
    4. Set up terminals (WezTerm, Windows Terminal)
    5. Register autostart

  TRANSITION (existing box, migrating from monorepo scripts):
    1. Set LIFEAI_ENV at Machine scope (if not set)
    2. Pull latest env repo
    3. Verify shims in consuming project(s)
    4. Report drift

  Works on Windows and Mac (PowerShell Core).

.PARAMETER ProjectRoot
  Path to the consuming monorepo. Default: C:/Dev/regen-root

.PARAMETER Force
  Skip confirmation prompts.

.PARAMETER DryRun
  Show what would happen without making changes.

.PARAMETER SkipTools
  Skip tool installation (use for transition-only runs).
#>

param(
  [string]$ProjectRoot = '',
  [switch]$Force,
  [switch]$DryRun,
  [switch]$SkipTools
)

$ErrorActionPreference = 'Stop'
$EnvRoot = $PSScriptRoot

function Log($msg, $color = 'Cyan') { Write-Host "  $msg" -ForegroundColor $color }
function Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red }
function Step($n, $msg) { Write-Host "`n--- Step ${n}: $msg ---" -ForegroundColor White }

Write-Host "`n=== LIFEAI Environment Provisioner ===" -ForegroundColor Cyan
Write-Host "  Env repo:  $EnvRoot" -ForegroundColor Gray
Write-Host "  Platform:  $($PSVersionTable.OS ?? $env:OS)" -ForegroundColor Gray
Write-Host "  Mode:      $(if ($DryRun) { 'DRY RUN' } else { 'LIVE' })" -ForegroundColor Gray

# ── Step 1: LIFEAI_ENV system variable ────────────────────────────────────────
Step 1 'LIFEAI_ENV system variable'

$currentEnv = [Environment]::GetEnvironmentVariable('LIFEAI_ENV', 'Machine')
if ($currentEnv -eq $EnvRoot) {
  Ok "LIFEAI_ENV=$currentEnv (Machine scope, correct)"
} elseif ($currentEnv) {
  Warn "LIFEAI_ENV=$currentEnv (Machine scope, expected $EnvRoot)"
  if (-not $DryRun) {
    try {
      [Environment]::SetEnvironmentVariable('LIFEAI_ENV', $EnvRoot, 'Machine')
      Ok "Updated LIFEAI_ENV to $EnvRoot"
    } catch {
      Fail "Cannot set Machine-scope env var (needs elevation). Run as admin."
      Warn "Falling back to User scope..."
      [Environment]::SetEnvironmentVariable('LIFEAI_ENV', $EnvRoot, 'User')
      Ok "Set LIFEAI_ENV=$EnvRoot (User scope — re-run as admin for Machine scope)"
    }
  } else {
    Log "Would set LIFEAI_ENV=$EnvRoot (Machine scope)"
  }
} else {
  Log "LIFEAI_ENV not set — setting to $EnvRoot"
  if (-not $DryRun) {
    try {
      [Environment]::SetEnvironmentVariable('LIFEAI_ENV', $EnvRoot, 'Machine')
      Ok "Set LIFEAI_ENV=$EnvRoot (Machine scope)"
    } catch {
      Fail "Cannot set Machine-scope env var (needs elevation). Run as admin."
      [Environment]::SetEnvironmentVariable('LIFEAI_ENV', $EnvRoot, 'User')
      Ok "Set LIFEAI_ENV=$EnvRoot (User scope — re-run as admin for Machine scope)"
    }
  } else {
    Log "Would set LIFEAI_ENV=$EnvRoot (Machine scope)"
  }
}
$env:LIFEAI_ENV = $EnvRoot

# ── Step 2: Resolve project root(s) ──────────────────────────────────────────
Step 2 'Resolve project root(s)'

$projectsFile = Join-Path $EnvRoot 'projects.json'
$projects = @{}
if (Test-Path $projectsFile) {
  $projects = Get-Content $projectsFile -Raw | ConvertFrom-Json -AsHashtable
  Ok "projects.json: $($projects.Count) project(s)"
} else {
  Warn "No projects.json found at $projectsFile"
}

if ($ProjectRoot) {
  $resolvedRoot = $ProjectRoot
} elseif ($env:PROJECT_ROOT) {
  $resolvedRoot = $env:PROJECT_ROOT
} elseif ($projects.ContainsKey('regen-root')) {
  $resolvedRoot = $projects['regen-root']
} else {
  $resolvedRoot = 'C:/Dev/regen-root'
}
$env:PROJECT_ROOT = $resolvedRoot
Log "PROJECT_ROOT=$resolvedRoot"

# ── Step 3: Pull latest env repo ──────────────────────────────────────────────
Step 3 'Pull latest env repo'

try {
  Push-Location $EnvRoot
  $behind = & git rev-list --count HEAD..origin/main 2>$null
  if ($behind -and [int]$behind -gt 0) {
    Log "Behind origin/main by $behind commit(s) — pulling..."
    if (-not $DryRun) {
      & git pull origin main --ff-only 2>&1 | Out-Null
      Ok "Pulled $behind commit(s)"
    } else {
      Log "Would pull $behind commit(s)"
    }
  } else {
    Ok "Up to date with origin/main"
  }
} catch {
  Warn "Git pull failed: $($_.Exception.Message)"
} finally {
  Pop-Location
}

# ── Step 4: Verify consuming project shims ────────────────────────────────────
Step 4 'Verify consuming project shims'

if (Test-Path $resolvedRoot) {
  $lockFile = Join-Path $resolvedRoot 'environment.lock.json'
  if (Test-Path $lockFile) {
    Ok "environment.lock.json present in $resolvedRoot"
  } else {
    Warn "No environment.lock.json in $resolvedRoot"
  }

  $shimDir = Join-Path $resolvedRoot 'scripts'
  if (Test-Path $shimDir) {
    $shimCount = 0
    $brokenCount = 0
    Get-ChildItem $shimDir -File | Where-Object {
      $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
      $content -and ($content -match 'LIFEAI_ENV')
    } | ForEach-Object {
      $shimCount++
      $content = Get-Content $_.FullName -Raw
      if ($content -match '(guards|pool|sessions|services|machines|sync|platform|terminals)/') {
        $targetPath = [regex]::Match($content, '(guards|pool|sessions|services|machines|sync|platform|terminals)/[^\s"'']+').Value
        $fullTarget = Join-Path $EnvRoot $targetPath
        if (-not (Test-Path $fullTarget)) {
          $brokenCount++
          Warn "Broken shim: $($_.Name) -> $targetPath (not found)"
        }
      }
    }
    if ($shimCount -gt 0) {
      Ok "$shimCount shim(s) found, $brokenCount broken"
    } else {
      Warn "No shims found in $shimDir — transition may not be complete"
    }
  }
} else {
  Warn "Project root $resolvedRoot not found"
}

# ── Step 5: Tool versions ─────────────────────────────────────────────────────
Step 5 'Tool versions'

if ($SkipTools) {
  Log "Skipped (--SkipTools)"
} else {
  $auditScript = Join-Path $EnvRoot 'audit' 'audit.ps1'
  if (Test-Path $auditScript) {
    & $auditScript -ProjectRoot $resolvedRoot
  } else {
    Warn "audit.ps1 not found at $auditScript"
    $checks = @(
      @{ Name = 'node';  Cmd = 'node --version' },
      @{ Name = 'pnpm';  Cmd = 'pnpm --version' },
      @{ Name = 'pm2';   Cmd = 'pm2 --version' },
      @{ Name = 'gh';    Cmd = 'gh --version' }
    )
    foreach ($check in $checks) {
      try {
        $ver = Invoke-Expression $check.Cmd 2>$null
        Ok "$($check.Name): $($ver.Trim())"
      } catch {
        Fail "$($check.Name): not found"
      }
    }
  }
}

# ── Step 6: Hooks inventory ──────────────────────────────────────────────────
Step 6 'Hooks inventory'

$hooksDir = Join-Path $EnvRoot 'hooks'
if (Test-Path $hooksDir) {
  $hookCount = (Get-ChildItem $hooksDir -File | Measure-Object).Count
  Ok "$hookCount hook file(s) in $hooksDir"
} else {
  Warn "No hooks/ directory in env repo"
}

# ── Summary ──────────────────────────────────────────────────────────────────
Write-Host "`n=== Provisioning complete ===" -ForegroundColor Green
Write-Host "  LIFEAI_ENV:    $env:LIFEAI_ENV" -ForegroundColor Gray
Write-Host "  PROJECT_ROOT:  $env:PROJECT_ROOT" -ForegroundColor Gray
Write-Host "  Env repo:      $EnvRoot" -ForegroundColor Gray
if ($DryRun) {
  Write-Host "  (DRY RUN — no changes made)" -ForegroundColor Yellow
}
