# patch-desktop-shortcuts.ps1 — idempotent desktop-shortcut patcher for one box.
#
# Part of the startup-environment subscript set (called by env-sync.mjs --fix,
# runnable standalone). Each subscript patches ONE concern and is safe to run
# every time. This one ensures the operator-facing "Restart clauth" shortcut
# exists on the desktop, pointing at the checked-in restart script.
#
# Idempotent: (re)writes the .lnk to the correct target every run. No admin needed.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File machines/patch-desktop-shortcuts.ps1
#   ... -Check     # report only, exit 1 if a shortcut is missing or mis-targeted

param([switch]$Check)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
if ((Split-Path -Leaf $PSScriptRoot) -eq 'dev-setup') {
  $RepoRoot = Split-Path -Parent $RepoRoot
}

# name -> target the .lnk must point at. Add future shortcuts here.
$shortcuts = @(
  @{ Name = 'Restart clauth'; Target = (Join-Path $RepoRoot 'services\restart-clauth.bat'); Icon = 'C:\Windows\System32\shell32.dll,238'; Desc = 'Shut down and restart the clauth credential daemon' }
)

$desktop = [Environment]::GetFolderPath('Desktop')
$shell = New-Object -ComObject WScript.Shell
$drift = $false

foreach ($s in $shortcuts) {
  $lnk = Join-Path $desktop ($s.Name + '.lnk')
  $targetOk = $false
  if (Test-Path $lnk) {
    $existing = $shell.CreateShortcut($lnk)
    $targetOk = ($existing.TargetPath -eq $s.Target)
  }

  if ($targetOk) {
    Write-Host "  shortcut '$($s.Name)' OK" -ForegroundColor Green
    continue
  }

  if ($Check) {
    $drift = $true
    Write-Host "  shortcut '$($s.Name)' MISSING or mis-targeted" -ForegroundColor Yellow
    continue
  }

  if (-not (Test-Path $s.Target)) {
    Write-Host "  WARN: target missing, cannot create '$($s.Name)': $($s.Target)" -ForegroundColor Yellow
    continue
  }
  $sc = $shell.CreateShortcut($lnk)
  $sc.TargetPath = $s.Target
  $sc.WorkingDirectory = Split-Path -Parent $s.Target
  $sc.IconLocation = $s.Icon
  $sc.Description = $s.Desc
  $sc.WindowStyle = 1
  $sc.Save()
  Write-Host "  shortcut '$($s.Name)' written -> $($s.Target)" -ForegroundColor Green
}

if ($Check -and $drift) { exit 1 }
exit 0
