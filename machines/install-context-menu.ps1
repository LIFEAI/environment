#Requires -Version 5.1
# install-context-menu.ps1
# Usage: .\install-context-menu.ps1 [-ApiKey "your-key"]
# Called by install-context-menu.bat — no need to run directly.

param(
    [Parameter(Mandatory = $false)]
    [string]$ApiKey
)

$ErrorActionPreference = 'Stop'

$uploadScript = 'C:\Dev\regen-root\scripts\upload-to-media.ps1'
$keyFile      = 'C:\Dev\regen-root\.media-api-key'
$exts         = 'jpg','jpeg','png','webp','gif','tiff','tif','bmp','zip'

# %1 placeholder for shell verbs — build it without cmd expanding the percent sign
$pct     = [char]37
$cmd     = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uploadScript`" `"${pct}1`""

# ── 1. Registry context menu ─────────────────────────────────────────────────
Write-Host "Adding Explorer context menu entries..."
foreach ($ext in $exts) {
    $base    = "HKCU:\Software\Classes\SystemFileAssociations\.$ext\shell\Upload to Regen Media"
    $cmdPath = "$base\command"
    New-Item    -Path $cmdPath -Force | Out-Null
    Set-ItemProperty -Path $base    -Name '(default)' -Value 'Upload to Regen Media'
    Set-ItemProperty -Path $cmdPath -Name '(default)' -Value $cmd
}
Write-Host "  Done — $($exts.Count) extensions registered."

# ── 2. Send To shortcut ──────────────────────────────────────────────────────
Write-Host "Creating Send To shortcut..."
$sendTo  = [System.IO.Path]::Combine($env:APPDATA, 'Microsoft\Windows\SendTo\Regen Media.lnk')
$wshell  = New-Object -ComObject WScript.Shell
$lnk     = $wshell.CreateShortcut($sendTo)
$lnk.TargetPath  = 'powershell.exe'
$lnk.Arguments   = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uploadScript`""
$lnk.Description = 'Upload to Regen Media library'
$lnk.Save()
Write-Host "  Done — $sendTo"

# ── 3. API key file ──────────────────────────────────────────────────────────
if ($ApiKey) {
    $ApiKey.Trim() | Set-Content -LiteralPath $keyFile -Encoding UTF8 -NoNewline
    Write-Host "API key written to $keyFile"
} else {
    Write-Host "No -ApiKey passed -- clauth daemon will be used at upload time."
}

# -- 4. "Browse Regen Media" -- directory background context menu --
Write-Host "Adding 'Browse Regen Media' directory background context menu..."
$browsePath    = "HKCU:\Software\Classes\Directory\Background\shell\Browse Regen Media"
$browseCmdPath = "$browsePath\command"
New-Item -Path $browseCmdPath -Force | Out-Null
Set-ItemProperty -Path $browsePath    -Name '(default)' -Value 'Browse Regen Media'
Set-ItemProperty -Path $browseCmdPath -Name '(default)' -Value 'cmd /c start https://media-manager.dev.regendevcorp.com'
Write-Host "  Done -- right-click any folder background -> Browse Regen Media"

Write-Host ""
Write-Host "All done."
Write-Host "  Right-click any image/zip  ->  Upload to Regen Media"
Write-Host "  Right-click any image/zip  ->  Send to  ->  Regen Media"
Write-Host "  Right-click any folder background  ->  Browse Regen Media"
