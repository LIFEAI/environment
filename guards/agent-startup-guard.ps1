param(
  [int]$MinIntervalSeconds = 1800,
  [switch]$Force,
  [switch]$OpenDashboards,
  # When set, verify clauth health but never trigger restart-clauth.bat. Codex passes this
  # so two engines don't fight over the daemon — Claude + the watchdog own clauth's
  # lifecycle. If clauth is down under this flag, the guard fails loudly instead of
  # restarting it out from under the other engine.
  [switch]$NoClauthRestart,
  # When set (ANY warm pool lane — x-codex-N OR claude-N — auto-detected by
  # session-start.sh from the cwd leaf), the guard additionally PROVES the named repo
  # lane is ready for edits — registered worktree + on wt/<name> + 0/0 vs a
  # freshly-fetched origin/develop + required docs present — and FAILS startup if not.
  # Service health ("clauth/codeflow ready") is necessary but NOT sufficient for repo
  # edits; this closes the gap where the guard reported ready while the active lane was
  # missing/unregistered/stale (the "started working, 15 commits behind" bypass). The
  # proof is engine-agnostic — the -CodexLane name is legacy. Unset (main/SV tree) ->
  # never gates on a lane.
  [string]$CodexLane = ''
)

$ErrorActionPreference = 'Stop'
$RepoRoot = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { Split-Path -Parent $PSScriptRoot }
$LogDir = Join-Path $RepoRoot '.codex'
$LogFile = Join-Path $LogDir 'agent-startup-guard.log'
$StampFile = Join-Path $env:LOCALAPPDATA 'regen-root-agent-startup.ok'
$OpenedStampFile = Join-Path $env:LOCALAPPDATA 'regen-root-agent-startup.opened'
$MutexName = 'Local\regen-root-agent-startup-guard'
# Last-resort literal only. Resolve-CorpusRoots prefers a process env that resolves on
# disk, then looks the ONE system variable up at Machine scope (survives a stale, pre-move
# process env inherited by a restarted session — the 2026-07-20 crash mode). Master
# relocated to C:\rdc-gdrive\global-corpus (2026-07-20).
$DefaultCorpusRoot = 'C:\rdc-gdrive\global-corpus'
$DefaultLocalCorpusRoot = 'C:\Dev\local-corpus'

if (-not (Test-Path $LogDir)) {
  New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-GuardLog($Message) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $Message
  for ($i = 0; $i -lt 5; $i++) {
    try {
      Add-Content -Path $LogFile -Value $line -Encoding ASCII -ErrorAction Stop
      return
    } catch {
      Start-Sleep -Milliseconds (75 * ($i + 1))
    }
  }
}

function Test-HttpOk($Url, [int]$TimeoutSec = 3) {
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec $TimeoutSec
    return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300)
  } catch {
    return $false
  }
}

# Resolve one root against the ONE system variable. Machine-scope is AUTHORITATIVE —
# it is the canonical value set by the operator. Process env may carry a stale pre-move
# path inherited from a parent shell started before the migration. When Machine scope
# is set and resolves on disk, it wins unconditionally. Falls back to process env only
# when Machine scope is unset or unresolvable, then to the literal default.
function Get-ResolvedRoot([string]$EnvValue, [string]$VarName, [string]$Default) {
  $machine = [Environment]::GetEnvironmentVariable($VarName, 'Machine')
  if ($machine) { $machine = $machine.Trim() }
  if ($machine -and (Test-Path -LiteralPath $machine)) { return $machine }
  $proc = if ([string]::IsNullOrWhiteSpace($EnvValue)) { '' } else { $EnvValue.Trim() }
  if ($proc -and (Test-Path -LiteralPath $proc)) { return $proc }
  if ($machine) { return $machine }
  if ($proc) { return $proc }
  return $Default
}

function Resolve-CorpusRoots {
  $corpusRoot = Get-ResolvedRoot $env:CORPUS_ROOT 'CORPUS_ROOT' $DefaultCorpusRoot
  $localCorpusRoot = Get-ResolvedRoot $env:LOCAL_CORPUS_ROOT 'LOCAL_CORPUS_ROOT' $DefaultLocalCorpusRoot

  $env:CORPUS_ROOT = $corpusRoot
  $env:LOCAL_CORPUS_ROOT = $localCorpusRoot

  return [pscustomobject]@{
    CorpusRoot = $corpusRoot
    LocalCorpusRoot = $localCorpusRoot
  }
}

function Get-CorpusFileCount([string]$Path) {
  return (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object).Count
}

function Test-CorpusReady {
  try {
    $roots = Resolve-CorpusRoots
    if (-not (Test-Path -LiteralPath $roots.CorpusRoot)) { return $false }
    return (Get-CorpusFileCount $roots.CorpusRoot) -gt 0
  } catch {
    return $false
  }
}

