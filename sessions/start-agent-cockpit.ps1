#requires -Version 7.0
<#
.SYNOPSIS
  Rebuild the WezTerm agent cockpit and resume the saved Claude + Codex sessions.

.DESCRIPTION
  Reads .rdc\cockpit\session-manifest.json (produced by save-cockpit-session.ps1)
  and (re)builds one WezTerm tab per layout entry in the `regen` workspace.

  Per tab:
    - tool 'claude' : injects  claude --resume <id>   (fallback: claude --continue)
    - tool 'codex'  : injects  codex resume <id>       (fallback: codex resume --last)
    - tool 'cell'   : starts the cell-init.ps1 role (SV/Portal/Data/...).
  Each tab gets its title set and the cell role's color scheme exported.

  GRACEFUL DEGRADATION
    - Missing manifest        -> uses the built-in default layout, no saved ids.
    - Missing saved id        -> falls back to --continue / resume --last.
    - Tool not installed       -> opens a plain pwsh shell in the repo with a note,
                                  never aborts the rest of the cockpit.

  This script is meant to run INSIDE a WezTerm GUI that was launched into the
  `regen` workspace (see wezterm-restart.ps1 / the gui-startup hook). It spawns
  sibling tabs via `wezterm cli` and leaves the launching pane as tab 1.

.PARAMETER WhatIf
  Print the exact tabs + injected commands without spawning anything. Safe for
  verification without touching a live GUI.

.PARAMETER Workspace
  Target workspace name (default 'regen'). Used only for the friendly banner;
  tab spawns inherit the current window's workspace.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$Repo = 'C:\Dev\regen-root',
  [string]$ManifestPath = 'C:\Dev\regen-root\.rdc\cockpit\session-manifest.json',
  [string]$Workspace = 'regen'
)

$ErrorActionPreference = 'Stop'

