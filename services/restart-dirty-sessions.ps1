#requires -Version 7.0
<#
.SYNOPSIS
  Reopen every DIRTY worktree's crashed agent session as a tab in ONE Windows
  Terminal window.

.DESCRIPTION
  After the 2026-07-21 GPU crash, each lane worktree kept its uncommitted work on
  disk but its interactive Claude/Codex process died. This opens one Windows
  Terminal (wt.exe) window with a tab per dirty lane, each -d'd into the lane and
  running its exact resume command (claude --resume <id> / codex resume <id>).

  wt.exe takes every tab on one command line (new-tab ... ; new-tab ...), so the
  whole window is built in a single launch — no terminal-multiplexer socket to
  attach to.

  Session IDs were resolved from the newest transcript per lane cwd
  (~/.claude/projects/<enc>/ for Claude, ~/.codex/sessions/**/rollout-*.jsonl cwd
  for Codex) on 2026-07-21.

  Run:  pwsh -File C:\Dev\regen-root\scripts\restart-dirty-sessions.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$codexExe = Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin\codex.exe'

# engine | tab title | worktree cwd | resume session id
$sessions = @(
  @{ e='codex';  t='x-codex-8'; d='C:\Dev\regen-root.wt\x-codex-8'; id='019f85d7-b266-7993-8f73-170337741b19' }
  @{ e='codex';  t='x-codex-7'; d='C:\Dev\regen-root.wt\x-codex-7'; id='019f5a18-6351-7111-b991-be47c75a48e2' }
  @{ e='codex';  t='x-codex-6'; d='C:\Dev\regen-root.wt\x-codex-6'; id='019f59ca-4b97-7ab1-aeb9-abbf605df855' }
  @{ e='codex';  t='x-codex-5'; d='C:\Dev\regen-root.wt\x-codex-5'; id='019f5f31-8287-7640-9d5f-2960111f03c2' }
  @{ e='codex';  t='x-codex-1'; d='C:\Dev\regen-root.wt\x-codex-1'; id='019f44d2-3c42-7112-9872-c5bf0f4e3f87' }
  @{ e='codex';  t='x-codex-4'; d='C:\Dev\regen-root.wt\x-codex-4'; id='019f156b-55ed-7ec0-a9c3-be93d5196169' }
  @{ e='claude'; t='claude-1';  d='C:\Dev\regen-root.wt\claude-1';  id='87adae4f-d5f0-4e9a-9695-9ebc273ba585' }
  @{ e='claude'; t='claude-2';  d='C:\Dev\regen-root.wt\claude-2';  id='615d617a-5f03-41db-8417-2be84356a7d5' }
  @{ e='claude'; t='claude-3';  d='C:\Dev\regen-root.wt\claude-3';  id='fb91ba53-858a-4cd0-a2f3-b15e16116b67' }
  @{ e='claude'; t='claude-4';  d='C:\Dev\regen-root.wt\claude-4';  id='1bb63edf-7e72-4359-a344-b4fc1ba69dd9' }
  @{ e='claude'; t='x-codex-3'; d='C:\Dev\regen-root.wt\x-codex-3'; id='e39da849-7067-4d5f-a14d-965d59c96e93' }
)

$wt = (Get-Command wt.exe -ErrorAction SilentlyContinue).Source
if (-not $wt) { $wt = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe' }
if (-not (Test-Path $wt)) { throw 'Windows Terminal (wt.exe) not found. Install it from the Microsoft Store, then retry.' }

# Build one wt invocation. CRITICAL: wt parses bare `;` as a tab delimiter, so
# codex commands must avoid semicolons entirely (use full-path exe, no PATH set),
# and the inter-tab separator must be PowerShell-escaped '`;'.
$wtArgs = @('-w', 'restart-dirty')
$first = $true
foreach ($s in $sessions) {
  if ($s.e -eq 'codex') { $inner = "& '$codexExe' resume $($s.id)" }
  else                  { $inner = "claude --resume $($s.id)" }
  if (-not $first) { $wtArgs += '`;' }
  $first = $false
  $wtArgs += @('new-tab', '--title', $s.t, '-d', $s.d,
               'pwsh.exe', '-NoLogo', '-NoExit', '-ExecutionPolicy', 'Bypass', '-Command', $inner)
}

Write-Host "Opening Windows Terminal window 'restart-dirty' with $($sessions.Count) tabs..."
& $wt @wtArgs
Write-Host "Launched $($sessions.Count) tabs."
