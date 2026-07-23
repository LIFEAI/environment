# pnpm-env.ps1 — Ensures pnpm is on PATH for non-interactive/scheduled contexts
#
# Problem: Windows scheduled tasks may inherit only the Machine PATH, which lacks
# %LOCALAPPDATA%\pnpm and %APPDATA%\npm. This breaks pnpm and turbo.
#
# Usage:
#   powershell -File scripts\pnpm-env.ps1 type-check
#   powershell -File scripts\pnpm-env.ps1 build --filter=@regen/rdc-marketing-engine
#
# Or dot-source it to set PATH in the current session:
#   . .\scripts\pnpm-env.ps1

param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$PnpmArgs
)

# -- Ensure user-level pnpm + npm dirs are on PATH --
$pnpmHome = "$env:LOCALAPPDATA\pnpm"
$npmHome  = "$env:APPDATA\npm"
$nodeHome = "C:\Program Files\nodejs"

$pathParts = $env:PATH -split ';'

if ($pathParts -notcontains $pnpmHome) {
    $env:PATH = "$pnpmHome;$env:PATH"
}
if ($pathParts -notcontains $npmHome) {
    $env:PATH = "$npmHome;$env:PATH"
}
if ($pathParts -notcontains $nodeHome) {
    $env:PATH = "$nodeHome;$env:PATH"
}

# -- Set working directory --
Set-Location "C:\Dev\regen-root"

# -- Run pnpm with provided arguments --
if ($PnpmArgs.Count -gt 0) {
    $argString = $PnpmArgs -join ' '
    Write-Host "[pnpm-env] Running: pnpm $argString" -ForegroundColor DarkGray
    & pnpm @PnpmArgs
    exit $LASTEXITCODE
} else {
    Write-Host "[pnpm-env] PATH configured. pnpm version: $(pnpm --version)" -ForegroundColor Green
}
