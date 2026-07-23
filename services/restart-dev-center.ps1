param(
  [switch]$Open,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$HealthUrl = 'http://127.0.0.1:3003/api/version'
$AppUrl = 'http://127.0.0.1:3003/agent-manager'
$LogDir = Join-Path $RepoRoot '.codex'
$LogFile = Join-Path $LogDir 'dev-center-local.log'
$ErrLogFile = Join-Path $LogDir 'dev-center-local.err.log'
$TraceLogFile = Join-Path $LogDir 'dev-center-restart.trace.log'

if (-not (Test-Path $LogDir)) {
  New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-RestartTrace($Message) {
  Add-Content -Path $TraceLogFile -Value "$((Get-Date).ToString('s')) $Message" -Encoding ASCII
}

function Test-HttpOk($Url, [int]$TimeoutSec = 5) {
  try {
    $output = & curl.exe -fsS --max-time $TimeoutSec $Url 2>$null
    return ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($output))
  } catch {
    return $false
  }
}

function Complete-Success($Message) {
  Write-RestartTrace "success: $Message"
  Write-Host $Message
  exit 0
}

function Stop-DevCenterPortOwner {
  $owners = Get-NetTCPConnection -LocalPort 3003 -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.OwningProcess -gt 0 } |
    Select-Object -ExpandProperty OwningProcess -Unique

  foreach ($owner in $owners) {
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$owner" -ErrorAction SilentlyContinue
    if (-not $proc) { continue }
    $cmd = [string]$proc.CommandLine
    $isDevCenter = $cmd -like '*C:\Dev\regen-root*' -and (
      $cmd -like '*@regen/dev-center*' -or
      $cmd -like '*apps\dev-center*' -or
      $cmd -like '*next*3003*' -or
      $cmd -like '*next\dist\server\lib\start-server.js*'
    )
    if (-not $isDevCenter) {
      throw "Port 3003 is occupied by non-Dev-Center process ${owner}: $cmd"
    }
    Stop-Process -Id $owner -Force -ErrorAction SilentlyContinue
  }
}

function Stop-DevCenterStartProcesses {
  $currentPid = $PID
  $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
      $_.ProcessId -ne $currentPid -and
      $_.CommandLine -and (
        $_.CommandLine -like '*dev-center-local-start.cmd*' -or
        $_.CommandLine -like '*@regen/dev-center start*' -or
        ($_.CommandLine -like '*C:\Dev\regen-root*' -and $_.CommandLine -like '*next*start*--port 3003*')
      )
    }

  foreach ($process in $processes) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
  }
}

function Test-DevCenterListener {
  $owners = Get-NetTCPConnection -LocalPort 3003 -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.OwningProcess -gt 0 } |
    Select-Object -ExpandProperty OwningProcess -Unique

  foreach ($owner in $owners) {
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$owner" -ErrorAction SilentlyContinue
    if (-not $proc) { continue }
    $cmd = [string]$proc.CommandLine
    if ($cmd -like '*C:\Dev\regen-root*' -and $cmd -like '*next*3003*') {
      return $true
    }
  }
  return $false
}

if (-not $Force -and (Test-HttpOk $HealthUrl 5)) {
  if ($Open) { Start-Process $AppUrl | Out-Null }
  Complete-Success 'dev-center: already running'
}

$buildId = Join-Path $RepoRoot 'apps\dev-center\.next\BUILD_ID'
if (-not (Test-Path $buildId)) {
  throw 'Dev Center production build is missing. Run: pnpm --filter @regen/dev-center build'
}

Stop-DevCenterPortOwner
Stop-DevCenterStartProcesses
Start-Sleep -Milliseconds 500

Set-Content -Path $LogFile -Value '' -Encoding ASCII
Set-Content -Path $ErrLogFile -Value '' -Encoding ASCII
Set-Content -Path $TraceLogFile -Value "$((Get-Date).ToString('s')) restart begin force=$Force" -Encoding ASCII