function Ensure-CorpusRoots {
  $roots = Resolve-CorpusRoots
  $corpusRoot = $roots.CorpusRoot
  $localCorpusRoot = $roots.LocalCorpusRoot

  if (-not (Test-Path -LiteralPath $corpusRoot)) {
    throw "CORPUS ROOT UNRESOLVED: CORPUS_ROOT=$corpusRoot. corpus-relative paths are unsafe until the global-corpus master is mounted."
  }

  $srcCount = Get-CorpusFileCount $corpusRoot
  if ($srcCount -lt 1) {
    throw "CORPUS ROOT UNRESOLVED: CORPUS_ROOT=$corpusRoot exists but contains 0 files. corpus-relative paths are unsafe until global-corpus is hydrated."
  }

  $localExists = Test-Path -LiteralPath $localCorpusRoot
  if ($localExists) {
    Write-GuardLog "corpus: ready root=$corpusRoot files=$srcCount local=$localCorpusRoot local_present=true"
  } else {
    Write-GuardLog "corpus: ready root=$corpusRoot files=$srcCount local=$localCorpusRoot local_present=false (session-start sync will provision)"
  }
}

function Ensure-EnvironmentRepo {
  $lockFile = Join-Path $RepoRoot 'environment.lock.json'
  if (-not (Test-Path -LiteralPath $lockFile)) {
    Write-GuardLog 'environment-repo: no environment.lock.json — skipping env repo check'
    return
  }
  $lock = Get-Content $lockFile -Raw | ConvertFrom-Json
  $envPath = if ($env:LIFEAI_ENV_ROOT) { $env:LIFEAI_ENV_ROOT } else { $lock.environment_repo.default_path }
  if (-not $envPath -or -not (Test-Path -LiteralPath $envPath)) {
    Write-GuardLog "environment-repo: WARN not cloned at $envPath — clone from $($lock.environment_repo.url)"
    return
  }
  $inside = git -C $envPath rev-parse --is-inside-work-tree 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-GuardLog "environment-repo: WARN $envPath exists but is not a git repo"
    return
  }
  try {
    git -C $envPath fetch origin --quiet 2>$null
    $behind = git -C $envPath rev-list HEAD..origin/main --count 2>$null
    if ($behind -and [int]$behind -gt 0) {
      Write-GuardLog "environment-repo: $behind commit(s) behind origin/main at $envPath — run: git -C $envPath pull"
    } else {
      Write-GuardLog "environment-repo: ready path=$envPath"
    }
  } catch {
    Write-GuardLog "environment-repo: ready path=$envPath (fetch skipped: $($_.Exception.Message))"
  }
}

function Get-ClauthPing([int]$TimeoutSec = 3) {
  $url = 'http://127.0.0.1:52437/ping'
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec $TimeoutSec -Headers @{
      'Cache-Control' = 'no-cache'
      'Pragma' = 'no-cache'
    }
    $json = $response.Content | ConvertFrom-Json
    return [pscustomobject]@{
      ok = ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300)
      json = $json
      raw = $response.Content
      error = $null
    }
  } catch {
    return [pscustomobject]@{
      ok = $false
      json = $null
      raw = $null
      error = $_.Exception.Message
    }
  }
}

function Format-ClauthPing($Ping) {
  if (-not $Ping -or -not $Ping.ok -or -not $Ping.json) {
    return "unreachable error=$($Ping.error)"
  }
  $j = $Ping.json
  return "locked=$($j.locked) hard_locked=$($j.hard_locked) failures=$($j.failures) auth_failures=$($j.auth_failures) pid=$($j.pid) version=$($j.app_version)"
}

function Test-ClauthUnlocked {
  $ping = Get-ClauthPing 2
  return ($ping.ok -and $ping.json -and $ping.json.locked -ne $true -and $ping.json.hard_locked -ne $true)
}

function Wait-HttpOk($Url, [int]$Seconds, [int]$TimeoutSec = 3) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-HttpOk $Url $TimeoutSec) { return $true }
    Start-Sleep -Seconds 2
  }
  return $false
}

function Stop-DevCenterPortOwner {
  $owners = Get-NetTCPConnection -LocalPort 3003 -ErrorAction SilentlyContinue |
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
    if ($isDevCenter) {
      Write-GuardLog "dev-center: stopping stale port 3003 owner pid=$owner"
      Stop-Process -Id $owner -Force -ErrorAction SilentlyContinue
    } else {
      throw "Port 3003 is occupied by non-Dev-Center process ${owner}: $cmd"
    }
  }
}

function Assert-Command($Name) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if (-not $cmd) { throw "Required command not found: $Name" }
  return $cmd.Source
}

