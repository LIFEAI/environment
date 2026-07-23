@echo off
:: Restart clauth daemon
:: Watchdog (autostart.ps1) monitors every 15s — register it once with register-autostart.ps1.
:: This script shuts down the current daemon and starts a fresh one directly.
:: Usage: double-click or run from terminal

:: Shut down existing daemon cleanly
curl -s --max-time 3 http://127.0.0.1:52437/shutdown >nul 2>&1
if %errorlevel% equ 0 (
  echo Daemon stopped.
  timeout /t 2 /nobreak >nul
) else (
  echo No daemon running.
)

:: Kill orphaned cloudflared processes — tasklist|findstr pipe hangs on this machine,
:: so use taskkill directly (exits cleanly whether cloudflared is running or not)
taskkill /F /IM cloudflared.exe >nul 2>&1

:: Resolve npm path — try %APPDATA% first, fall back to full known path
set "CLAUTH_CMD=%APPDATA%\npm\clauth.cmd"
if not exist "%CLAUTH_CMD%" set "CLAUTH_CMD=C:\Users\%USERNAME%\AppData\Roaming\npm\clauth.cmd"
if not exist "%CLAUTH_CMD%" (
  echo ERROR: Cannot find clauth.cmd — is @lifeaitools/clauth installed globally?
  pause
  exit /b 1
)

:: Start daemon — tested: start /B cmd /c is the only non-hanging launch method
:: (tasklist pipe hangs, powershell Start-Process hangs on this machine)
echo Starting clauth daemon from %CLAUTH_CMD%...
start "" /B cmd /c "%CLAUTH_CMD% serve start"

:: Wait for it to come up — retry up to 15s
set /a i=0
:waitloop
timeout /t 2 /nobreak >nul
curl -s --max-time 2 http://127.0.0.1:52437/ping >nul 2>&1 && goto :daemonup
set /a i+=1
if %i% lss 7 goto :waitloop
echo WARNING: Daemon not up after 14s. Run manually: clauth serve start
exit /b 1

:daemonup
echo clauth daemon is running.
start "" "http://127.0.0.1:52437/"
