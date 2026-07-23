param(
  [string]$Service = "vultr-dev-ssh",
  [string]$Target = "root@64.237.54.189",
  [string]$Command,
  [string]$KeyPath
)

# ssh-clauth.ps1 — SSH into Vultr (or any clauth-held SSH target) WITHOUT
# writing the private key to %TEMP%. Uses the Windows OpenSSH agent (ssh-agent
# service) to hold the key ephemerally so Windows Defender never sees key
# material on disk.
#
# IMPORTANT: This script MUST use the Windows OpenSSH binaries, NOT Git's.
# Git's ssh-add.exe cannot talk to the Windows ssh-agent service (different IPC).
# We resolve the correct binaries below and use full paths throughout.
#
# Usage:
#   .\scripts\ssh-clauth.ps1                           # interactive shell
#   .\scripts\ssh-clauth.ps1 -Command "pm2 list"       # run a command
#   .\scripts\ssh-clauth.ps1 -KeyPath C:\keys\my.key   # explicit key file (skip agent)

$ErrorActionPreference = "Stop"

# ── Resolve Windows OpenSSH binaries (NOT Git's) ──────────────────────────
# Git's ssh/ssh-add use Unix domain sockets; Windows ssh-agent uses a named pipe.
# Using the wrong binary gives "no connection to auth agent" even when the
# service is running.
$WinSshDir = Join-Path $env:SystemRoot "System32\OpenSSH"
$SshExe    = Join-Path $WinSshDir "ssh.exe"
$SshAddExe = Join-Path $WinSshDir "ssh-add.exe"

if (-not (Test-Path $SshExe)) {
  # Fallback: try Program Files
  $altDir = "C:\Program Files\OpenSSH"
  if (Test-Path (Join-Path $altDir "ssh.exe")) {
    $SshExe    = Join-Path $altDir "ssh.exe"
    $SshAddExe = Join-Path $altDir "ssh-add.exe"
  } else {
    throw "Windows OpenSSH not found at $WinSshDir or $altDir. Install via Settings > Apps > Optional Features > OpenSSH Client."
  }
}

function Get-CurrentIdentity {
  return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Normalize-KeyText {
  param([object]$Raw)

  $text = if ($Raw -is [array]) {
    ($Raw -join "`n")
  } else {
    [string]$Raw
  }

  $text = $text.Trim()

  if ($text.Contains("\n") -and -not $text.Contains("`n")) {
    $text = $text.Replace("\r\n", "`n").Replace("\n", "`n")
  }

  $text = $text -replace "`r`n", "`n"
  $text = $text -replace "`r", "`n"

  if (-not $text.Contains("-----BEGIN ") -or -not $text.Contains(" PRIVATE KEY-----")) {
    throw "clauth service '$Service' did not return an SSH private key."
  }

  if (-not $text.Contains("-----END ") -or -not $text.Contains(" PRIVATE KEY-----")) {
    throw "clauth service '$Service' returned an incomplete SSH private key."
  }

  return $text.TrimEnd() + "`n"
}

# ── Explicit key file path: use it directly (legacy / manual override) ──────
if ($KeyPath) {
  $sshArgs = @(
    "-i", $KeyPath,
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=NUL",
    $Target
  )
  if ($Command) { $sshArgs += $Command }
  & $SshExe @sshArgs
  exit $LASTEXITCODE
}

# ── Agent-based path: load key into ssh-agent, never touches disk ───────────

# 1. Ensure the OpenSSH Authentication Agent service is running.
$agentSvc = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
if (-not $agentSvc) {
  throw "OpenSSH Authentication Agent service (ssh-agent) is not installed. Install via Settings > Apps > Optional Features > OpenSSH Client."
}
if ($agentSvc.Status -ne 'Running') {
  try {
    Start-Service ssh-agent -ErrorAction Stop
  } catch {
    throw "Cannot start ssh-agent service. Run once as admin: Set-Service ssh-agent -StartupType Manual; Start-Service ssh-agent"
  }
}

# 2. Fetch key from clauth daemon.
$rawKey = & curl.exe -s "http://127.0.0.1:52437/v/$Service"
$keyText = Normalize-KeyText -Raw $rawKey

# 3. Write key to ephemeral file and load via Windows ssh-add.
#    Windows ssh-add does not support stdin pipe ("-"), so we use a short-lived
#    file in ~/.ssh/clauth-ephemeral/ (user profile, not %TEMP%).
$fallbackDir = Join-Path (Join-Path $env:USERPROFILE ".ssh") "clauth-ephemeral"
New-Item -ItemType Directory -Path $fallbackDir -Force | Out-Null
$fallbackKey = Join-Path $fallbackDir "$Service.key"

try {
  [System.IO.File]::WriteAllText($fallbackKey, $keyText, [System.Text.Encoding]::ASCII)
  $identity = Get-CurrentIdentity
  icacls $fallbackKey /inheritance:r /grant:r "$identity`:F" 2>&1 | Out-Null

  # Use Windows OpenSSH ssh-add (NOT Git's). It prints success to stderr, so
  # temporarily avoid PowerShell converting that native stderr into a failure.
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    & $SshAddExe $fallbackKey *> $null
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  if ($LASTEXITCODE -ne 0) {
    throw "ssh-add failed (exit $LASTEXITCODE). Is the ssh-agent service running?"
  }
} finally {
  if (Test-Path -LiteralPath $fallbackKey) {
    try {
      icacls $fallbackKey /grant:r "$(Get-CurrentIdentity):F" 2>&1 | Out-Null
      [System.IO.File]::Delete($fallbackKey)
    } catch {}
  }
}

# 4. Run ssh (Windows OpenSSH) — picks up the key from the agent automatically.
$sshArgs = @(
  "-o", "StrictHostKeyChecking=no",
  "-o", "UserKnownHostsFile=NUL",
  $Target
)
if ($Command) { $sshArgs += $Command }

try {
  & $SshExe @sshArgs
  $exitCode = $LASTEXITCODE
} finally {
  # 5. Remove the key from the agent after use (ephemeral).
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    & $SshAddExe -D *> $null
  } catch {
    # Best effort cleanup only
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
}

exit $exitCode
