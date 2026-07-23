#!/usr/bin/env pwsh
param(
  [switch]$Json,
  [string]$ProjectRoot = $env:PROJECT_ROOT
)

$ErrorActionPreference = 'Stop'

if (-not $ProjectRoot) {
  $configPath = Join-Path $PSScriptRoot '..' 'projects.json'
  if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $ProjectRoot = $config.projects.'regen-root'.path
  }
}

if (-not $ProjectRoot -or -not (Test-Path $ProjectRoot)) {
  Write-Error "PROJECT_ROOT not set or does not exist: $ProjectRoot"
  exit 1
}

$lockFile = Join-Path $ProjectRoot 'environment.lock.json'
if (-not (Test-Path $lockFile)) {
  Write-Error "No environment.lock.json at $lockFile"
  exit 1
}

$lock = Get-Content $lockFile -Raw | ConvertFrom-Json
$results = @()
$allPass = $true

function Get-InstalledVersion($tool) {
  switch ($tool) {
    'node'       { (node --version 2>$null) -replace '^v', '' }
    'pnpm'       { pnpm --version 2>$null }
    'pm2'        { pm2 --version 2>$null }
    'gh'         { ((gh --version 2>$null) -split ' ')[2] -replace ',', '' }
    'clauth'     {
      try {
        $ping = Invoke-RestMethod -Uri 'http://127.0.0.1:52437/ping' -TimeoutSec 3
        $ping.app_version
      } catch { $null }
    }
    'rdc-skills' {
      try {
        $json = npm list -g '@lifeai/rdc-skills' --depth=0 --json 2>$null | ConvertFrom-Json
        $json.dependencies.'@lifeai/rdc-skills'.version
      } catch { $null }
    }
    default      { $null }
  }
}

function Compare-SemVer($installed, $minimum) {
  if (-not $installed) { return $false }
  $iv = [version]($installed -replace '[^0-9.]', '' -replace '^\.' , '' -replace '\.$', '')
  $mv = [version]($minimum -replace '[^0-9.]', '' -replace '^\.' , '' -replace '\.$', '')
  return $iv -ge $mv
}

foreach ($prop in $lock.required_tools.PSObject.Properties) {
  $tool = $prop.Name
  $spec = $prop.Value
  $installed = Get-InstalledVersion $tool
  $meets = Compare-SemVer $installed $spec.min_version
  if (-not $meets) { $allPass = $false }
  $results += [pscustomobject]@{
    tool         = $tool
    min_version  = $spec.min_version
    installed    = if ($installed) { $installed } else { 'NOT FOUND' }
    pass         = $meets
    install_hint = $spec.install
  }
}

if ($Json) {
  @{ ok = $allPass; checked_at = (Get-Date -Format 'o'); project_root = $ProjectRoot; results = $results } |
    ConvertTo-Json -Depth 3
} else {
  Write-Host "`nEnvironment Audit — $ProjectRoot" -ForegroundColor Cyan
  Write-Host ('-' * 60)
  foreach ($r in $results) {
    $mark = if ($r.pass) { '  PASS' } else { '  FAIL' }
    $color = if ($r.pass) { 'Green' } else { 'Red' }
    Write-Host "$mark  $($r.tool): $($r.installed) (requires >= $($r.min_version))" -ForegroundColor $color
  }
  Write-Host ('-' * 60)
  if ($allPass) {
    Write-Host '  All tools meet requirements.' -ForegroundColor Green
  } else {
    Write-Host '  DRIFT DETECTED — run install commands above.' -ForegroundColor Red
    $results | Where-Object { -not $_.pass } | ForEach-Object {
      Write-Host "    $($_.tool): $($_.install_hint)" -ForegroundColor Yellow
    }
  }
}

if (-not $allPass) { exit 1 }