function Ensure-Clauth {
  $url = 'http://127.0.0.1:52437/ping'
  $ping = Get-ClauthPing 2
  if (-not $ping.ok) {
    if ($NoClauthRestart) {
      throw 'clauth is down and -NoClauthRestart is set. Claude or the watchdog owns clauth lifecycle; start it (Restart clauth on the desktop) before this engine proceeds.'
    }
    $restart = Join-Path $RepoRoot 'scripts\restart-clauth.bat'
    if (-not (Test-Path $restart)) { throw "clauth is down and restart script is missing: $restart" }
    Write-GuardLog 'clauth: starting via restart-clauth.bat'
    Start-Process -FilePath $restart -WindowStyle Hidden -WorkingDirectory $RepoRoot | Out-Null
    if (-not (Wait-HttpOk $url 30 2)) { throw 'clauth did not answer /ping after restart.' }
    $ping = Get-ClauthPing 3
  }

  $status = $ping.json
  Write-GuardLog "clauth: ping $(Format-ClauthPing $ping)"

  # HARD lock: NEVER restart. A fresh `serve start` with a wrong/sealed boot.key burns
  # fail_count toward server-side machine lockout, masking the real cause and making
  # recovery worse (reference_clauth_locked_vault_recovery). Fail loudly -> manual unlock.
  if ($status.hard_locked) {
    throw 'clauth is HARD-locked. Do NOT restart (it worsens lockout). Browser-unlock at http://127.0.0.1:52437, then start a new session.'
  }

  # SOFT lock: recover, don't just refuse. The 30s watchdog (scripts/autostart.ps1) re-unlocks
  # in place via the sealed boot.key — give it a beat to do its job, then fall back to
  # restart-clauth.bat (fresh daemon + unlock page). Claude owns the restart; Codex
  # (-NoClauthRestart) waits for the watchdog only. Only throw if still locked after recovery.
  if ($status.locked) {
    Write-GuardLog 'clauth: locked - waiting for watchdog in-place unlock'
    $deadline = (Get-Date).AddSeconds(35)
    while ((Get-Date) -lt $deadline -and $status.locked -and -not $status.hard_locked) {
      Start-Sleep -Seconds 3
      $ping = Get-ClauthPing 3
      if ($ping.ok -and $ping.json) {
        $status = $ping.json
        Write-GuardLog "clauth: retry ping $(Format-ClauthPing $ping)"
      }
    }
    if ($status.locked -and -not $status.hard_locked -and -not $NoClauthRestart) {
      $restart = Join-Path $RepoRoot 'scripts\restart-clauth.bat'
      if (Test-Path $restart) {
        Write-GuardLog 'clauth: still locked after watchdog window - restarting via restart-clauth.bat'
        Start-Process -FilePath $restart -WindowStyle Hidden -WorkingDirectory $RepoRoot | Out-Null
        if (Wait-HttpOk $url 30 2) {
          $ping = Get-ClauthPing 3
          if ($ping.ok -and $ping.json) {
            $status = $ping.json
            Write-GuardLog "clauth: post-restart ping $(Format-ClauthPing $ping)"
          }
        }
      }
    }

    # Final truth check: do not report a lock from an old object if /ping has recovered.
    for ($i = 0; $i -lt 3 -and ($status.locked -or $status.hard_locked); $i++) {
      Start-Sleep -Milliseconds 500
      $ping = Get-ClauthPing 3
      if ($ping.ok -and $ping.json) {
        $status = $ping.json
        Write-GuardLog "clauth: final ping $(Format-ClauthPing $ping)"
      }
    }
    if ($status.locked -or $status.hard_locked) {
      throw "clauth is still locked after recovery. Fresh /ping says $(Format-ClauthPing $ping). Unlock http://127.0.0.1:52437 before Claude/Codex work can proceed."
    }
    Write-GuardLog 'clauth: recovered from soft lock'
  }
  Write-GuardLog 'clauth: ready'
}

function Ensure-RdcSkills {
  $health = 'http://127.0.0.1:3110/health'
  $needsRepair = $false

  if (-not (Get-Command rdc-skills-install -ErrorAction SilentlyContinue)) {
    Write-GuardLog 'rdc-skills: installer command missing'
    $needsRepair = $true
  }

  try {
    $status = Invoke-RestMethod -Uri $health -TimeoutSec 4
    if ($status.status -ne 'ok' -or [int]$status.skills -lt 20) {
      Write-GuardLog "rdc-skills: MCP unhealthy status=$($status.status) skills=$($status.skills)"
      $needsRepair = $true
    }
  } catch {
    Write-GuardLog "rdc-skills: MCP health failed: $($_.Exception.Message)"
    $needsRepair = $true
  }

  if ($needsRepair) {
    $npm = Assert-Command npm
    Write-GuardLog 'rdc-skills: repairing approved global package and LIFEAI install'
    & $npm install -g '@lifeaitools/rdc-skills@latest' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'rdc-skills global npm install failed.' }

    $installer = Assert-Command rdc-skills-install
    & $installer --profile lifeai --project-root $RepoRoot --write-startup-blocks | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'rdc-skills installer failed.' }
  }

  try {
    $final = Invoke-RestMethod -Uri $health -TimeoutSec 5
    if ($final.status -ne 'ok' -or [int]$final.skills -lt 20) {
      throw "MCP health invalid after repair: status=$($final.status) skills=$($final.skills)"
    }
    Write-GuardLog "rdc-skills: ready version=$($final.version) skills=$($final.skills)"
  } catch {
    throw "rdc-skills MCP is not healthy: $($_.Exception.Message)"
  }
}

