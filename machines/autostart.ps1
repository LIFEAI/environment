# autostart.ps1 - clauth daemon watchdog
# Polls /ping every 30s. Recovers TWO failure modes:
#   1. Daemon DOWN   -> restart it (sealed via DPAPI boot.key when present).
#   2. Daemon LOCKED -> re-unlock IN PLACE via POST /auth with the sealed password
#      (a locked daemon still answers /ping, so the old "ping-only" watchdog never
#      noticed locked:true and every /v/<service> returned the string "locked",
#      breaking all credential fetches until a manual restart).
# Single-instance: exits if another autostart.ps1 is already running.
# ASCII-only on purpose (powershell.exe 5.1 mis-parses non-ASCII without a BOM).
#
# Source of truth: C:\Dev\regen-root\scripts\autostart.ps1
# Startup shortcut: %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\clauth-autostart.lnk
# To reinstall shortcut: run scripts\register-autostart.ps1

$base     = 'http://127.0.0.1:52437'
$bootKey  = "$env:APPDATA\clauth\boot.key"
$logFile  = "$env:TEMP\clauth-watchdog.log"
$nodeExe  = 'C:\Program Files\nodejs\node.exe'
$cliIndex = "$env:APPDATA\npm\node_modules\@lifeaitools\clauth\cli\index.js"

# REQUIRED: [Security.Cryptography.ProtectedData] (DPAPI) does NOT exist in
# powershell.exe 5.1 until System.Security is loaded. Without this the boot.key
# decrypt throws "Unable to find type" and every sealed unlock silently fails -
# the latent bug that made the watchdog never able to auto-unlock.
Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue

function Write-Log($msg) {
  $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  Add-Content -Path $logFile -Value "[$ts] $msg" -ErrorAction SilentlyContinue
}

# --- Single-instance guard: a named mutex (no command-line false positives) ---
# Held for the process lifetime. $wdMutex must stay referenced so it is not GC'd.
$wdMutex = New-Object System.Threading.Mutex($false, 'Global\clauth-watchdog-singleton')
$gotMutex = $false
try { $gotMutex = $wdMutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $gotMutex = $true }  # prior watchdog died holding it
catch { $gotMutex = $true }
if (-not $gotMutex) {
  Write-Log "Another watchdog holds the singleton mutex; exiting PID $PID"
  return
}

# DPAPI-decrypt the sealed vault password from boot.key. Returns $null on any failure.
# The password is NEVER logged or printed.
function Get-SealedPassword {
  if (-not (Test-Path $bootKey)) { return $null }
  try {
    $enc = (Get-Content $bootKey -Raw).Trim()
    return [Text.Encoding]::UTF8.GetString(
      [Security.Cryptography.ProtectedData]::Unprotect(
        [Convert]::FromBase64String($enc), $null, 'CurrentUser'))
  } catch { return $null }
}

Write-Log "Watchdog started (PID $PID)"

# Recovery state. $authRejects counts only CONFIRMED auth rejections -- the daemon
# received the /auth POST and refused it (HTTP 4xx), or it is hard-locked, or there is
# no usable boot.key. We stop after a small cap so we never approach clauth's lockout
# threshold. TRANSIENT failures (network blip, 5xx, daemon mid-restart, timeout) are
# NOT counted and are retried on the next cycle, so a momentary glitch can never
# permanently wedge recovery. Reset to 0 on a successful unlock and on a daemon restart.
$authRejects = 0
$AUTH_REJECT_CAP = 2

while ($true) {
  $ping = $null
  try {
    $ping = Invoke-RestMethod -Uri "$base/ping" -TimeoutSec 3 -ErrorAction Stop
  } catch {
    $ping = $null
  }

  if ($null -eq $ping) {
    # --- Mode 1: daemon DOWN -> restart (sealed if possible) ---
    Write-Log "Daemon not responding - restarting..."
    $pw = Get-SealedPassword
    if ($pw) {
      Start-Process $nodeExe -ArgumentList "`"$cliIndex`" serve start -p $pw" -WindowStyle Hidden
      Write-Log "Restarted (sealed/DPAPI)"
    } else {
      Start-Process $nodeExe -ArgumentList "`"$cliIndex`" serve start" -WindowStyle Hidden
      Write-Log "Restarted (locked - no usable boot.key)"
    }
    $pw = $null
    $authRejects = 0   # fresh daemon: allow unlock attempts again
    Start-Sleep -Seconds 5
  }
  elseif ($ping.locked -eq $true) {
    # --- Mode 2: daemon UP but LOCKED -> re-unlock in place via POST /auth ---
    if ($ping.hard_locked -eq $true) {
      if ($authRejects -lt $AUTH_REJECT_CAP) { Write-Log "Vault HARD-locked - manual unlock required (dashboard)" }
      $authRejects = $AUTH_REJECT_CAP   # retrying cannot help; wait for a restart to reset
    }
    elseif ($authRejects -ge $AUTH_REJECT_CAP) {
      # Confirmed-rejection cap reached (wrong/stale password). Stop hammering /auth to
      # stay under the lockout threshold; manual unlock or a restart is required.
    }
    else {
      $pw = Get-SealedPassword
      if (-not $pw) {
        Write-Log "Vault locked but no usable boot.key - manual unlock required"
        $authRejects = $AUTH_REJECT_CAP   # cannot unlock without the key; stop retrying
      } else {
        $rejected = $false
        try {
          $body = @{ password = $pw } | ConvertTo-Json -Compress
          Invoke-RestMethod -Uri "$base/auth" -Method POST -Body $body -ContentType 'application/json' -TimeoutSec 5 -ErrorAction Stop | Out-Null
        } catch {
          # 4xx = daemon received and refused (count toward cap). 5xx / network / timeout
          # = transient; do NOT count, retry next cycle.
          $code = $null
          try { $code = [int]$_.Exception.Response.StatusCode } catch {}
          if ($code -ge 400 -and $code -lt 500) {
            $rejected = $true
            $authRejects++
            Write-Log "In-place unlock REJECTED by /auth (attempt $authRejects/$AUTH_REJECT_CAP)"
          } else {
            Write-Log "In-place unlock transient error ($($_.Exception.Message)) - will retry"
          }
        }
        $pw = $null
        if (-not $rejected) {
          # Confirm success POSITIVELY via /ping (never infer from response shape).
          Start-Sleep -Milliseconds 400
          $chk = $null
          try { $chk = Invoke-RestMethod -Uri "$base/ping" -TimeoutSec 3 -ErrorAction Stop } catch {}
          if ($chk -and $chk.locked -ne $true) {
            Write-Log "Vault was locked - re-unlocked in place via /auth"
            $authRejects = 0
          }
          # else: still locked but no 4xx -> transient; retry next cycle (uncounted).
        }
      }
    }
  }
  else {
    # Healthy and unlocked.
    $authRejects = 0
  }

  Start-Sleep -Seconds 30
}
