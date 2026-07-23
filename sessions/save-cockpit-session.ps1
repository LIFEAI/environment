#requires -Version 7.0
<#
.SYNOPSIS
  Capture the currently-active Claude + Codex session IDs (and the cockpit cell
  layout) into a manifest so start-agent-cockpit.ps1 can resume them later.

.DESCRIPTION
  "Active session" = the most-recently-modified transcript file per tool, scoped
  to the regen-root repo.

    - Claude Code transcripts:
        C:\Users\<user>\.claude\projects\C--Dev-regen-root\<session-id>.jsonl
      The file base name IS the session id (verified against the `sessionId`
      field inside the first JSONL line).

    - Codex sessions:
        C:\Users\<user>\.codex\sessions\YYYY\MM\DD\rollout-<ts>-<uuid>.jsonl
      The trailing UUID in the filename IS the session id. We additionally read
      the first line (`session_meta.payload`) to confirm the id and the `cwd`,
      so only rollouts whose cwd is the regen-root repo are considered.

  The manifest is written to .rdc/cockpit/session-manifest.json (committed-repo
  relative). It records the resolved session IDs, the file they came from, the
  modified time, and the static cockpit layout (which cell/tool each tab runs).

  Idempotent + safe to run anytime. If a tool has no resumable session, that
  tool's id is left null and the cockpit will fall back to --continue / --last.

.PARAMETER WhatIf
  Resolve and print what WOULD be written, but do not write the manifest.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$Repo = 'C:\Dev\regen-root',
  [string]$ManifestPath = 'C:\Dev\regen-root\.rdc\cockpit\session-manifest.json'
)

$ErrorActionPreference = 'Stop'

function Get-RepoSlug {
  param([string]$Path)
  # Claude encodes the project dir by replacing : and \ and / with '-'.
  # C:\Dev\regen-root -> C--Dev-regen-root
  return ($Path -replace '[:\\/]', '-')
}

function Resolve-ClaudeSession {
  param([string]$Repo)

  $slug = Get-RepoSlug -Path $Repo
  $projDir = Join-Path $env:USERPROFILE ".claude\projects\$slug"
  if (-not (Test-Path -LiteralPath $projDir)) {
    Write-Verbose "Claude project dir not found: $projDir"
    return $null
  }

  $newest = Get-ChildItem -LiteralPath $projDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1
  if (-not $newest) {
    Write-Verbose "No Claude transcripts in $projDir"
    return $null
  }

  # The file base name is the session id; confirm via the first JSONL line if possible.
  $id = [System.IO.Path]::GetFileNameWithoutExtension($newest.Name)
  try {
    $firstLine = Get-Content -LiteralPath $newest.FullName -TotalCount 1 -ErrorAction Stop
    if ($firstLine) {
      $obj = $firstLine | ConvertFrom-Json -ErrorAction Stop
      if ($obj.sessionId) { $id = $obj.sessionId }
    }
  } catch {
    Write-Verbose "Could not parse first line of $($newest.Name); using filename as id."
  }

  return [pscustomobject]@{
    tool          = 'claude'
    session_id    = $id
    transcript    = $newest.FullName
    modified_utc  = $newest.LastWriteTimeUtc.ToString('o')
  }
}