function Ensure-PnpmInstall {
  $lockFile = Join-Path $RepoRoot 'pnpm-lock.yaml'
  $stampFile = Join-Path $RepoRoot 'node_modules\.pnpm-install-stamp'
  if (-not (Test-Path $lockFile)) { return }
  $lockMtime = (Get-Item $lockFile).LastWriteTimeUtc
  $needsInstall = $false
  if (-not (Test-Path $stampFile)) {
    $needsInstall = $true
  } else {
    $stampMtime = (Get-Item $stampFile).LastWriteTimeUtc
    if ($lockMtime -gt $stampMtime) { $needsInstall = $true }
  }
  if ($needsInstall) {
    Write-GuardLog 'pnpm-install: lockfile newer than last install — running pnpm install'
    $pnpm = Assert-Command pnpm
    Push-Location $RepoRoot
    try {
      & $pnpm install --frozen-lockfile 2>&1 | Out-Null
      # Stamp the install time so we don't re-run on next session
      [IO.File]::WriteAllText($stampFile, (Get-Date -Format 'o'))
      Write-GuardLog 'pnpm-install: done'
    } catch {
      Write-GuardLog "pnpm-install: WARN failed — $($_.Exception.Message)"
    } finally {
      Pop-Location
    }
  }
}

function Ensure-Docker {
  $docker = Assert-Command docker
  & $docker info *> $null
  if ($LASTEXITCODE -eq 0) {
    Write-GuardLog 'docker: ready'
    return
  }

  $dockerDesktop = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
  if (-not (Test-Path $dockerDesktop)) { throw 'Docker daemon is down and Docker Desktop was not found.' }
  if (-not (Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue)) {
    Write-GuardLog 'docker: launching Docker Desktop'
    Start-Process -FilePath $dockerDesktop -WindowStyle Hidden | Out-Null
  }

  $deadline = (Get-Date).AddSeconds(120)
  while ((Get-Date) -lt $deadline) {
    & $docker info *> $null
    if ($LASTEXITCODE -eq 0) {
      Write-GuardLog 'docker: ready after launch'
      return
    }
    Start-Sleep -Seconds 3
  }
  throw 'Docker daemon did not become ready within 120 seconds.'
}

function Ensure-CodeFlow {
  $health = 'http://127.0.0.1:3109/health'
  # /health timeout is deliberately generous. Since epic 7cde6025 the local 3109
  # gateway routes the active brain to remote PM2 (codeflow-pm2.regendevcorp.com),
  # so /health round-trips the network and legitimately takes ~6s. A tight 3s probe
  # here false-negatives, drops into the destructive PM2-restart branch below, and
  # can never recover (that branch's wait was also 3s). Do NOT tighten below ~12s.
  if (Test-HttpOk $health 15) {
    Write-GuardLog 'codeflow: ready'
    # Gateway is up. Version-aware self-heal for the OTHER two local codeflow
    # processes (rig :3129, explorer :3108): each auto-rebuilds+refreshes only
    # when its served build is stale; a current process is left untouched
    # (uptime preserved). Best-effort — must never fail the gate.
    Ensure-CodeFlowSiblings
    return
  }

  # Gateway is down. Try blue-green recover first (hot-swap capable); if slots
  # don't exist yet (first run / fresh machine), fall back to direct pm2 start.
  Write-GuardLog 'codeflow: gateway down — starting'
  $node = Assert-Command node
  $pm2 = Assert-Command pm2
  $bgScript = Join-Path $RepoRoot 'scripts\codeflow-bluegreen.mjs'
  $blueSlot = 'C:\Dev\codeflow-blue'
  $greenSlot = 'C:\Dev\codeflow-green'
  $slotsExist = (Test-Path $blueSlot) -or (Test-Path $greenSlot)

  if ((Test-Path $bgScript) -and $slotsExist) {
    Write-GuardLog 'codeflow: recovering via blue-green controller'
    & $node $bgScript recover | Out-Null
  } else {
    # Blue-green slots not initialized — direct start as passthrough relay.
    # This is the first-run / post-reboot path before `prepare` has been run.
    Write-GuardLog 'codeflow: no blue-green slots — direct pm2 start (passthrough relay)'
    $dist = Join-Path $RepoRoot 'packages\codeflow\dist\server.js'
    $cf = Join-Path $RepoRoot 'packages\codeflow'
    if (-not (Test-Path $dist)) {
      Write-GuardLog 'codeflow: dist missing — building'
      $pnpm = Assert-Command pnpm
      & $pnpm --filter '@regen/codeflow' esbuild 2>&1 | Out-Null
    }
    & $pm2 start $dist --name codeflow-mcp --cwd $cf --node-args "--import=tsx" --update-env | Out-Null
  }
  # 15s per-probe timeout: remote-brain /health takes ~6s.
  if (-not (Wait-HttpOk $health 45 15)) { throw 'CodeFlow gateway did not answer /health after startup.' }
  $pm2 = Assert-Command pm2
  & $pm2 save | Out-Null
  Write-GuardLog 'codeflow: ready'
  Ensure-CodeFlowSiblings
}

