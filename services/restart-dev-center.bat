@echo off
:: Restart Dev Center local production server.
:: This is intentionally NOT PM2 and NOT next dev.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0restart-dev-center.ps1" -Open
exit /b %errorlevel%
