@echo off
REM env-sync-scheduled.cmd — daily read-only drift check wrapper for Carbon7.
REM Registered as Windows Scheduled Task "RegenEnvSyncDailyCheck".
REM Runs scripts/env-sync.mjs (no flags = read-only); logs output and drops a
REM DRIFT marker file when the script exits non-zero so drift surfaces by hand
REM or at session start. Never runs --fix (that stays an explicit human action).
setlocal
set "REPO=C:\Dev\regen-root"
set "NODE=C:\Program Files\nodejs\node.exe"
set "LOGDIR=%REPO%\.rdc\logs\env-sync"
set "MARKER=%REPO%\.rdc\env-sync-DRIFT.txt"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"
for /f %%I in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "STAMP=%%I"
set "LOG=%LOGDIR%\%STAMP%.log"

"%NODE%" "%REPO%\scripts\env-sync.mjs" > "%LOG%" 2>&1
set "RC=%ERRORLEVEL%"
copy /y "%LOG%" "%LOGDIR%\latest.log" >nul

if "%RC%"=="0" (
  if exist "%MARKER%" del "%MARKER%"
) else (
  echo DRIFT detected %STAMP% (env-sync exit %RC%). See .rdc\logs\env-sync\latest.log> "%MARKER%"
  type "%LOG%" >> "%MARKER%"
)
exit /b %RC%