# Version-aware staleness self-heal for the two local codeflow processes that are
# NOT the gateway: the rig (codeflow-test-mcp :3129) and the explorer
# (codeflow-explorer :3108). Extends codeflow-up.mjs's served-vs-built pattern.
# scripts/codeflow-heal.mjs reads each process's LIVE served state, consults the
# pure predicates in scripts/lib/staleness.mjs, and refreshes ONLY when stale — a
# current rig/explorer is never bounced (uptime preserved). Best-effort: this must
# never fail agent startup (the top-level catch turns a throw into exit 1), so it
# is wrapped and only warns on error.
function Ensure-CodeFlowSiblings {
  # BACKGROUND (approved 2026-07-16, Dave): once the active-brain gateway (:3109) is confirmed
  # healthy, the rig (:3129) + explorer (:3108) staleness heal must NOT block startup — checking
  # the two NON-active brains synchronously every session was pure added latency. Fire it
  # DETACHED + windowless so the session comes up immediately; codeflow-heal.mjs self-logs and
  # windowsHides its own children. Engine-agnostic: both Claude and Codex reach this via
  # session-start.sh -> this guard.
  try {
    $node = Assert-Command node
    $heal = Join-Path $RepoRoot 'scripts\codeflow-heal.mjs'
    $hlog = Join-Path $LogDir 'codeflow-heal.out.log'
    Start-Process -FilePath $node -ArgumentList $heal -WindowStyle Hidden `
      -RedirectStandardOutput $hlog -RedirectStandardError "$hlog.err" | Out-Null
    Write-GuardLog 'codeflow-siblings: rig (:3129) + explorer (:3108) heal launched (background, non-blocking)'
  } catch {
    Write-GuardLog "codeflow-siblings: WARN $($_.Exception.Message) - continuing (self-heal is non-blocking)"
  }
}

function Ensure-DevToolsFresh {
  # Approved 2026-07-16 (Dave, AskUserQuestion): "auto-update tools, warn on repo." An offline
  # box (e.g. Carbon) used to drift behind silently — the guard checked LIVENESS, never LATEST.
  # ENGINE-AGNOSTIC: runs for BOTH Claude and Codex because both go through session-start.sh ->
  # this guard. Two-phase + NON-BLOCKING so it does not re-introduce startup latency:
  #   (1) show the PREVIOUS check's drift warnings INSTANTLY from an off-repo LOCALAPPDATA stamp;
  #   (2) relaunch scripts/dev-tools-freshness.mjs DETACHED to git-fetch, auto-update rdc-skills
  #       when behind npm latest, and warn on repo/clauth drift — self-throttled to 4h.
  # No network on the blocking path; the warning the operator sees is the last completed check.
  try {
    $stamp = Join-Path $env:LOCALAPPDATA 'regen-root-dev-tools-freshness.json'
    # Summarize the LAST completed check into ONE 'dev-tools: ready' log line so the
    # startup table renders a dedicated at-a-glance row (like clauth/codeflow/...). The
    # row is always ✅ because the CHECK itself is non-blocking and warn-only — any actual
    # drift is surfaced loudly in the '!! DEV-TOOLS / REPO FRESHNESS' block above the table
    # AND echoed in this row's detail so a glance shows "current" vs "N drift warning(s)".
    $devToolsDetail = 'first freshness check running in background'
    if (Test-Path -LiteralPath $stamp) {
      try {
        $s = Get-Content -LiteralPath $stamp -Raw | ConvertFrom-Json
        $warns = @($s.warnings)
        if ($warns.Count -gt 0) {
          Write-Output ''
          Write-Output '  !! DEV-TOOLS / REPO FRESHNESS:'
          foreach ($w in $warns) { Write-Output "     - $w" }
          Write-Output ''
          $devToolsDetail = "$($warns.Count) drift warning(s) - see freshness block above"
        } else {
          $rs = $s.tools.'rdc-skills'; $cl = $s.tools.'clauth'
          $parts = @()
          if ($rs -and $rs.installed) { $parts += "rdc-skills $($rs.installed)" }
          if ($cl -and $cl.installed) { $parts += "clauth $($cl.installed)" }
          $parts += 'repo current'
          $devToolsDetail = ($parts -join ', ')
        }
      } catch { $devToolsDetail = 'stamp unreadable - re-checking in background' }
    }
    Write-GuardLog "dev-tools: ready ($devToolsDetail)"
    $node = Assert-Command node
    $fresh = Join-Path $RepoRoot 'scripts\dev-tools-freshness.mjs'
    $flog = Join-Path $LogDir 'dev-tools-freshness.out.log'
    Start-Process -FilePath $node -ArgumentList $fresh -WindowStyle Hidden `
      -RedirectStandardOutput $flog -RedirectStandardError "$flog.err" | Out-Null
    Write-GuardLog 'dev-tools-freshness: check launched (background, non-blocking, 4h TTL)'
  } catch {
    Write-GuardLog "dev-tools-freshness: WARN $($_.Exception.Message) - continuing (non-blocking)"
  }
}

