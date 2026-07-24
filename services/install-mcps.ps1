#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Verify and install MCP servers declared in mcps.json.
.PARAMETER ProjectRoot
  Path to the consuming monorepo (for codeflow build).
.PARAMETER Fix
  Attempt to install/start missing local MCPs.
#>
param(
  [string]$ProjectRoot = $env:PROJECT_ROOT,
  [switch]$Fix
)

$ErrorActionPreference = 'Stop'
$envRoot = $PSScriptRoot | Split-Path
$mcpsFile = Join-Path $PSScriptRoot 'mcps.json'
$clauthBase = 'http://127.0.0.1:52437'

if (-not $ProjectRoot) { $ProjectRoot = 'C:/Dev/regen-root' }

function Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red }

if (-not (Test-Path $mcpsFile)) {
  Fail "mcps.json not found at $mcpsFile"
  exit 1
}

$config = Get-Content $mcpsFile -Raw | ConvertFrom-Json

Write-Host "`n=== Local MCP Servers ===" -ForegroundColor Cyan

foreach ($name in $config.local.PSObject.Properties.Name) {
  $mcp = $config.local.$name
  $healthUrl = $mcp.health

  $isUp = $false
  if ($healthUrl) {
    try {
      $r = Invoke-WebRequest -UseBasicParsing -Uri $healthUrl -TimeoutSec 3 -ErrorAction Stop
      $isUp = $r.StatusCode -ge 200 -and $r.StatusCode -lt 300
    } catch { $isUp = $false }
  }

  if ($isUp) {
    Ok "${name}: running ($healthUrl)"
  } else {
    Warn "${name}: not running"
    if ($Fix) {
      Write-Host "    Attempting start: $($mcp.start)" -ForegroundColor Gray
      try {
        Push-Location $ProjectRoot
        Invoke-Expression $mcp.start 2>&1 | Out-Null
        Start-Sleep 3
        if ($healthUrl) {
          $r2 = Invoke-WebRequest -UseBasicParsing -Uri $healthUrl -TimeoutSec 5 -ErrorAction Stop
          if ($r2.StatusCode -ge 200) { Ok "${name}: started successfully" }
          else { Fail "${name}: started but health check failed" }
        }
      } catch {
        Fail "${name}: start failed — $($_.Exception.Message)"
      } finally {
        Pop-Location
      }
    }
  }
}

Write-Host "`n=== Remote MCP Servers ===" -ForegroundColor Cyan

foreach ($name in $config.remote.PSObject.Properties.Name) {
  $mcp = $config.remote.$name
  $issues = @()

  if ($mcp.endpoint_clauth) {
    try {
      $ep = (Invoke-RestMethod -Uri "$clauthBase/v/$($mcp.endpoint_clauth)" -TimeoutSec 3).Trim()
      if (-not $ep -or $ep -match 'not found|locked') { $issues += "endpoint $($mcp.endpoint_clauth) not in clauth" }
    } catch { $issues += "clauth unreachable for $($mcp.endpoint_clauth)" }
  }

  if ($mcp.secret_clauth) {
    try {
      $sk = (Invoke-RestMethod -Uri "$clauthBase/v/$($mcp.secret_clauth)" -TimeoutSec 3).Trim()
      if (-not $sk -or $sk -match 'not found|locked') { $issues += "secret $($mcp.secret_clauth) not in clauth" }
    } catch { $issues += "clauth unreachable for $($mcp.secret_clauth)" }
  }

  if ($mcp.health) {
    try {
      $r = Invoke-WebRequest -UseBasicParsing -Uri $mcp.health -TimeoutSec 5 -ErrorAction Stop
      if ($r.StatusCode -lt 200 -or $r.StatusCode -ge 300) { $issues += "health check failed ($($r.StatusCode))" }
    } catch { $issues += "health unreachable" }
  }

  if ($issues.Count -eq 0) {
    Ok "${name}: credentials + health verified"
  } else {
    Warn "${name}: $($issues -join '; ')"
  }
}

Write-Host "`n=== claude.ai Connectors ===" -ForegroundColor Cyan
Write-Host "  Manual setup in claude.ai Settings > Integrations:" -ForegroundColor Gray
foreach ($connector in $config.claude_ai_connectors.required) {
  Write-Host "    - $connector" -ForegroundColor Gray
}
Write-Host ""
