# VS Code 1.112 Downgrade Script
# Run from PowerShell: .\scripts\install-vscode-1112.ps1

$version = "1.112.0"
$url = "https://update.code.visualstudio.com/$version/win32-x64/stable"
$installer = "$env:TEMP\VSCodeSetup-$version.exe"

Write-Host "Downloading VS Code $version..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing

Write-Host "Uninstalling VS Code 1.113..." -ForegroundColor Yellow
$uninstaller = "$env:LOCALAPPDATA\Programs\Microsoft VS Code\unins000.exe"
if (Test-Path $uninstaller) {
    Start-Process -FilePath $uninstaller -ArgumentList "/SILENT /NORESTART" -Wait
}

Write-Host "Installing VS Code $version..." -ForegroundColor Green
Start-Process -FilePath $installer -ArgumentList "/SILENT /NORESTART /MERGETASKS=!runcode,addcontextmenufiles,addcontextmenufolders,associatewithfiles,addtopath" -Wait

Write-Host "Done. Disable auto-update in VS Code settings to stay on $version." -ForegroundColor Green
Write-Host '  Add to settings.json: "update.mode": "none"' -ForegroundColor White