function Ensure-DevCenter {
  # Dev Center is a convenience dashboard, NOT a gate on agent startup. It must NEVER
  # throw — a slow/missing dashboard cannot be allowed to fail a Claude/Codex session
  # (the top-level catch turns any throw here into exit 1). Best-effort start, wait at
  # most 30s, then continue regardless. clauth/CodeFlow/rdc-skills are the real gates.
  try {
    $health = 'http://127.0.0.1:3003/api/version'
    if (Test-HttpOk $health 5) {
      Write-GuardLog 'dev-center: ready'
      return
    }

    Stop-DevCenterPortOwner

    $buildId = Join-Path $RepoRoot 'apps\dev-center\.next\BUILD_ID'
    $ecosystemConfig = Join-Path $RepoRoot 'apps\dev-center\ecosystem.config.cjs'
    $pm2Cmd = Get-Command pm2 -ErrorAction SilentlyContinue

    if ((Test-Path $buildId) -and $pm2Cmd -and (Test-Path $ecosystemConfig)) {
      # Path 1: PM2 + production build (preferred)
      Write-GuardLog 'dev-center: starting via PM2 ecosystem.config.cjs'
      & $pm2Cmd.Source delete dev-center 2>$null | Out-Null
      & $pm2Cmd.Source start $ecosystemConfig | Out-Null
    } elseif (Test-Path $buildId) {
      # Path 2: production build, no PM2 — use restart-dev-center.ps1
      $restart = Join-Path $RepoRoot 'scripts\restart-dev-center.ps1'
      if (Test-Path $restart) {
        Write-GuardLog 'dev-center: starting local production service (raw fallback)'
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $restart | Out-Null
      } else {
        Write-GuardLog 'dev-center: WARN restart script missing - skipping (non-blocking)'
      }
    } else {
      # Path 3: no production build - dev mode fallback.
      # IMPORTANT: Get-Command pnpm resolves to pnpm.ps1 (an ExternalScript). Passing that
      # to Start-Process -FilePath ShellExecutes the .ps1, which - with no valid .ps1
      # UserChoice on Win11 - pops the "Select an app to open this .ps1 file" picker and
      # blocks. Launch through cmd.exe instead so it resolves pnpm.cmd via PATHEXT and no
      # .ps1 is ever ShellExecuted.
      Write-GuardLog 'dev-center: no production build; starting in dev mode'
      $null = Assert-Command pnpm
      Push-Location $RepoRoot
      try {
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'pnpm', '--filter', '@regen/dev-center', 'dev' -WindowStyle Hidden -WorkingDirectory $RepoRoot | Out-Null
      } finally {
        Pop-Location
      }
    }

    # Non-blocking: the start above is fire-and-forget. A cold Next dev server won't
    # compile within the budget anyway, so probe briefly (<=10s) and move on - it will
    # finish coming up in the background and be cache-fresh for the next session.
    if (Wait-HttpOk $health 10 3) {
      Write-GuardLog 'dev-center: ready'
    } else {
      Write-GuardLog 'dev-center: starting in background - continuing (dashboard is non-blocking)'
    }
  } catch {
    Write-GuardLog "dev-center: WARN $($_.Exception.Message) - continuing (dashboard is non-blocking)"
  }
}

function Ensure-AgentReadiness {
  $pnpm = Assert-Command pnpm
  Write-GuardLog 'agent-readiness: checking clauth, CodeFlow MCP, and repo hydration'
  # The readiness script runs several checks with tight (~5s) timeouts (codeflow
  # /health, Neo4j connect, spawned MCP smoke). At session start those checks
  # contend with corpus sync, pnpm, Neo4j warmup, and multiple node processes,
  # so a single transient timeout would otherwise fail the whole gate. Retry a
  # few times with a short backoff and only declare failure if every attempt
  # fails — and log the real blockers each time so the cause is never hidden.
  $maxAttempts = 3
  Push-Location $RepoRoot
  try {
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
      $output = & $pnpm --filter '@regen/codeflow' startup:readiness 2>&1
      if ($LASTEXITCODE -eq 0) {
        if ($attempt -gt 1) { Write-GuardLog "agent-readiness: ready (passed on attempt $attempt)" }
        else { Write-GuardLog 'agent-readiness: ready' }
        return
      }

      $freshClauthUnlocked = Test-ClauthUnlocked
      $report = $null
      try {
        $jsonText = ($output -join "`n")
        $start = $jsonText.IndexOf('{')
        if ($start -ge 0) {
          $report = $jsonText.Substring($start) | ConvertFrom-Json
        }
      } catch {}

      $blockers = @()
      if ($report -and $report.blockers) { $blockers = @($report.blockers) }
      $onlyStaleClauthBlocker = $freshClauthUnlocked -and
        $blockers.Count -gt 0 -and
        (@($blockers | Where-Object { [string]$_ -notlike 'clauth*' }).Count -eq 0)

      if ($onlyStaleClauthBlocker) {
        Write-GuardLog 'agent-readiness: ignored stale clauth locked blocker because fresh /ping is unlocked'
        return
      }

      $blockerText = if ($blockers.Count -gt 0) { $blockers -join '; ' } else { 'unknown (no blockers parsed from report)' }
      Write-GuardLog "agent-readiness: attempt $attempt/$maxAttempts failed; blockers: $blockerText"

      if ($attempt -lt $maxAttempts) {
        Start-Sleep -Seconds 3
      } else {
        $ping = Get-ClauthPing 3
        Write-GuardLog "agent-readiness: failed after $maxAttempts attempts; fresh clauth ping $(Format-ClauthPing $ping)"
        throw "Agent readiness failed after $maxAttempts attempts. Run: pnpm agent:readiness"
      }
    }
  } finally {
    Pop-Location
  }
}