function Resolve-CodexSession {
  param([string]$Repo)

  $sessionsRoot = Join-Path $env:USERPROFILE '.codex\sessions'
  if (-not (Test-Path -LiteralPath $sessionsRoot)) {
    Write-Verbose "Codex sessions root not found: $sessionsRoot"
    return $null
  }

  $repoNorm = ($Repo.TrimEnd('\')).ToLowerInvariant()

  # Newest rollouts first; stop at the first one whose cwd matches the repo.
  $rollouts = Get-ChildItem -LiteralPath $sessionsRoot -Filter 'rollout-*.jsonl' -File -Recurse -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending

  foreach ($f in $rollouts) {
    $id = $null
    $cwd = $null
    try {
      $firstLine = Get-Content -LiteralPath $f.FullName -TotalCount 1 -ErrorAction Stop
      if ($firstLine) {
        $obj = $firstLine | ConvertFrom-Json -ErrorAction Stop
        if ($obj.type -eq 'session_meta' -and $obj.payload) {
          $id  = $obj.payload.id
          $cwd = $obj.payload.cwd
        }
      }
    } catch {
      Write-Verbose "Could not parse $($f.Name); skipping."
      continue
    }

    if (-not $id) {
      # Fall back to the UUID embedded in the filename: rollout-<ts>-<uuid>.jsonl
      if ($f.BaseName -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$') {
        $id = $Matches[1]
      }
    }
    if (-not $id) { continue }

    $cwdNorm = if ($cwd) { ($cwd.TrimEnd('\')).ToLowerInvariant() } else { $null }
    if ($cwdNorm -and $cwdNorm -ne $repoNorm) {
      Write-Verbose "Codex rollout cwd $cwd != repo; skipping $($f.Name)."
      continue
    }

    return [pscustomobject]@{
      tool          = 'codex'
      session_id    = $id
      transcript    = $f.FullName
      modified_utc  = $f.LastWriteTimeUtc.ToString('o')
    }
  }

  Write-Verbose "No Codex rollout matched repo cwd $Repo."
  return $null
}

# --- Static cockpit layout -------------------------------------------------
# Mirrors the cell model (Ctrl+Alt/Alt 1-7 = SV/Portal/Data/CS2/Mktg/Infra/Spec)
# plus the two agent panes Dave wants resumed. start-agent-cockpit.ps1 reads
# this to build tabs; tools 'claude'/'codex' get their saved session injected.
$layout = @(
  [ordered]@{ title = 'Claude SV'; tool = 'claude'; role = 'sv';         scheme = 'LIFEAI Claude' }
  [ordered]@{ title = 'Codex';     tool = 'codex';  role = 'codex';      scheme = 'LIFEAI Slate'  }
  [ordered]@{ title = 'Portal';    tool = 'cell';   role = 'cell-portal'; scheme = 'LIFEAI Slate'  }
  [ordered]@{ title = 'Data';      tool = 'cell';   role = 'cell-data';   scheme = 'LIFEAI Slate'  }
  [ordered]@{ title = 'CS2';       tool = 'cell';   role = 'cell-cs2';    scheme = 'LIFEAI Dark'   }
  [ordered]@{ title = 'Mktg';      tool = 'cell';   role = 'cell-mktg';   scheme = 'LIFEAI Slate'  }
  [ordered]@{ title = 'Infra';     tool = 'cell';   role = 'cell-infra';  scheme = 'LIFEAI Dark'   }
  [ordered]@{ title = 'Spec';      tool = 'cell';   role = 'specialist';  scheme = 'LIFEAI Claude' }
)

$claude = Resolve-ClaudeSession -Repo $Repo
$codex  = Resolve-CodexSession  -Repo $Repo

if ($claude) { Write-Host "Claude session: $($claude.session_id)  ($([IO.Path]::GetFileName($claude.transcript)))" }
else         { Write-Host 'Claude session: none found (will fall back to --continue)' }

if ($codex)  { Write-Host "Codex  session: $($codex.session_id)  ($([IO.Path]::GetFileName($codex.transcript)))" }
else         { Write-Host 'Codex  session: none found (will fall back to resume --last)' }

$manifest = [ordered]@{
  schema_version = '1.0'
  generated_utc  = (Get-Date).ToUniversalTime().ToString('o')
  repo           = $Repo
  workspace      = 'regen'
  sessions       = [ordered]@{
    claude = if ($claude) { $claude.session_id } else { $null }
    codex  = if ($codex)  { $codex.session_id }  else { $null }
  }
  sources        = [ordered]@{
    claude = $claude
    codex  = $codex
  }
  layout         = $layout
}

$json = $manifest | ConvertTo-Json -Depth 8

if ($PSCmdlet.ShouldProcess($ManifestPath, 'Write cockpit session manifest')) {
  $dir = Split-Path -Parent $ManifestPath
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  Set-Content -LiteralPath $ManifestPath -Value $json -Encoding UTF8
  Write-Host "Saved cockpit manifest -> $ManifestPath"
} else {
  Write-Host '--- manifest (dry run, not written) ---'
  Write-Host $json
}
