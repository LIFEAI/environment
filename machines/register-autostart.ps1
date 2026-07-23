# register-autostart.ps1 -- installs clauth watchdog as a Windows Startup item
# No admin required. Uses the user Startup folder.
# Source: C:\Dev\regen-root\scripts\autostart.ps1
#
# Run this any time the startup shortcut needs to be recreated
# (after a new machine setup, OS reinstall, or if the shortcut goes missing).

$repoScript  = 'C:\Dev\regen-root\scripts\autostart.ps1'
$startupDir  = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$lnkPath     = "$startupDir\clauth-autostart.lnk"

if (-not (Test-Path $repoScript)) {
  Write-Error "autostart.ps1 not found at $repoScript -- clone the repo first."
  exit 1
}

# Create or overwrite the startup shortcut pointing at the repo script
$shell = New-Object -ComObject WScript.Shell
$sc    = $shell.CreateShortcut($lnkPath)
$sc.TargetPath       = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$sc.Arguments        = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$repoScript`""
$sc.WorkingDirectory = 'C:\Dev\regen-root\scripts'
$sc.Description      = 'clauth daemon watchdog -- auto-restarts clauth on crash'
$sc.Save()

Write-Host "Startup shortcut created: $lnkPath"
Write-Host "Points to:               $repoScript"
Write-Host ""
Write-Host "Watchdog will start automatically at next login."
Write-Host "To start it now (without rebooting):"
Write-Host "  powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$repoScript`""