function Open-AgentDashboards {
  $maxAgeSeconds = 600
  if (Test-Path $OpenedStampFile) {
    $age = (New-TimeSpan -Start (Get-Item $OpenedStampFile).LastWriteTime -End (Get-Date)).TotalSeconds
    if ($age -lt $maxAgeSeconds) {
      Write-GuardLog 'dashboards: recently prepared'
      return
    }
  }

  $clauthUrl = 'http://127.0.0.1:52437'
  $devCenterUrl = 'http://127.0.0.1:3003/agent-manager'
  $openDashboards = $env:REGEN_OPEN_DASHBOARDS -eq '1'

  if ($openDashboards) {
    Write-GuardLog 'dashboards: opening clauth and Dev Center because REGEN_OPEN_DASHBOARDS=1'
    Start-Process $clauthUrl -WindowStyle Minimized | Out-Null
  } else {
    Write-GuardLog "dashboards: prepared clauth at $clauthUrl (browser launch suppressed)"
  }

  if (Test-HttpOk 'http://127.0.0.1:3003/api/version' 5) {
    if ($openDashboards) {
      Start-Process $devCenterUrl -WindowStyle Minimized | Out-Null
    } else {
      Write-GuardLog "dashboards: prepared Dev Center at $devCenterUrl (browser launch suppressed)"
    }
  }
  Set-Content -Path $OpenedStampFile -Value (Get-Date -Format o)
}

