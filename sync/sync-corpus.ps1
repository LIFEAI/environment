# sync-corpus.ps1 - mirror the Google Drive global-corpus master to the local cache.
# One-way pull: CORPUS_ROOT (source of truth) -> LOCAL_CORPUS_ROOT (read-only working copy).
# Safe on headless boxes (source not mounted -> exits 0). Never run the reverse direction.
# Plan: .rdc/plans/e8v2-global-corpus-architecture.md (WP-2)
#
# ASCII-only on purpose: this runs under Windows PowerShell 5.1 via powershell.exe, which
# decodes a no-BOM file as CP1252. Non-ASCII (em dashes, etc.) corrupts parsing. Keep ASCII.
#
# -Force            ignore the freshness window and always mirror.
# -MaxAgeHours <n>  skip if the last sync is younger than n hours (default 6).
param([switch]$Force, [int]$MaxAgeHours = 6)

# Master relocated to C:\rdc-gdrive\global-corpus (2026-07-20).
# Resolve the ONE system variable: Machine-scope is AUTHORITATIVE (operator-set).
# Process env may carry a stale pre-move path from a parent shell. Machine wins
# when set and resolvable on disk; falls back to process env, then literal default.
$DefaultCorpusRoot = 'C:\rdc-gdrive\global-corpus'
$DefaultLocalCorpusRoot = 'C:\Dev\local-corpus'
function Get-ResolvedRoot([string]$EnvValue, [string]$VarName, [string]$Default) {
    $machine = [Environment]::GetEnvironmentVariable($VarName, 'Machine')
    if ($machine) { $machine = $machine.Trim() }
    if ($machine -and (Test-Path -LiteralPath $machine)) { return $machine }
    $proc = if ([string]::IsNullOrWhiteSpace($EnvValue)) { '' } else { $EnvValue.Trim() }
    if ($proc -and (Test-Path -LiteralPath $proc)) { return $proc }
    if ($machine) { return $machine }
    if ($proc) { return $proc }
    return $Default
}
$Global = Get-ResolvedRoot $env:CORPUS_ROOT 'CORPUS_ROOT' $DefaultCorpusRoot
$Local  = Get-ResolvedRoot $env:LOCAL_CORPUS_ROOT 'LOCAL_CORPUS_ROOT' $DefaultLocalCorpusRoot

$env:CORPUS_ROOT = $Global
$env:LOCAL_CORPUS_ROOT = $Local

if (-not (Test-Path -LiteralPath $Global)) {
    Write-Warning "CORPUS_ROOT does not resolve at $Global - skipping sync."
    exit 0
}

# Freshness guard: session-start may invoke this often. Skip if synced recently. A fresh
# box has no .last-sync, so the first run always provisions fully.
$stamp = Join-Path $Local '.last-sync'
if (-not $Force -and (Test-Path -LiteralPath $stamp)) {
    $age = (Get-Date) - (Get-Item -LiteralPath $stamp).LastWriteTime
    if ($age.TotalHours -lt $MaxAgeHours) {
        Write-Host ("corpus fresh ({0}m old) - skip." -f [int]$age.TotalMinutes)
        exit 0
    }
}

# Guard: never /MIR an empty source onto the local cache (would delete the cache).
$srcCount = (Get-ChildItem -LiteralPath $Global -Recurse -File -Force -ErrorAction SilentlyContinue).Count
if ($srcCount -lt 1) {
    Write-Warning "CORPUS_ROOT=$Global has 0 files - refusing to mirror (guard). No changes made."
    exit 0
}

New-Item -ItemType Directory -Force -Path $Local | Out-Null

# /MIR mirror, /XO skip older, quiet logging, minimal retries.
robocopy $Global $Local /MIR /XO /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
$rc = $LASTEXITCODE  # robocopy: 0-7 = success, 8+ = error

(Get-Date -Format o) | Set-Content -LiteralPath (Join-Path $Local '.last-sync')

if ($rc -ge 8) {
    Write-Error "robocopy reported errors (exit $rc)."
    exit $rc
}
Write-Host ("corpus synced: {0} source files from {1} -> {2} (robocopy exit {3})." -f $srcCount, $Global, $Local, $rc)
exit 0
