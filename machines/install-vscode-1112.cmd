@echo off
:: VS Code 1.112 Downgrade Script
:: Run from Command Prompt as Administrator

set VERSION=1.112.0
set URL=https://update.code.visualstudio.com/%VERSION%/win32-x64/stable
set INSTALLER=%TEMP%\VSCodeSetup-%VERSION%.exe

echo Downloading VS Code %VERSION%...
curl -L -o "%INSTALLER%" "%URL%"
if errorlevel 1 (
    echo Download failed. Check version number or internet connection.
    pause
    exit /b 1
)

echo Uninstalling VS Code 1.113...
set UNINSTALLER=%LOCALAPPDATA%\Programs\Microsoft VS Code\unins000.exe
if exist "%UNINSTALLER%" (
    "%UNINSTALLER%" /SILENT /NORESTART
    timeout /t 5 /nobreak >nul
)

echo Installing VS Code %VERSION%...
"%INSTALLER%" /SILENT /NORESTART /MERGETASKS=!runcode,addcontextmenufiles,addcontextmenufolders,associatewithfiles,addtopath

echo.
echo Done! Add this to VS Code settings.json to block auto-update:
echo   "update.mode": "none"
pause