# Prove (or disprove) that a Codex repo lane is ready for EDITS — distinct from
# service health. Returns a status string; only one starting with 'READY' clears
# the gate. Mirrors the launcher's invariant: registered worktree + on wt/<name> +
# clean-or-known + 0/0 vs a freshly-fetched origin/develop + required docs present.
function Get-CodexLaneStatus {
  param([string]$Name)
  $wtRoot = "$RepoRoot.wt"
  $path = Join-Path $wtRoot $Name
  $branch = "wt/$Name"
  if (-not (Test-Path -LiteralPath $path)) { return "MISSING (no directory at $path)" }
  $inside = git -C $path rev-parse --is-inside-work-tree 2>$null
  if ($LASTEXITCODE -ne 0 -or $inside -ne 'true') { return 'INVALID (directory exists but is not a git worktree)' }
  $norm = ($path -replace '/', '\').TrimEnd('\')
  $registered = $false
  foreach ($line in (git -C $RepoRoot worktree list --porcelain 2>$null)) {
    if ($line -like 'worktree *') {
      $wp = (($line.Substring('worktree '.Length).Trim()) -replace '/', '\').TrimEnd('\')
      if ($wp -ieq $norm) { $registered = $true; break }
    }
  }
  if (-not $registered) { return 'UNREGISTERED (not in `git worktree list`)' }
  $cur = git -C $path rev-parse --abbrev-ref HEAD 2>$null
  if ($cur -ne $branch) { return "WRONG-BRANCH (on $cur, expected $branch)" }
  $docs = @('CLAUDE.md', '.codex/CODEX.md', 'docs/systems/cs2/BRIDGE-MODE-SPEC.md', '.rdc/guides/agent-bootstrap.md')
  $missing = @($docs | Where-Object { -not (Test-Path -LiteralPath (Join-Path $path $_)) })
  if ($missing.Count -gt 0) { return "UNPOPULATED (missing: $($missing -join ', '))" }
  # ACTIVE REPAIR via the ONE shared lane-sync primitive (scripts/wt-pool.mjs sync-lane):
  # `git rebase --autostash origin/develop` -- fast-forwards a behind-only lane, REPLAYS
  # (preserves) any unlanded commits, and autostashes a dirty tree. Exit 0 = lane current;
  # exit 1 = commits that will not rebase (true conflict) -- surfaced as STALE, never reset.
  # This keeps BOTH sync points (pool re-attach in wt-pool.mjs + this guard) on one hardened
  # path with NO `git reset --hard` anywhere (2026-07-05 review: unify + never-destroy).
  $node = Assert-Command node
  $sync = & $node (Join-Path $RepoRoot 'scripts\wt-pool.mjs') 'sync-lane' $path 2>&1
  if ($LASTEXITCODE -eq 0) {
    return "READY (synced to origin/develop via sync-lane; registered, $branch, docs present)"
  }
  return "STALE ($branch will not sync to origin/develop -- land or resolve in the lane: $($sync | Select-Object -Last 1))"
}

function Test-GuardFresh {
  # A named pool lane (x-codex-N or claude-N) must be re-proven every run — the
  # service-freshness short-circuit must never stand in for lane readiness.
  if ($CodexLane) { return $false }
  if ($Force -or -not (Test-Path $StampFile)) { return $false }
  $age = (New-TimeSpan -Start (Get-Item $StampFile).LastWriteTime -End (Get-Date)).TotalSeconds
  if ($age -gt $MinIntervalSeconds) { return $false }
  return (Test-ClauthUnlocked) -and
    (Test-CorpusReady) -and
    (Test-HttpOk 'http://127.0.0.1:3109/health' 15) -and
    (Test-HttpOk 'http://127.0.0.1:3003/api/version' 1)
}

try {
  $mutex = [Threading.Mutex]::new($false, $MutexName)
  $hasLock = $mutex.WaitOne(0)

  if (-not $hasLock) {
    if ($mutex.WaitOne([TimeSpan]::FromSeconds(10))) {
      $hasLock = $true
    } elseif (Test-GuardFresh) {
      Write-Output 'agent-startup: ready'
      exit 0
    } else {
      Write-Output 'agent-startup: another startup check is already running'
      exit 0
    }
  }

  if (Test-GuardFresh) {
    Write-Output 'agent-startup: ready'
    exit 0
  }

  Write-GuardLog '==== agent startup guard begin ===='
  Ensure-CorpusRoots
  Ensure-EnvironmentRepo
  Ensure-Clauth
  Ensure-RdcSkills
  Ensure-PnpmInstall
  Ensure-CodeFlow
  Ensure-DevCenter
  Ensure-AgentReadiness
  # Machine-wide dev-tools + repo freshness (non-blocking; shows last result, refreshes in bg).
  # Runs for every session/both engines — it is intentionally NOT gated on a lane, because the
  # global tools + main-tree develop it checks are machine-wide, not per-worktree.
  Ensure-DevToolsFresh

  # Repo-lane proof — services-ready is necessary but NOT sufficient for repo edits.
  # Only gates when a Codex lane is named; FAILS loudly (does not report ready) if
  # the exact active lane is missing/invalid/unregistered/wrong-branch/stale/unpopulated.
  if ($CodexLane) {
    $laneStatus = Get-CodexLaneStatus -Name $CodexLane
    Write-GuardLog "codex-lane[$CodexLane]: $laneStatus"
    if ($laneStatus -notlike 'READY*') {
      throw "Codex repo lane '$CodexLane' is NOT ready for edits: $laneStatus. Re-run scripts/codex-worktree-launch.ps1 to repair/select a lane before editing."
    }
  }

  if ($OpenDashboards) {
    Open-AgentDashboards
  }
  Set-Content -Path $StampFile -Value (Get-Date -Format o)
  Write-GuardLog '==== agent startup guard end ok ===='
  $laneSuffix = if ($CodexLane) { "; codex lane $CodexLane ready for edits" } else { '' }
  if (Test-HttpOk 'http://127.0.0.1:3003/api/version' 5) {
    Write-Output "agent-startup: clauth, codeflow, hydration, and dev-center ready$laneSuffix"
  } else {
    Write-Output "agent-startup: clauth, codeflow, and hydration ready; dev-center skipped (production build missing or not healthy)$laneSuffix"
  }
  exit 0
} catch {
  Write-GuardLog "FAILED: $($_.Exception.Message)"
  if ($_.Exception.Message -like 'CORPUS ROOT UNRESOLVED:*') {
    Write-Output ''
    Write-Output '*** STOP - CORPUS ROOT UNRESOLVED ***'
    Write-Output 'Corpus-relative paths are unsafe in this session.'
    Write-Output ''
    Write-Output "  Failure: $($_.Exception.Message)"
    Write-Output ''
    Write-Output 'Fix this before continuing:'
    Write-Output "  - Confirm CORPUS_ROOT points at the mounted master corpus root (default: $DefaultCorpusRoot)"
    Write-Output '  - Make that folder available offline / hydrated on disk'
    Write-Output '  - Re-run: powershell -File scripts/agent-startup-guard.ps1 -Force'
    Write-Output '*** ----------------------------------- ***'
    Write-Output ''
  }
  Write-Output "agent-startup: FAILED - $($_.Exception.Message)"
  exit 1
} finally {
  if ($hasLock) {
    $mutex.ReleaseMutex()
  }
  if ($mutex) {
    $mutex.Dispose()
  }
}
