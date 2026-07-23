#requires -Version 7.0
<#
.SYNOPSIS
  Open the agent cockpit in a fresh WezTerm window on the `regen` workspace.

.DESCRIPTION
  Thin entrypoint. Launches a new WezTerm GUI window bound to workspace `regen`;
  the launching pane runs start-agent-cockpit.ps1, which sets its own title and
  resume command, then spawns the remaining cockpit tabs.

  This does NOT kill any existing WezTerm window or session (per the
  terminal-recovery rule — never taskkill wezterm). It opens a new window. If a
  `regen` workspace window already exists, WezTerm attaches a new window to that
  same workspace.

  Typical use after a reboot / crash:
      pwsh -File C:\Dev\regen-root\scripts\wezterm-restart.ps1

  Or, with the function loaded from wezterm-start.ps1 / your profile:
      wezterm-restart

.PARAMETER Workspace
  Workspace name to launch into (default 'regen').

.PARAMETER Save
  Run save-cockpit-session.ps1 first to refresh the manifest, then restore.

.PARAMETER WhatIf
  Print the wezterm command that would be run without launching anything.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$Repo = 'C:\Dev\regen-root',
  [string]$Workspace = 'regen',
  [switch]$Save
)

$ErrorActionPreference = 'Stop'

$cockpit = Join-Path $Repo 'scripts\start-agent-cockpit.ps1'
$saver   = Join-Path $Repo 'scripts\save-cockpit-session.ps1'

if ($Save) {
  if ($PSCmdlet.ShouldProcess($saver, 'Refresh cockpit manifest before restore')) {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $saver
  }
}

if (-not (Get-Command 'wezterm' -ErrorAction SilentlyContinue)) {
  Write-Error 'wezterm not found on PATH. Install WezTerm or add it to PATH, then retry.'
  return
}

# wezterm start --workspace <name> -- <prog...>
# The launching pane runs the cockpit builder, which spawns the rest of the tabs.
$wezArgs = @(
  'start', '--workspace', $Workspace, '--cwd', $Repo, '--',
  'pwsh.exe', '-NoLogo', '-NoExit', '-ExecutionPolicy', 'Bypass',
  '-File', $cockpit, '-Workspace', $Workspace
)

if ($PSCmdlet.ShouldProcess("WezTerm workspace '$Workspace'", 'Launch agent cockpit')) {
  Write-Host "wezterm $($wezArgs -join ' ')"
  Start-Process -FilePath 'wezterm' -ArgumentList $wezArgs -WorkingDirectory $Repo
  Write-Host "Launched cockpit on workspace '$Workspace'."
} else {
  Write-Host "[dry-run] wezterm $($wezArgs -join ' ')"
}
