#!/usr/bin/env pwsh
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$Name,

  [string]$Repo = $env:REGEN_ROOT,

  [switch]$NoInstall,

  [switch]$Quiet,

  [switch]$PrintOnly
)

$ErrorActionPreference = "Stop"

if (-not $Repo) {
  $Repo = "C:\Dev\regen-root"
}

$Repo = (Resolve-Path -LiteralPath $Repo).Path
$wtScript = Join-Path $Repo "scripts\wt.mjs"
if (-not (Test-Path -LiteralPath $wtScript)) {
  throw "wt.mjs not found at $wtScript"
}

$wtRoot = "$Repo.wt"
$wtDir = Join-Path $wtRoot $Name

if ($PrintOnly) {
  Write-Output $wtDir
  return
}

$wtArgs = @($wtScript, "add", $Name)
if ($NoInstall -or (Test-Path -LiteralPath $wtDir)) {
  $wtArgs += "--no-install"
}

if ($Quiet) {
  & node @wtArgs *> $null
} else {
  & node @wtArgs | ForEach-Object { Write-Host $_ }
}
if ($LASTEXITCODE -ne 0) {
  exit $LASTEXITCODE
}

if (-not (Test-Path -LiteralPath $wtDir)) {
  throw "Expected worktree was not created: $wtDir"
}

Write-Output $wtDir
