@echo off
setlocal enabledelayedexpansion

:: ── GET ESC CHARACTER FOR ANSI COLORS ──────────────────────
for /f %%a in ('echo prompt $E ^| cmd') do set "ESC=%%a"

echo.
echo %ESC%[36m══════════════════════════════════════════════════%ESC%[0m
echo %ESC%[36m  CELL STATUS DASHBOARD%ESC%[0m
echo %ESC%[36m══════════════════════════════════════════════════%ESC%[0m
echo.

set "STATE_DIR=C:\Dev\regen-root\.cell-state"
set "FOUND=0"

if not exist "%STATE_DIR%" (
  echo   %ESC%[90mNo .cell-state directory.%ESC%[0m
  goto :gitinfo
)

echo %ESC%[1m  ROLE             STATUS     BRANCH              STARTED%ESC%[0m
echo   ─────────────────────────────────────────────────────────────

for %%f in (%STATE_DIR%\*.lock) do (
  set "ROLE=%%~nf"
  set "LOCKPID="
  set "STARTED="
  set "LOCKBRANCH="

  for /f "tokens=1,* delims==" %%a in (%%f) do (
    if "%%a"=="PID" set "LOCKPID=%%b"
    if "%%a"=="STARTED" set "STARTED=%%b"
    if "%%a"=="BRANCH" set "LOCKBRANCH=%%b"
  )

  :: Cross-check PID against running processes
  set "ALIVE=0"
  if defined LOCKPID (
    tasklist /fi "PID eq !LOCKPID!" /fo csv /nh 2>nul | findstr /i "cmd.exe" >nul 2>&1
    if !errorlevel!==0 set "ALIVE=1"
  )

  if "!ALIVE!"=="1" (
    echo   !ROLE!	%ESC%[32mACTIVE%ESC%[0m     !LOCKBRANCH!	!STARTED!
    set "FOUND=1"
  ) else (
    echo   !ROLE!	%ESC%[90mSTALE%ESC%[0m      !LOCKBRANCH!	!STARTED!
    :: Clean up stale lockfile
    del "%%f" >nul 2>&1
    echo   %ESC%[90m  ^(lockfile cleaned up^)%ESC%[0m
  )
)

if "%FOUND%"=="0" (
  echo   %ESC%[90mNo active cells.%ESC%[0m
)

:gitinfo
echo.
echo %ESC%[90m── Git Overview ─────────────────────────────────%ESC%[0m

for /f "tokens=*" %%i in ('git -C C:\Dev\regen-root rev-parse --abbrev-ref HEAD 2^>nul') do set "BRANCH=%%i"
echo   Branch: %ESC%[1m!BRANCH!%ESC%[0m

for /f %%i in ('git -C C:\Dev\regen-root status --porcelain 2^>nul ^| find /c /v ""') do set "CHANGES=%%i"
if "!CHANGES!"=="0" ( echo   Working tree: %ESC%[32mclean%ESC%[0m ) else ( echo   Working tree: %ESC%[33m!CHANGES! changes%ESC%[0m )

echo.
echo %ESC%[90m── Recent commits ──────────────────────────────%ESC%[0m
git -C C:\Dev\regen-root log --oneline -5 2>nul
echo.

echo %ESC%[90m── Local branches ─────────────────────────────%ESC%[0m
git -C C:\Dev\regen-root branch --list 2>nul
echo.

endlocal
