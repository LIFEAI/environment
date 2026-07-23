param(
  [string]$Name,
  [string]$SessionId,
  [switch]$Resume,
  [switch]$DryRun,
  [switch]$StartIsolatedClauth,
  [int]$Port,
  [string]$BaseUrl = "http://127.0.0.1:52437",
  [string]$Repo = "C:\Dev\regen-root",
  [string]$ClauthCli = "C:\Dev\clauth\cli\index.js"
)

$ErrorActionPreference = "Stop"

if ($Port) {
  $BaseUrl = "http://127.0.0.1:$Port"
}

function Test-CodevelopPing {
  param([string]$Url)
  try {
    $result = Invoke-RestMethod -Method "GET" -Uri "$Url/ping" -TimeoutSec 2
    return ($result.status -eq "ok")
  } catch {
    return $false
  }
}

function Invoke-CodevelopJson {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Uri,
    [object]$Body
  )

  $params = @{
    Method = $Method
    Uri = $Uri
    TimeoutSec = 5
  }
  if ($null -ne $Body) {
    $params.ContentType = "application/json"
    $params.Body = ($Body | ConvertTo-Json -Depth 20)
  }
  Invoke-RestMethod @params
}

$startedClauth = $null
if ($StartIsolatedClauth -and -not (Test-CodevelopPing -Url $BaseUrl)) {
  if (-not $Port) {
    throw "-StartIsolatedClauth requires -Port so live clauth is not affected"
  }
  if ($Port -eq 52437 -or $Port -eq 52438) {
    throw "Refusing to start isolated clauth on reserved port $Port"
  }
  $logDir = Join-Path $Repo ".rdc\co-develop\logs"
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
  $stdout = Join-Path $logDir "clauth-$Port.out.log"
  $stderr = Join-Path $logDir "clauth-$Port.err.log"
  $startedClauth = Start-Process -FilePath node `
    -ArgumentList @($ClauthCli, "serve", "foreground", "--port", "$Port", "--isolated") `
    -WindowStyle Hidden `
    -PassThru `
    -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 250
    if (Test-CodevelopPing -Url $BaseUrl) { break }
  }
}

$ping = Invoke-CodevelopJson -Method "GET" -Uri "$BaseUrl/ping"
if ($ping.status -ne "ok") {
  throw "clauth ping failed at $BaseUrl/ping"
}

if (-not $Name) {
  $Name = "codev-regen-root-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}

if ($Resume) {
  if (-not $SessionId) {
    throw "-Resume requires -SessionId"
  }
  $status = Invoke-CodevelopJson -Method "GET" -Uri "$BaseUrl/codevelop/$SessionId/status"
} else {
  $started = Invoke-CodevelopJson -Method "POST" -Uri "$BaseUrl/codevelop/start" -Body @{
    name = $Name
    repo = $Repo
  }
  $SessionId = $started.session_id
  $null = Invoke-CodevelopJson -Method "POST" -Uri "$BaseUrl/codevelop/join" -Body @{
    session_id = $SessionId
    peer_id = "claude"
    role = "supervisor"
    target_peer = "codex"
  }
  $null = Invoke-CodevelopJson -Method "POST" -Uri "$BaseUrl/codevelop/join" -Body @{
    session_id = $SessionId
    peer_id = "codex"
    role = "implementation_partner"
    target_peer = "claude"
  }
  $status = Invoke-CodevelopJson -Method "GET" -Uri "$BaseUrl/codevelop/$SessionId/status"
}

$wtEnterScript = Join-Path $Repo "scripts\wt-enter.ps1"
if (-not (Test-Path -LiteralPath $wtEnterScript)) {
  throw "wt-enter helper not found at $wtEnterScript"
}
$wtEnterArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $wtEnterScript, "x-codex", "-Repo", $Repo)
if ($DryRun) {
  $wtEnterArgs += "-PrintOnly"
} else {
  $wtEnterArgs += @("-NoInstall", "-Quiet")
}
$codexResult = @(& pwsh @wtEnterArgs)
if ($LASTEXITCODE -ne 0 -or $codexResult.Count -eq 0) {
  throw "Failed to resolve x-codex worktree"
}
$codexRepo = $codexResult[$codexResult.Count - 1]
$codexBranch = "wt/x-codex"
$manifestDir = Join-Path $Repo ".rdc\co-develop"
New-Item -ItemType Directory -Force -Path $manifestDir | Out-Null
$manifestPath = Join-Path $manifestDir "$SessionId.json"

$wtArgs = @(
  "-w", "new",
  "new-tab", "--profile", "Co Develop Claude", "--title", "Co Develop Claude",
  ";",
  "split-pane", "-V", "--size", "0.50", "--profile", "Co Develop Codex", "--title", "Co Develop Codex"
)

$manifest = [ordered]@{
  session_id = $SessionId
  name = $Name
  repo = $Repo
  transport = [ordered]@{
    type = "clauth-codevelop"
    base_url = $BaseUrl
  }
  peers = [ordered]@{
    claude = [ordered]@{
      role = "supervisor"
      cwd = $Repo
      branch = "develop"
      target_peer = "codex"
      stream_url = "$BaseUrl/codevelop/$SessionId/claude/stream"
    }
    codex = [ordered]@{
      role = "implementation_partner"
      cwd = $codexRepo
      branch = $codexBranch
      target_peer = "claude"
      stream_url = "$BaseUrl/codevelop/$SessionId/codex/stream"
    }
  }
  clauth_status = $status
  clauth_process = if ($startedClauth) {
    [ordered]@{
      pid = $startedClauth.Id
      started_by_launcher = $true
      isolated = $true
    }
  } else {
    [ordered]@{
      started_by_launcher = $false
      isolated = ($Port -and $Port -ne 52437 -and $Port -ne 52438)
    }
  }
  commands = [ordered]@{
    claude = "Windows Terminal profile: Co Develop Claude"
    codex = "Windows Terminal profile: Co Develop Codex"
    wt = "wt.exe " + ($wtArgs -join " ")
  }
  manual_prompt_required = $false
  created_at = (Get-Date).ToString("o")
}

$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

if (-not $DryRun) {
  $activePath = Join-Path $manifestDir "active.json"
  [ordered]@{
    session_id = $SessionId
    manifest = $manifestPath
    updated_at = (Get-Date).ToString("o")
  } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $activePath -Encoding UTF8
} else {
  $activePath = Join-Path $manifestDir "active.json"
}

Write-Host "CODEVELOP_SESSION=$SessionId"
Write-Host "MANIFEST=$manifestPath"
if (-not $DryRun) {
  Write-Host "ACTIVE=$activePath"
}
Write-Host "CLAUDE_STREAM=$BaseUrl/codevelop/$SessionId/claude/stream"
Write-Host "CODEX_STREAM=$BaseUrl/codevelop/$SessionId/codex/stream"
if ($startedClauth) {
  Write-Host "CLAUTH_PID=$($startedClauth.Id)"
}
Write-Host ""
Write-Host "Windows Terminal command:"
Write-Host ($manifest.commands.wt)

if (-not $DryRun) {
  & wt.exe @wtArgs
}
