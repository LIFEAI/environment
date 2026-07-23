@echo off
REM pnpm-env.cmd — Wrapper that ensures pnpm is on PATH for non-interactive contexts
REM (Task Scheduler, CI, automated agents, etc.)
REM
REM Problem: Windows scheduled tasks may inherit only the Machine PATH, which does NOT
REM include %LOCALAPPDATA%\pnpm or %APPDATA%\npm. This means pnpm and turbo fail.
REM
REM Usage:
REM   scripts\pnpm-env.cmd type-check        (runs: pnpm type-check)
REM   scripts\pnpm-env.cmd build              (runs: pnpm build)
REM   scripts\pnpm-env.cmd turbo type-check   (runs: pnpm turbo type-check)
REM
REM If no arguments: just sets PATH and opens a new cmd prompt.

REM -- Ensure user-level pnpm + npm dirs are on PATH --
set "PNPM_HOME=%LOCALAPPDATA%\pnpm"
set "NPM_HOME=%APPDATA%\npm"

echo %PATH% | findstr /i "pnpm" >nul 2>&1
if errorlevel 1 (
    set "PATH=%PNPM_HOME%;%NPM_HOME%;%PATH%"
)

REM -- Ensure Node.js is on PATH (should be in Machine PATH but just in case) --
echo %PATH% | findstr /i "nodejs" >nul 2>&1
if errorlevel 1 (
    set "PATH=C:\Program Files\nodejs;%PATH%"
)

REM -- Set working directory to monorepo root --
cd /d C:\Dev\regen-root

REM -- Run the command or open interactive shell --
if "%~1"=="" (
    echo PATH configured for pnpm. Opening interactive shell.
    cmd /k
) else (
    pnpm %*
)
