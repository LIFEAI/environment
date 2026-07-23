param(
  [ValidateSet('claude','codex','service','unknown')]
  [string]$Engine = 'unknown',
  [string]$DevCenterUrl = 'http://127.0.0.1:3003',
  [string]$Task = '',
  [string[]]$Capabilities = @('tail'),
  [int]$HeartbeatSeconds = 60,
  [switch]$NoHeartbeat,
  [switch]$Stopped,
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

function Read-HookInput {
  try {
    # Only read stdin when it is actually redirected (piped). Some hosts (e.g. certain
    # Codex startup paths) invoke this hook with an inherited console, in which case
    # [Console]::In.ReadToEnd() blocks forever waiting for EOF and hangs session start.
    # Guard on redirection and bound the read so it can never block.
    if (-not [Console]::IsInputRedirected) { return $null }
    $task = [System.Threading.Tasks.Task[string]]::Run([Func[string]] { [Console]::In.ReadToEnd() })
    if (-not $task.Wait(2000)) { return $null }
    $raw = $task.Result
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return $null
  }
}

function Get-Value($Object, [string[]]$Paths) {
  foreach ($path in $Paths) {
    $cursor = $Object
    $ok = $true
    foreach ($part in $path.Split('.')) {
      if ($null -eq $cursor -or -not ($cursor.PSObject.Properties.Name -contains $part)) {
        $ok = $false
        break
      }
      $cursor = $cursor.$part
    }
    if ($ok -and $null -ne $cursor -and "$cursor".Trim().Length -gt 0) { return "$cursor" }
  }
  return ''
}

function Get-GitBranch {
  try {
    $branch = git rev-parse --abbrev-ref HEAD 2>$null
    if ($LASTEXITCODE -eq 0) { return "$branch".Trim() }
  } catch {}
  return ''
}

function Get-GitRoot {
  try {
    $root = git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0) { return "$root".Trim() }
  } catch {}
  return ''
}

function Get-ProcessTable {
  # Build the full PID -> { Name, ParentId } map in ONE WMI query, cached for the
  # life of the process. The old hot path walked the ancestor chain with a per-PID
  # `Get-CimInstance Win32_Process -Filter "ProcessId=$id"` call — up to ~64 WMI
  # round-trips across the two ancestor walks on session start, which blew the 5s
  # SessionStart hook budget. One bulk query + in-memory walk is ~50x faster.
  if ($script:ProcTable) { return $script:ProcTable }
  $table = @{}
  try {
    foreach ($p in Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,Name -ErrorAction Stop) {
      $table[[int]$p.ProcessId] = [pscustomobject]@{
        Name     = $p.Name
        ParentId = [int]$p.ParentProcessId
      }
    }
  } catch {}
  $script:ProcTable = $table
  return $table
}

function Get-RuntimeProcess {
  # Walk ancestors until we find the real engine (claude.exe/codex.exe). The hook
  # pwsh is not a direct child of the engine — intermediate shells/hosts sit
  # between — so checking only the immediate parent fell through to the transient
  # pwsh PID, leaving registry entries that never matched a live engine.
  try {
    $table = Get-ProcessTable
    $cursor = [int]$PID
    $guard = 0
    while ($cursor -gt 0 -and $guard -lt 64 -and $table.ContainsKey($cursor)) {
      $entry = $table[$cursor]
      if ($entry.Name -match '^(claude|codex)(\.exe)?$') {
        return [pscustomobject]@{
          Id   = $cursor
          Name = [System.IO.Path]::GetFileNameWithoutExtension($entry.Name)
        }
      }
      if ($entry.ParentId -le 0) { break }
      $cursor = $entry.ParentId
      $guard++
    }
  } catch {}
  try {
    $self = Get-Process -Id $PID -ErrorAction Stop
    return [pscustomobject]@{ Id = $PID; Name = $self.ProcessName }
  } catch {
    return [pscustomobject]@{ Id = $PID; Name = 'unknown' }
  }
}