$env:NODE_ENV = 'production'
$env:NEXT_TELEMETRY_DISABLED = '1'
$env:DEV_CENTER_LOCAL_AUTH_BYPASS = '1'

# --- PM2 path: preferred when pm2 is available ---
$pm2Cmd = Get-Command pm2 -ErrorAction SilentlyContinue
$ecosystemConfig = Join-Path $RepoRoot 'apps\dev-center\ecosystem.config.cjs'

if ($pm2Cmd -and (Test-Path $ecosystemConfig)) {
  Write-RestartTrace 'starting via PM2 ecosystem.config.cjs'

  # Stop any existing PM2 dev-center process first
  & $pm2Cmd.Source delete dev-center 2>$null | Out-Null

  & $pm2Cmd.Source start $ecosystemConfig
  if ($LASTEXITCODE -ne 0) {
    Write-RestartTrace 'PM2 start failed, falling back to raw Start-Process'
  } else {
    Write-RestartTrace 'PM2 start issued, waiting for health'
    $deadline = (Get-Date).AddSeconds(120)
    do {
      Start-Sleep -Seconds 2
      $healthy = Test-HttpOk $HealthUrl 5
      Write-RestartTrace "poll healthy=$healthy"
      if ($healthy) {
        if ($Open) { Start-Process $AppUrl | Out-Null }
        Complete-Success 'dev-center: started via PM2 and healthy'
      }
    } while ((Get-Date) -lt $deadline)
    throw 'Dev Center (PM2) did not become healthy within 120 seconds.'
  }
}

# --- Raw Start-Process fallback ---
$node = (Get-Command node.exe -ErrorAction Stop).Source
$nextBin = Join-Path $RepoRoot 'apps\dev-center\node_modules\next\dist\bin\next'
if (-not (Test-Path $nextBin)) {
  throw 'Dev Center Next.js binary is missing. Run: pnpm install'
}

$proc = Start-Process -FilePath $node `
  -ArgumentList $nextBin, 'start', '--port', '3003' `
  -WorkingDirectory (Join-Path $RepoRoot 'apps\dev-center') `
  -RedirectStandardOutput $LogFile `
  -RedirectStandardError $ErrLogFile `
  -WindowStyle Hidden `
  -PassThru
Write-RestartTrace "started pid=$($proc.Id)"

$deadline = (Get-Date).AddSeconds(120)
do {
  Start-Sleep -Seconds 2
  $healthy = Test-HttpOk $HealthUrl 5
  Write-RestartTrace "poll healthy=$healthy procExited=$($proc.HasExited) listener=$(Test-DevCenterListener)"
  if ($healthy) {
    if ($Open) { Start-Process $AppUrl | Out-Null }
    Complete-Success 'dev-center: started and healthy'
  }

  if ($proc.HasExited) {
    if (Test-DevCenterListener) {
      Write-RestartTrace 'launcher exited; listener is still warming up'
      continue
    }
    $outTail = if (Test-Path $LogFile) { (Get-Content -Path $LogFile -Tail 25 -ErrorAction SilentlyContinue) -join "`n" } else { '' }
    $errTail = if (Test-Path $ErrLogFile) { (Get-Content -Path $ErrLogFile -Tail 25 -ErrorAction SilentlyContinue) -join "`n" } else { '' }
    throw "Dev Center exited before becoming healthy.`nSTDOUT:`n$outTail`nSTDERR:`n$errTail"
  }
} while ((Get-Date) -lt $deadline)

$outTail = if (Test-Path $LogFile) { (Get-Content -Path $LogFile -Tail 25 -ErrorAction SilentlyContinue) -join "`n" } else { '' }
$errTail = if (Test-Path $ErrLogFile) { (Get-Content -Path $ErrLogFile -Tail 25 -ErrorAction SilentlyContinue) -join "`n" } else { '' }
throw "Dev Center did not become healthy within 120 seconds.`nSTDOUT:`n$outTail`nSTDERR:`n$errTail"
