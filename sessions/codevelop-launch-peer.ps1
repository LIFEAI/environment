param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("claude", "codex")]
  [string]$Peer,

  [string]$Repo = "C:\Dev\regen-root",

  [switch]$PrintOnly
)

$ErrorActionPreference = "Stop"

$stateDir = Join-Path $Repo ".rdc\co-develop"
$activePath = Join-Path $stateDir "active.json"

if (-not (Test-Path -LiteralPath $activePath)) {
  throw "No active co-develop session found at $activePath. Run scripts\codevelop-start.ps1 first."
}

$active = Get-Content -LiteralPath $activePath -Raw | ConvertFrom-Json
$manifestPath = $active.manifest
if (-not $manifestPath -or -not (Test-Path -LiteralPath $manifestPath)) {
  throw "Active co-develop manifest is missing: $manifestPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$peerConfig = $manifest.peers.$Peer
if (-not $peerConfig) {
  throw "Manifest $manifestPath does not define peer '$Peer'"
}

$targetPeer = $peerConfig.target_peer
$baseUrl = $manifest.transport.base_url
$sessionId = $manifest.session_id
$cwd = $peerConfig.cwd
if ($Peer -eq "codex" -and (-not $cwd -or -not (Test-Path -LiteralPath $cwd))) {
  $wtEnterScript = Join-Path $Repo "scripts\wt-enter.ps1"
  if (-not (Test-Path -LiteralPath $wtEnterScript)) {
    throw "wt-enter helper not found at $wtEnterScript"
  }
  $cwdResult = @(& pwsh -NoProfile -ExecutionPolicy Bypass -File $wtEnterScript "x-codex" -Repo $Repo -NoInstall -Quiet)
  if ($LASTEXITCODE -ne 0 -or $cwdResult.Count -eq 0) {
    throw "Failed to enter x-codex worktree"
  }
  $cwd = $cwdResult[$cwdResult.Count - 1]
}

$env:CODEVELOP_SESSION = $sessionId
$env:CODEVELOP_PEER = $Peer
$env:CODEVELOP_TARGET = $targetPeer
$env:CODEVELOP_BASE_URL = $baseUrl
$env:CODEVELOP_MANIFEST = $manifestPath
$env:CELL_ROLE = "codevelop-$Peer"

$prompt = @"
You are peer=$Peer in co-development session $sessionId.
Your default partner is $targetPeer.
Use clauth codevelop tools at $baseUrl to send and receive partner messages.
Honor per-turn role and skill requests when provided.
Reply with evidence, files changed, commits, blockers, and next action.
Manifest: $manifestPath
"@

Write-Host ""
Write-Host "Co-develop $Peer"
Write-Host "  session:  $sessionId"
Write-Host "  partner:  $targetPeer"
Write-Host "  base_url: $baseUrl"
Write-Host "  cwd:      $cwd"
Write-Host "  manifest: $manifestPath"
Write-Host ""

Set-Location -LiteralPath $cwd

if ($PrintOnly) {
  if ($Peer -eq "claude") {
    Write-Host 'command: claude -n "Co Develop Claude" --append-system-prompt <co-develop prompt>'
  } else {
    Write-Host "command: codex -C `"$cwd`" <co-develop prompt>"
  }
  return
}

if ($Peer -eq "claude") {
  & claude -n "Co Develop Claude" --append-system-prompt $prompt
} else {
  & codex --cd $cwd --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust $prompt
}
