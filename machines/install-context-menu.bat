@echo off
:: install-context-menu.bat
:: Usage: install-context-menu.bat [api-key]
::   api-key  optional — writes key to .media-api-key fallback file
::
:: Adds "Upload to Regen Media" to right-click menu for image files
:: and creates a Send To shortcut. No admin required.

powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0install-context-menu.ps1" %*
if %ERRORLEVEL% neq 0 (
    echo.
    echo Something went wrong. See error above.
    pause
    exit /b 1
)
pause