function Get-WezTermContext {
  $socket = "$env:WEZTERM_UNIX_SOCKET"
  $paneId = "$env:WEZTERM_PANE"
  $guiPid = 0
  $startedAt = ''

  if ($socket -match 'gui-sock-(\d+)') {
    $guiPid = [int]$Matches[1]
  }

  if ($guiPid -le 0) {
    try {
      $table = Get-ProcessTable
      $cursor = [int]$PID
      $guard = 0
      while ($cursor -gt 0 -and $guard -lt 64 -and $table.ContainsKey($cursor)) {
        $entry = $table[$cursor]
        if ($entry.Name -match '^wezterm-gui(\.exe)?$') {
          $guiPid = $cursor
          break
        }
        if ($entry.ParentId -le 0) { break }
        $cursor = $entry.ParentId
        $guard++
      }
    } catch {}
  }

  if ($guiPid -gt 0) {
    try {
      $proc = Get-Process -Id $guiPid -ErrorAction Stop
      $startedAt = $proc.StartTime.ToUniversalTime().ToString('o')
    } catch {}
  }

  $startKey = if ($startedAt) {
    try { ([datetimeoffset]::Parse($startedAt)).UtcDateTime.ToString('yyyyMMddTHHmmssZ') } catch { '' }
  } else { '' }

  $sessionId = "$env:REGEN_WEZTERM_SESSION_ID"
  if (-not $sessionId -and $guiPid -gt 0) {
    $sessionId = "wezterm:$guiPid"
    if ($startKey) { $sessionId = "$sessionId`:$startKey" }
  }
  if (-not $sessionId -and $paneId) {
    $sessionId = "wezterm-pane:$paneId"
  }

  return [pscustomobject]@{
    SessionId = $sessionId
    GuiPid = $guiPid
    PaneId = $paneId
    Socket = $socket
    StartedAt = $startedAt
  }
}

function Get-StateDir {
  $base = $env:LOCALAPPDATA
  if (-not $base) { $base = [System.IO.Path]::GetTempPath() }
  $path = Join-Path $base 'DevCenter\runtime-heartbeats'
  New-Item -ItemType Directory -Force -Path $path | Out-Null
  return $path
}

function Get-SafeId([string]$Value) {
  return ($Value -replace '[^a-zA-Z0-9_.-]', '_')
}

