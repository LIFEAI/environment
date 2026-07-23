# Pin Windows 11 voice-typing processes in memory.
# Sets a hard minimum working set so Windows won't trim them under pressure.
# Runs as a logon scheduled task; loops to catch SpeechRuntime.exe when it spawns on demand.

$ErrorActionPreference = 'Continue'
$LogPath = "$env:LOCALAPPDATA\pin-dictation.log"

function Log($msg) {
    "$([DateTime]::Now.ToString('s')) $msg" | Out-File -FilePath $LogPath -Append -Encoding utf8
}

# P/Invoke SetProcessWorkingSetSizeEx — hard min, soft max.
$signature = @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetProcessWorkingSetSizeEx(
    IntPtr hProcess, IntPtr dwMin, IntPtr dwMax, uint Flags);
'@
if (-not ('Win32.Mem' -as [type])) {
    Add-Type -MemberDefinition $signature -Name Mem -Namespace Win32 | Out-Null
}

# 0x1 = QUOTA_LIMITS_HARDWS_MIN_ENABLE  (hard floor — won't be trimmed below this)
# 0x8 = QUOTA_LIMITS_HARDWS_MAX_DISABLE (soft ceiling — can grow if needed)
$FLAGS = [uint32]0x9
$MinMB = 256
$MaxMB = 1536

# Targets: voice-typing UI host, on-demand recognizer, and Voice Access (always-on path).
$Targets = @('TextInputHost', 'SpeechRuntime', 'VoiceAccess')
$Tuned = @{}

Log "pin-dictation started (PID $PID)"

while ($true) {
    foreach ($name in $Targets) {
        foreach ($p in Get-Process -Name $name -ErrorAction SilentlyContinue) {
            $key = "$($p.Id)-$name"
            if ($Tuned.ContainsKey($key)) { continue }

            try {
                $p.PriorityClass = 'High'
                $ok = [Win32.Mem]::SetProcessWorkingSetSizeEx(
                    $p.Handle,
                    [IntPtr]($MinMB * 1MB),
                    [IntPtr]($MaxMB * 1MB),
                    $FLAGS)
                if ($ok) {
                    $Tuned[$key] = $true
                    Log "tuned $name PID=$($p.Id) min=${MinMB}MB max=${MaxMB}MB priority=High"
                } else {
                    $Tuned[$key] = $true  # mark so we don't retry every 10s
                    Log "WSS failed for $name PID=$($p.Id) err=$([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())"
                }
            } catch {
                # Higher-IL processes (e.g. Voice Access) deny user-mode tuning. Mark once and move on.
                $Tuned[$key] = $true
                if ($_.Exception.Message -notmatch 'Access is denied') {
                    Log "exception tuning $name PID=$($p.Id): $_"
                }
            }
        }
    }

    # GC stale PIDs so a respawned process gets re-tuned.
    $alive = @{}
    foreach ($name in $Targets) {
        foreach ($p in Get-Process -Name $name -ErrorAction SilentlyContinue) {
            $alive["$($p.Id)-$name"] = $true
        }
    }
    foreach ($k in @($Tuned.Keys)) {
        if (-not $alive.ContainsKey($k)) { $Tuned.Remove($k) | Out-Null }
    }

    Start-Sleep -Seconds 10
}