function Test-Command {
  param([string]$Name)
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-DefaultLayout {
  return @(
    [pscustomobject]@{ title = 'Claude SV'; tool = 'claude'; role = 'sv';          scheme = 'LIFEAI Claude' }
    [pscustomobject]@{ title = 'Codex';     tool = 'codex';  role = 'codex';       scheme = 'LIFEAI Slate'  }
    [pscustomobject]@{ title = 'Portal';    tool = 'cell';   role = 'cell-portal'; scheme = 'LIFEAI Slate'  }
    [pscustomobject]@{ title = 'Data';      tool = 'cell';   role = 'cell-data';   scheme = 'LIFEAI Slate'  }
    [pscustomobject]@{ title = 'CS2';       tool = 'cell';   role = 'cell-cs2';    scheme = 'LIFEAI Dark'   }
    [pscustomobject]@{ title = 'Mktg';      tool = 'cell';   role = 'cell-mktg';   scheme = 'LIFEAI Slate'  }
    [pscustomobject]@{ title = 'Infra';     tool = 'cell';   role = 'cell-infra';  scheme = 'LIFEAI Dark'   }
    [pscustomobject]@{ title = 'Spec';      tool = 'cell';   role = 'specialist';  scheme = 'LIFEAI Claude' }
  )
}

# --- Load manifest ---------------------------------------------------------
$manifest = $null
if (Test-Path -LiteralPath $ManifestPath) {
  try {
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
  } catch {
    Write-Warning "Manifest at $ManifestPath is unreadable ($($_.Exception.Message)); using default layout."
  }
} else {
  Write-Warning "No manifest at $ManifestPath; using default layout (no saved session ids)."
}

$layout = if ($manifest -and $manifest.layout) { $manifest.layout } else { Get-DefaultLayout }
$claudeId = if ($manifest -and $manifest.sessions) { $manifest.sessions.claude } else { $null }
$codexId  = if ($manifest -and $manifest.sessions) { $manifest.sessions.codex }  else { $null }

$haveClaude = Test-Command 'claude'
$haveCodex  = Test-Command 'codex'

# --- Build the resume command for a tool tab -------------------------------
function Get-TabPlan {
  param([pscustomobject]$Entry)

  switch ($Entry.tool) {
    'claude' {
      if (-not $haveClaude) {
        return [pscustomobject]@{
          title = $Entry.title; scheme = $Entry.scheme
          spawnArgs = @('pwsh.exe', '-NoLogo', '-NoExit', '-Command',
            "Write-Host 'claude CLI not found on PATH; open a Claude session manually.' -ForegroundColor Yellow")
          note = 'claude CLI missing'
        }
      }
      if ($claudeId) { $cmd = "claude --resume $claudeId" }
      else           { $cmd = 'claude --continue' }
      # NOTE: the SV pane does NOT reach this branch in practice — the "Claude SV" tab
      # (dropdown profile AND the cockpit's cell-tab entry) launches through
      # cell-init.ps1 sv, which now emits the visible startup status table for every
      # role before launch. If a future direct claude --resume/--continue tab is added
      # here, mirror cell-init.ps1's session-start.sh emission (see its ~line 222 block).
      return [pscustomobject]@{
        title = $Entry.title; scheme = $Entry.scheme
        spawnArgs = @('pwsh.exe', '-NoLogo', '-NoExit', '-Command',
          "Set-Location '$Repo'; $cmd")
        note = $cmd
      }
    }
    'codex' {
      if (-not $haveCodex) {
        return [pscustomobject]@{
          title = $Entry.title; scheme = $Entry.scheme
          spawnArgs = @('pwsh.exe', '-NoLogo', '-NoExit', '-Command',
            "Write-Host 'codex CLI not found on PATH; open a Codex session manually.' -ForegroundColor Yellow")
          note = 'codex CLI missing'
        }
      }
      $cellInit = Join-Path $Repo 'scripts\cell-init.ps1'
      $resumeArg = if ($codexId) { $codexId } else { 'last' }
      return [pscustomobject]@{
        title = $Entry.title; scheme = $Entry.scheme
        spawnArgs = @('pwsh.exe', '-NoLogo', '-NoExit', '-ExecutionPolicy', 'Bypass',
          '-File', $cellInit, 'codex', '-Resume', $resumeArg)
        note = "cell-init codex -Resume $resumeArg"
      }
    }
    default {
      # A cell role -> cell-init.ps1 <role>
      $cellInit = Join-Path $Repo 'scripts\cell-init.ps1'
      return [pscustomobject]@{
        title = $Entry.title; scheme = $Entry.scheme
        spawnArgs = @('pwsh.exe', '-NoLogo', '-NoExit', '-ExecutionPolicy', 'Bypass',
          '-File', $cellInit, $Entry.role)
        note = "cell-init $($Entry.role)"
      }
    }
  }
}

# --- Spawn a single tab ----------------------------------------------------
function Start-CockpitTab {
  param([pscustomobject]$Plan, [bool]$IsFirst)

  if ($IsFirst -and $env:WEZTERM_PANE) {
    # Reuse the launching tab for the first entry: set its title + send the command.
    $paneId = $env:WEZTERM_PANE
    & wezterm cli set-tab-title --pane-id $paneId $Plan.title 2>$null | Out-Null
    # Re-invoke this tab's program by sending the command text to the live shell.
    # The launching pane is already a pwsh prompt; send the resume command + Enter.
    $sendText = ($Plan.spawnArgs[-1])  # the -Command payload
    & wezterm cli send-text --pane-id $paneId --no-paste "$sendText`r" 2>$null | Out-Null
    Write-Host ("[tab 1] {0,-10} -> {1}" -f $Plan.title, $Plan.note)
    return
  }

  $spawnArgs = @('cli', 'spawn', '--cwd', $Repo, '--') + $Plan.spawnArgs
  $newPane = (& wezterm @spawnArgs 2>$null)
  if ($newPane) {
    $newPane = $newPane.Trim()
    & wezterm cli set-tab-title --pane-id $newPane $Plan.title 2>$null | Out-Null
  }
  Write-Host ("[tab +] {0,-10} -> {1}" -f $Plan.title, $Plan.note)
}

# --- Banner ----------------------------------------------------------------
Write-Host ''
Write-Host "Agent cockpit -> workspace '$Workspace'"
Write-Host ("  claude: {0}" -f ($(if ($claudeId) { "--resume $claudeId" } elseif ($haveClaude) { '--continue (no saved id)' } else { 'CLI missing' })))
Write-Host ("  codex : {0}" -f ($(if ($codexId)  { "resume $codexId" }    elseif ($haveCodex)  { 'resume --last (no saved id)' } else { 'CLI missing' })))
Write-Host ''

$first = $true
foreach ($entry in $layout) {
  $plan = Get-TabPlan -Entry $entry

  if ($WhatIfPreference -or -not $PSCmdlet.ShouldProcess($plan.title, 'Spawn cockpit tab')) {
    Write-Host ("[dry-run] {0,-10} | {1}" -f $plan.title, ($plan.spawnArgs -join ' '))
    $first = $false
    continue
  }

  if (-not (Test-Command 'wezterm')) {
    Write-Warning 'wezterm CLI not found on PATH; cannot spawn tabs. Run this from inside WezTerm.'
    break
  }

  Start-CockpitTab -Plan $plan -IsFirst $first
  $first = $false
}

Write-Host ''
Write-Host 'Cockpit ready.'