function Test-ProcessAlive([int]$ProcessId) {
  try {
    Get-Process -Id $ProcessId -ErrorAction Stop | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Stop-HeartbeatWorker([string]$RuntimeId) {
  $statePath = Join-Path (Get-StateDir) "$(Get-SafeId $RuntimeId).json"
  if (-not (Test-Path -LiteralPath $statePath)) { return }
  try {
    $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    $workerPid = [int]$state.workerPid
    if ($workerPid -gt 0 -and (Test-ProcessAlive $workerPid)) {
      Stop-Process -Id $workerPid -Force -ErrorAction SilentlyContinue
    }
  } catch {}
  try { [System.IO.File]::Delete($statePath) } catch {}
}

function Start-HeartbeatWorker([hashtable]$Payload, [string]$RuntimeId, [string]$Endpoint, [int]$IntervalSeconds) {
  if ($IntervalSeconds -lt 10) { return }
  $statePath = Join-Path (Get-StateDir) "$(Get-SafeId $RuntimeId).json"
  if (Test-Path -LiteralPath $statePath) {
    try {
      $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
      if (([int]$state.runtimePid -eq [int]$Payload.pid) -and (Test-ProcessAlive ([int]$state.workerPid))) { return }
    } catch {}
  }

  $payloadJson = $Payload | ConvertTo-Json -Depth 8 -Compress
  $workerScript = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$payload = @'
$payloadJson
'@ | ConvertFrom-Json
`$endpoint = '$Endpoint'
`$runtimePid = [int]`$payload.pid
`$interval = $IntervalSeconds
while (`$true) {
  try { Get-Process -Id `$runtimePid -ErrorAction Stop | Out-Null } catch { break }
  `$payload.heartbeatAt = (Get-Date).ToString('o')
  `$payload.lastSeenAt = (Get-Date).ToString('o')
  try {
    Invoke-RestMethod -Method Post -Uri `$endpoint -Body (`$payload | ConvertTo-Json -Depth 8) -ContentType 'application/json' -TimeoutSec 3 | Out-Null
  } catch {}
  Start-Sleep -Seconds `$interval
}
"@
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($workerScript))
  $worker = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -WindowStyle Hidden -PassThru
  [pscustomobject]@{
    runtimeId = $RuntimeId
    runtimePid = [int]$Payload.pid
    workerPid = $worker.Id
    startedAt = (Get-Date).ToString('o')
    intervalSeconds = $IntervalSeconds
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding UTF8
}

$hook = Read-HookInput
$runtimeProcess = Get-RuntimeProcess
$weztermContext = Get-WezTermContext
$sessionId = Get-Value $hook @('session_id', 'sessionId')
if (-not $sessionId) { $sessionId = $env:CODEX_THREAD_ID }
if (-not $sessionId) { $sessionId = $env:CLAUDE_SESSION_ID }
if (-not $sessionId) { $sessionId = "$Engine-$($runtimeProcess.Id)" }

$cwd = Get-Value $hook @('cwd', 'workspace.current_dir')
if (-not $cwd) { $cwd = (Get-Location).Path }

$transcriptPath = Get-Value $hook @('transcript_path', 'transcriptPath')
$taskName = Get-Value $hook @('task.name', 'tasks.0.name')
if (-not $Task -and $taskName) { $Task = $taskName }

$logPaths = @()
if ($transcriptPath) { $logPaths += $transcriptPath }

$now = Get-Date
$nowUtc = $now.ToUniversalTime().ToString('o')
$metadata = @{
  hook_event_name = (Get-Value $hook @('hook_event_name', 'hookEventName'))
  source = 'dev-center-runtime-checkin.ps1'
  checked_in_local = $now.ToString('o')
  checked_in_utc = $nowUtc
  timezone = [System.TimeZoneInfo]::Local.Id
}

if ($weztermContext.SessionId) {
  $metadata.terminal_kind = 'wezterm'
  $metadata.terminal_session_id = $weztermContext.SessionId
  $metadata.wezterm_session_id = $weztermContext.SessionId
}
if ($weztermContext.GuiPid -gt 0) {
  $metadata.terminal_pid = "$($weztermContext.GuiPid)"
  $metadata.wezterm_gui_pid = "$($weztermContext.GuiPid)"
}
if ($weztermContext.PaneId) {
  $metadata.terminal_pane_id = "$($weztermContext.PaneId)"
  $metadata.wezterm_pane_id = "$($weztermContext.PaneId)"
}
if ($weztermContext.Socket) { $metadata.wezterm_socket = $weztermContext.Socket }
if ($weztermContext.StartedAt) { $metadata.terminal_started_at = $weztermContext.StartedAt }

$payload = [ordered]@{
  engine = $Engine
  sessionId = $sessionId
  pid = $runtimeProcess.Id
  processName = $runtimeProcess.Name
  repo = Get-GitRoot
  cwd = $cwd
  branch = Get-GitBranch
  task = $Task
  status = $(if ($Stopped) { 'stopped' } else { 'running' })
  capabilities = $Capabilities
  startedAt = $now.ToString('o')
  heartbeatAt = $now.ToString('o')
  transcriptPath = $transcriptPath
  logPaths = $logPaths
  metadata = $metadata
}

$runtimeId = "$Engine`:$sessionId`:$($runtimeProcess.Id)" -replace '[^a-zA-Z0-9_.:-]', '_'
$payload.id = $runtimeId

if ($Engine -eq 'claude' -and -not $Stopped) {
  $payload.capabilities = @($Capabilities + @('resume') | Select-Object -Unique)
  $payload.resumeCommand = @{
    cmd = 'claude'
    args = @('--resume', $sessionId)
    cwd = $cwd
  }
}

if ($Engine -eq 'codex' -and -not $Stopped) {
  $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
  if ($codexCommand) {
    $payload.capabilities = @($Capabilities + @('resume') | Select-Object -Unique)
    $payload.resumeCommand = @{
      cmd = 'codex'
      args = @('resume', $sessionId)
      cwd = $cwd
    }
  }
}

if ($SelfTest) {
  $json = $payload | ConvertTo-Json -Depth 8 -Compress
  $self = $json | ConvertFrom-Json
  if (-not $self.sessionId) { throw 'self-test payload missing sessionId' }
  if (-not $Stopped -and $Engine -in @('claude','codex') -and -not $self.resumeCommand.cmd) {
    throw 'self-test payload missing resumeCommand'
  }
  if ($env:WEZTERM_PANE -and -not $self.metadata.wezterm_pane_id) {
    throw 'self-test payload missing wezterm_pane_id'
  }
  Write-Host 'dev-center-runtime-checkin: self-test ok'
  exit 0
}

try {
  $body = $payload | ConvertTo-Json -Depth 8
  $endpoint = "$($DevCenterUrl.TrimEnd('/'))/api/agent-manager/runtime/checkin"
  Invoke-RestMethod -Method Post -Uri $endpoint -Body $body -ContentType 'application/json' -TimeoutSec 3 | Out-Null
  if ($Stopped) {
    Stop-HeartbeatWorker $runtimeId
  } elseif (-not $NoHeartbeat) {
    Start-HeartbeatWorker ([hashtable]$payload) $runtimeId $endpoint $HeartbeatSeconds
  }
} catch {
  # Runtime check-in must never block agent startup.
}
