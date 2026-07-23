<#
  bootstrap.ps1 - Manifest-driven, idempotent dev-environment rebuild (WP-1.3).

  Evolves newmachine/restoredev.ps1 into a reproducible bootstrap that:
    0. SAFETY PRE-FLIGHT - runs scripts/env-sync.mjs against the CURRENT C:\Dev.
       If it exits non-zero (unpushed work / drift), this script ABORTS. A rebuild
       must never run over un-pushed local work.
    1. Captures dev-env/repos.json + dev-env/config-manifest.json into memory
       BEFORE any rename (the rename moves those files out from under us).
    2. RENAMES (never deletes) C:\Dev -> C:\Dev.bak-<stamp>.
    3. clauth-enroll (kind:"secret") FIRST, from the C:\Dev.bak-<stamp> backup -
       seeds .clauth/.ssh/.npmrc/.mcp.json/.cloudflared from the vault. This MUST
       precede the clones: the owned repos are PRIVATE github.com/LIFEAI/* repos,
       so cloning them needs the GH_TOKEN / SSH key that enroll restores. Secrets
       are NEVER copied from the backup.
    4. Verifies the restored GitHub credentials are actually usable (gh auth /
       git ls-remote) before any clone. Throws if enroll produced no working
       creds - private repos cannot be cloned otherwise.
    5. Clones every class:"owned" repo from repos.json into a fresh C:\Dev,
       checked out at its pinned_sha. Scratch repos are skipped; third-party
       repos are shallow-cloned at their branch tip. (Runs AFTER enroll, so the
       private-repo auth is already in place.)
    6. Restores the remaining kind:"config" profile items per config-manifest.json:
         kind:"config"  -> copy from the C:\Dev.bak-<stamp> backup (or git, if the
                            file is tracked inside a freshly-cloned repo).
       (kind:"secret" was already handled by the enroll in step 3.)
    7. pnpm install --frozen-lockfile in regen-root.
    8. pm2 resurrect (or start the ecosystem) to bring the fleet up.
    9. Prints a final summary and the verification command.

  The backup directory C:\Dev.bak-<stamp> is NEVER deleted by this script. Delete
  it yourself only after `node C:\Dev\regen-root\scripts\env-sync.mjs` reports
  every component in sync.

  Usage (elevated PowerShell):
      .\bootstrap.ps1 -WhatIf                          # dry-run: list actions, change nothing
      .\bootstrap.ps1 -Stamp 20260614-120000           # real run, deterministic backup name
      .\bootstrap.ps1 -Stamp 20260614 -Src E:\DevMigration\Profile   # config from an SSD backup
      .\bootstrap.ps1 -Stamp 20260614 -SkipPreflight   # ONLY for a truly empty C:\Dev (no env-sync to run)

  -WhatIf prints exactly what a real run would do and renames / clones / installs
  NOTHING. It always exits 0 when the plan is well-formed.
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
  # Deterministic backup-folder stamp. Passed in (not generated) so the script is
  # testable and reproducible: C:\Dev -> C:\Dev.bak-<Stamp>. Defaults to a
  # timestamp only for convenience on an interactive real run.
  [string]$Stamp = (Get-Date -Format 'yyyyMMdd-HHmmss'),

  # Root to rebuild. Override only for testing; production is always C:\Dev.
  [string]$DevRoot = 'C:\Dev',

  # Where config-kind profile items are restored FROM. This is normally the
  # freshly-renamed backup (C:\Dev.bak-<Stamp>\..\Profile is NOT where config
  # lives - profile config lives OUTSIDE C:\Dev). Point -Src at the SSD backup's
  # Profile dir (copydev.ps1 layout) when restoring onto a brand-new machine.
  # When omitted, config items are restored in-place from the live profile (a
  # no-op same-machine rebuild) and only repos are re-cloned.
  [string]$Src = '',

  # Skip the env-sync pre-flight. ONLY valid when C:\Dev does not yet exist (a
  # genuinely fresh machine where there is nothing to lose and nothing to probe).
  [switch]$SkipPreflight,

  # Dry-run. List every action, change nothing, exit 0.
  [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

$BackupRoot   = "$DevRoot.bak-$Stamp"
$RegenRoot    = Join-Path $DevRoot 'regen-root'
$BackupRegen  = Join-Path $BackupRoot 'regen-root'

# -- Plan accumulator (printed verbatim under -WhatIf) -------------------------
$script:Plan = New-Object System.Collections.Generic.List[string]
function Add-Plan([string]$line) { $script:Plan.Add($line) }

# Set true the instant C:\Dev is renamed to the backup. Used by the post-rename
# rollback handler so it only prints the Move-Item -back command once the
# destructive rename has actually happened (a failure BEFORE the rename leaves
# C:\Dev intact and needs no rollback).
$script:RenameDone = $false

# Repos that did NOT end up on their pinned ref (checkout failed / unreachable).
# Surfaced as a warning in the final summary so a silently-wrong checkout is
# never masked by a green COMPLETE.
$script:OffRefRepos = New-Object System.Collections.Generic.List[string]

function Write-Step($msg)  { Write-Host $msg -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "  ok: $msg" -ForegroundColor Green }
function Write-Skip($msg)  { Write-Host "  skip: $msg" -ForegroundColor DarkGray }
function Write-Warn2($msg) { Write-Host "  warn: $msg" -ForegroundColor Yellow }

# ============================================================================
# HELPER - resolve %ENV% style paths in the config manifest
# ============================================================================
function Expand-ManifestPath([string]$p) {
  # config-manifest.json uses %USERPROFILE% / %APPDATA% / %LOCALAPPDATA% tokens.
  # [Environment]::ExpandEnvironmentVariables handles all of them.
  return [Environment]::ExpandEnvironmentVariables($p)
}

# ============================================================================
# 0. SAFETY PRE-FLIGHT  (must run BEFORE anything destructive)
# ============================================================================
Write-Host "`n=== BOOTSTRAP ===" -ForegroundColor Cyan
Write-Host "DevRoot : $DevRoot"
Write-Host "Backup  : $BackupRoot   (rename target - NEVER deleted)"
Write-Host "Stamp   : $Stamp"
Write-Host "Mode    : $(if ($WhatIf) { 'WHATIF (dry-run, no changes)' } else { 'LIVE' })"

$preflightScript = Join-Path $RegenRoot 'scripts\env-sync.mjs'

if ($SkipPreflight) {
  Write-Warn2 "SAFETY PRE-FLIGHT SKIPPED (-SkipPreflight). Only valid on a truly empty C:\Dev."
  Add-Plan "PRE-FLIGHT: skipped (-SkipPreflight)"
}
elseif (-not (Test-Path $RegenRoot)) {
  # No existing regen-root => fresh machine, nothing to drift-check. Allowed.
  Write-Warn2 "No existing $RegenRoot - treating as a fresh machine; env-sync pre-flight not applicable."
  Add-Plan "PRE-FLIGHT: n/a (no existing regen-root to probe)"
}
else {
  Write-Step "`n-- [0] SAFETY PRE-FLIGHT: env-sync drift gate against current C:\Dev --"
  Add-Plan "PRE-FLIGHT: node `"$preflightScript`"  (ABORT on non-zero - unpushed work / drift)"
  if ($WhatIf) {
    Write-Host "  [WhatIf] would run: node `"$preflightScript`"" -ForegroundColor Magenta
    Write-Host "  [WhatIf] a real run ABORTS here if env-sync exits non-zero." -ForegroundColor Magenta
  }
  else {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
      throw "node is not on PATH - cannot run the env-sync safety pre-flight. Install Node 22+ and re-run."
    }
    if (-not (Test-Path $preflightScript)) {
      throw "env-sync pre-flight script not found at $preflightScript - refusing to rebuild without the drift gate."
    }
    # Run the drift doctor with --gate-local-only: READ-ONLY, and exit non-zero
    # ONLY on unpushed LOCAL work (what a rebuild would destroy). Codeflow/rdc-skills
    # version drift is ignored here because the rebuild FIXES it by re-cloning.
    & node $preflightScript --gate-local-only
    $code = $LASTEXITCODE
    if ($code -ne 0) {
      throw @"
STOP: ABORT - env-sync reported drift / unpushed work (exit $code).
A machine rebuild must NEVER run over un-pushed local work.
Resolve the drift first:
  cd $RegenRoot
  node scripts\env-sync.mjs            # see the drift table
  # push or stash-pop any unpushed commits, then re-run this bootstrap.
Nothing was changed. C:\Dev is intact.
"@
    }
    Write-Ok "env-sync clean (exit 0) - safe to rebuild"
  }
}

# ============================================================================
# 0b. BITE-CHECK secret-coverage gate (WARN, non-fatal)
# ============================================================================
# Runs the gitignore bite-list auditor's secret-restore coverage check against
# the CURRENT C:\Dev BEFORE the rename. Non-fatal by design: a missing manifest
# entry should surface a visible warning (so secrets that won't be restored are
# caught), but must NOT abort a rebuild. (.claude/worktrees is gitignored and
# never cloned, so worktree --prune is routine maintenance, NOT a rebuild step.)
$biteCheckScript = Join-Path $RegenRoot 'scripts\dev-env\bite-check.mjs'
Write-Step "`n-- [0b] bite-check secret-coverage gate (warn, non-fatal) --"
Add-Plan "BITE-CHECK: node `"$biteCheckScript`"  (secret-coverage WARN gate; non-fatal; never aborts the rebuild)"
if ($WhatIf) {
  Write-Host "  [WhatIf] would run: node `"$biteCheckScript`"  (warn-only; does not gate the rebuild)" -ForegroundColor Magenta
}
elseif (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Write-Warn2 "node not on PATH - skipping bite-check secret-coverage gate (non-fatal)"
}
elseif (-not (Test-Path $biteCheckScript)) {
  Write-Warn2 "bite-check.mjs not found at $biteCheckScript - skipping secret-coverage gate (non-fatal)"
}
else {
  # Warn-only: invoke WITHOUT --check so any uncovered-secret warnings are
  # printed but the script exits 0 and the rebuild proceeds.
  & node $biteCheckScript
  Write-Ok "bite-check secret-coverage gate run (warn-only; rebuild not gated)"
}

# ============================================================================
# 1. CAPTURE MANIFESTS INTO MEMORY  (BEFORE the rename moves the files)
# ============================================================================
Write-Step "`n-- [1] capturing manifests into memory (before rename) --"

$reposManifestPath  = Join-Path $RegenRoot 'dev-env\repos.json'
$configManifestPath = Join-Path $RegenRoot 'dev-env\config-manifest.json'

foreach ($mp in @($reposManifestPath, $configManifestPath)) {
  if (-not (Test-Path $mp)) {
    throw "Manifest not found: $mp - cannot bootstrap without it. (Run from a checkout that contains dev-env/.)"
  }
}

# Parse NOW, while the files are still under the live C:\Dev. After the rename
# they live under the backup; we already hold their contents in memory.
$repos  = Get-Content $reposManifestPath  -Raw | ConvertFrom-Json
$config = Get-Content $configManifestPath -Raw | ConvertFrom-Json

$owned      = @($repos | Where-Object { $_.class -eq 'owned' })
$thirdParty = @($repos | Where-Object { $_.class -eq 'third-party' })
$scratch    = @($repos | Where-Object { $_.class -eq 'scratch' })

Write-Ok "repos.json: $($repos.Count) repos ($($owned.Count) owned, $($thirdParty.Count) third-party, $($scratch.Count) scratch)"
Write-Ok "config-manifest.json: $($config.entries.Count) profile entries"
Add-Plan "CAPTURE: repos.json ($($owned.Count) owned, $($thirdParty.Count) third-party, $($scratch.Count) scratch) + config-manifest ($($config.entries.Count) entries) read into memory"

# ============================================================================
# 2. RENAME (NEVER DELETE) C:\Dev -> C:\Dev.bak-<stamp>
# ============================================================================
Write-Step "`n-- [2] rename C:\Dev -> backup (idempotent; never deletes) --"
Add-Plan "RENAME: $DevRoot  ->  $BackupRoot   (backup preserved, never deleted)"

if (Test-Path $BackupRoot) {
  # Idempotency: a backup with this stamp already exists. Do NOT overwrite or
  # delete it. If C:\Dev also still exists we'd be ambiguous - stop loudly.
  if (Test-Path $DevRoot) {
    throw "Backup $BackupRoot already exists AND $DevRoot still exists. Refusing to overwrite a backup. Choose a fresh -Stamp."
  }
  Write-Skip "backup $BackupRoot already present (prior run) - not re-renaming"
}
elseif (-not (Test-Path $DevRoot)) {
  Write-Skip "$DevRoot does not exist (fresh machine) - nothing to rename"
}
else {
  if ($WhatIf) {
    Write-Host "  [WhatIf] would: [IO.Directory]::Move '$DevRoot' -> '$BackupRoot' (atomic, all-or-nothing)" -ForegroundColor Magenta
  }
  else {
    # ATOMIC rename via .NET Directory.Move (a single Win32 MoveFile on the
    # directory entry). Unlike PowerShell's Move-Item, it does NOT enumerate or
    # recurse the tree, so it CANNOT choke on a broken pnpm symlink inside
    # node_modules and CANNOT leave a half-moved state: it renames the whole
    # directory or throws with NOTHING moved.
    # (2026-06-14: Move-Item recursed C:\Dev's pnpm symlink farm, died on a broken
    #  junction in codeflow-testsuite\node_modules, and left a partial move that
    #  had to be reassembled by hand. Never again — atomic or stop.)
    try {
      [System.IO.Directory]::Move($DevRoot, $BackupRoot)
    }
    catch {
      throw "STOP: atomic rename '$DevRoot' -> '$BackupRoot' FAILED: $($_.Exception.Message). Directory.Move is all-or-nothing, so NOTHING was moved and $DevRoot is intact. Resolve the cause and re-run."
    }
    # Hard sanity gate: the source MUST be gone and the backup MUST exist. If not,
    # we are in a partial state - refuse to proceed (do NOT touch anything further).
    if ((Test-Path $DevRoot) -or (-not (Test-Path $BackupRoot))) {
      throw "STOP: rename did not complete cleanly (source still present OR backup missing). Refusing to continue. Inspect $DevRoot and $BackupRoot manually."
    }
    Write-Ok "renamed $DevRoot -> $BackupRoot (atomic)"
    $script:RenameDone = $true
  }
}

# Fresh C:\Dev to clone into.
if ($WhatIf) {
  Write-Host "  [WhatIf] would: New-Item -ItemType Directory '$DevRoot'" -ForegroundColor Magenta
} else {
  New-Item -ItemType Directory -Force -Path $DevRoot | Out-Null
  Write-Ok "created fresh $DevRoot"
}
Add-Plan "MKDIR : fresh $DevRoot"

# ============================================================================
# 3. CLAUTH-ENROLL  (kind:"secret" - runs BEFORE the clones)
# ============================================================================
# The owned repos are PRIVATE github.com/LIFEAI/* repos, so cloning them needs
# the GH_TOKEN / SSH key that clauth-enroll restores. Enroll MUST therefore run
# BEFORE step 5 (clone). Secrets are seeded from the vault, NEVER copied from the
# backup. The enroll script lives in newmachine/ (loose .ps1 files, NOT a git
# repo), so it is never re-cloned and survives ONLY inside the backup after the
# rename - resolve it from $BackupRoot, not the fresh (empty) $DevRoot.
Write-Step "`n-- [3] clauth-enroll (secrets via clauth-enroll - NOT copied; runs BEFORE clones) --"

$secretEntries = @($config.entries | Where-Object { $_.kind -eq 'secret' })

Write-Host "  secrets (restore_via=clauth-enroll - NOT copied):" -ForegroundColor White
foreach ($s in $secretEntries) {
  $dst = Expand-ManifestPath $s.path
  Write-Host "    secret: $($s.name) -> $dst  [clauth-enroll]" -ForegroundColor DarkYellow
  Add-Plan "SECRET (clauth-enroll, NOT copied): $($s.name) -> $dst"
}
$enrollScript     = Join-Path $BackupRoot 'newmachine\clauth-enroll-zoen-life.ps1'
$newmachineBackup = Join-Path $BackupRoot 'newmachine'
$newmachineFresh  = Join-Path $DevRoot   'newmachine'
Add-Plan "CLAUTH-ENROLL: run $enrollScript  (from BACKUP - newmachine is never re-cloned; seeds .clauth/.ssh/.npmrc/.mcp.json/.cloudflared from the vault; BEFORE clones so private-repo auth exists)"
Add-Plan "COPY newmachine: $newmachineBackup -> $newmachineFresh  (so loose newmachine scripts survive into the fresh C:\Dev for the next rebuild)"
Add-Plan "ENROLL GATE: HARD-FAIL (throw) if enroll script missing OR enroll exits non-zero - never report COMPLETE on a credential-less box"
if ($WhatIf) {
  Write-Host "    [WhatIf] would copy $newmachineBackup -> $newmachineFresh (carry loose newmachine scripts forward)" -ForegroundColor Magenta
  Write-Host "    [WhatIf] would run clauth enroll from BACKUP: $enrollScript" -ForegroundColor Magenta
  Write-Host "    [WhatIf] would HARD-FAIL (throw) if that script is missing - a credential-less box must never report COMPLETE." -ForegroundColor Magenta
  Write-Host "    [WhatIf] would capture `$LASTEXITCODE and throw on non-zero - a failed enroll must not be swallowed." -ForegroundColor Magenta
  Write-Host "    [WhatIf] secrets are seeded by clauth from the vault, NOT copied from $BackupRoot." -ForegroundColor Magenta
  Write-Host "    [WhatIf] enroll runs BEFORE the clones so the private-repo GH credentials exist when cloning." -ForegroundColor Magenta
}
else {
  # Carry newmachine/ forward from the backup into the fresh C:\Dev FIRST, so the
  # loose scripts (which no repo clone provides) survive for the next rebuild.
  # Best-effort: must NOT mask an enroll failure, so it never throws.
  if (Test-Path $newmachineBackup) {
    try {
      robocopy $newmachineBackup $newmachineFresh /E /COPY:DAT /R:1 /W:1 /NP /NFL /NDL | Out-Null
      Write-Ok "copied newmachine/ from backup into fresh $DevRoot"
    } catch {
      Write-Warn2 "could not copy newmachine/ from backup ($newmachineBackup): $_"
    }
  } else {
    Write-Warn2 "newmachine/ not present in backup ($newmachineBackup) - nothing to carry forward"
  }

  # HARD-FAIL (throw), never warn: if the enroll script is missing we cannot
  # restore ANY secret and the box is left credential-less. A credential-less
  # box must NEVER be reported as a successful COMPLETE.
  if (-not (Test-Path $enrollScript)) {
    throw @"
STOP: clauth-enroll script not found at
  $enrollScript
This script lives in newmachine/ (loose .ps1 files, NOT a git repo), so it is
never re-cloned - it survives ONLY inside the backup $BackupRoot. Without it NO
secret can be restored and this machine would be left credential-less. Refusing
to continue to COMPLETE on a credential-less box.

Recover the backup or run clauth enroll manually (see dev-env/bootstrap.README.md),
then re-run this bootstrap. The backup $BackupRoot is intact.
"@
  }

  Write-Host "    -> running clauth enroll from backup (interactive: sets a machine vault password)..." -ForegroundColor Yellow
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enrollScript
  # Capture IMMEDIATELY - a failed enroll must NOT be swallowed and reported COMPLETE.
  $enrollExit = $LASTEXITCODE
  if ($enrollExit -ne 0) {
    throw @"
STOP: clauth enroll FAILED (exit $enrollExit).
  $enrollScript
Secrets were NOT restored - this machine is credential-less. Refusing to
continue to COMPLETE. Re-run clauth enroll manually (see dev-env/bootstrap.README.md),
verify
  curl http://127.0.0.1:52437/list-services
returns services, then re-run this bootstrap. The backup $BackupRoot is intact.
"@
  }
  Write-Ok "clauth enroll invoked (exit 0)"
}

# ============================================================================
# 3b. WIRE GIT -> GITHUB AUTH from the clauth vault.
# ============================================================================
# clauth-enroll seeds the vault but does NOT configure git. Without this, every
# HTTPS clone of a private github.com/LIFEAI/* repo below fails to authenticate
# (git tries to prompt for a username in a non-interactive context). Pull the
# 'github' token from the clauth daemon and wire it into gh + git.
Write-Step "`n-- [3b] wire git credential auth from the clauth GitHub token --"
Add-Plan "GIT AUTH: fetch clauth 'github' token; gh auth login --with-token + gh auth setup-git (so private-repo HTTPS clones authenticate)"
if ($WhatIf) {
  Write-Host "  [WhatIf] would: fetch clauth 'github' token; gh auth login --with-token; gh auth setup-git" -ForegroundColor Magenta
}
else {
  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "STOP: gh CLI is not on PATH - cannot wire git to GitHub for the private-repo clones. Install gh (winget install GitHub.cli), then re-run. The backup $BackupRoot is intact."
  }
  # 1. Already authenticated (the common case on an existing box) -> just wire git.
  gh auth status --hostname github.com 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) {
    gh auth setup-git 2>$null
    Write-Ok "git wired to GitHub (gh was already authenticated)"
  }
  else {
    # 2. Not authed yet -> try the clauth 'github' token (fully automated, no prompt).
    $ghTok = $null
    try { $ghTok = (Invoke-RestMethod -Uri 'http://127.0.0.1:52437/v/github' -TimeoutSec 8 | Out-String).Trim() } catch { $ghTok = $null }
    if (-not [string]::IsNullOrWhiteSpace($ghTok)) {
      $ghTok | gh auth login --hostname github.com --with-token 2>$null
      gh auth setup-git 2>$null
      Write-Ok "git wired to GitHub via gh (clauth token)"
    }
    else {
      # 3. Fallback: ONE interactive gh login. You are in the elevated window, so
      #    this prompts once and then persists (gh auth setup-git wires git to it).
      Write-Warn2 "no clauth github token available - falling back to a one-time interactive 'gh auth login' (you'll be prompted once)."
      gh auth login --hostname github.com
      if ($LASTEXITCODE -ne 0) {
        throw "STOP: interactive 'gh auth login' did not complete - cannot clone private repos. Re-run after logging in. The backup $BackupRoot is intact."
      }
      gh auth setup-git 2>$null
      Write-Ok "git wired to GitHub via a one-time interactive gh login"
    }
  }
}

# ============================================================================
# 4. VERIFY GITHUB CREDENTIALS  (prove enroll produced usable auth before cloning)
# ============================================================================
# Enroll exiting 0 means the vault was seeded; it does NOT prove the GitHub
# credential is actually usable. The owned repos are private, so a clone with a
# missing / wrong token fails for EVERY repo. Probe once here and throw with a
# clear message, rather than letting all owned clones fail one by one below.
Write-Step "`n-- [4] verify GitHub credentials are live (before any private-repo clone) --"
$ghProbeRemote = ($owned | Where-Object { -not [string]::IsNullOrWhiteSpace($_.remote) } | Select-Object -First 1).remote
Add-Plan "VERIFY CREDS: gh auth status (or git ls-remote $ghProbeRemote) - THROW if GH creds not usable; private owned repos cannot be cloned without them"
if ($WhatIf) {
  Write-Host "  [WhatIf] would verify GitHub auth via 'gh auth status' (fallback: git ls-remote $ghProbeRemote)" -ForegroundColor Magenta
  Write-Host "  [WhatIf] would THROW if creds are not usable - 'clauth enrolled but GH credentials not usable - cannot clone private repos'." -ForegroundColor Magenta
}
else {
  # AUTHORITATIVE check: can we actually READ a PRIVATE owned repo? gh-auth-exists
  # is NOT sufficient — gh may be logged into a wrong-scope/personal account that
  # 403s on github.com/LIFEAI/*. So probe the real owned remote with git ls-remote
  # (covers both the GH_TOKEN and SSH paths). A missing probe remote is a hard error
  # because we then cannot prove the owned clones will succeed.
  if ([string]::IsNullOrWhiteSpace($ghProbeRemote)) {
    throw "STOP: no owned remote available to verify private-repo auth - cannot prove the owned clones will succeed. Check dev-env/repos.json (no class:'owned' entry has a remote)."
  }
  git ls-remote $ghProbeRemote 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) {
    Write-Ok "git ls-remote $ghProbeRemote OK - GitHub credentials can read the private owned repos"
  } else {
    throw @"
STOP: clauth enrolled but GitHub credentials cannot READ the private owned repos.
'git ls-remote $ghProbeRemote' FAILED after enroll. (Note: gh merely being logged in
is NOT enough - the GH_TOKEN / SSH key must have github.com/LIFEAI org access.) The
owned repos are PRIVATE; without working creds every owned clone in step 5 would 403.
Fix the credential (gh auth login -h github.com  OR  re-run clauth enroll and confirm
curl http://127.0.0.1:52437/list-services  lists the github token), then re-run this
bootstrap. Nothing further was changed; the backup $BackupRoot is intact.
"@
  }
}

# ============================================================================
# 5. CLONE REPOS  (owned @ pinned_sha; third-party shallow; scratch skipped)
# ============================================================================
# Runs AFTER clauth-enroll (step 3) + credential verification (step 4) so the
# private-repo GitHub auth is already in place and proven usable.
Write-Step "`n-- [5] clone repos from repos.json (after enroll + cred verify) --"
Add-Plan "ROLLBACK GUARD: clone failures AFTER the rename print 'Move-Item ""$BackupRoot"" ""$DevRoot""' + the backup location, then rethrow"

function Invoke-CloneRepo($entry, [switch]$Shallow) {
  $slug   = $entry.slug
  $dest   = Join-Path $DevRoot $slug
  $remote = $entry.remote
  $branch = $entry.branch
  $sha    = $entry.pinned_sha

  if ([string]::IsNullOrWhiteSpace($remote)) {
    Write-Skip "$slug - no remote (scratch/local-only); not cloneable"
    Add-Plan "CLONE skip: $slug (no remote)"
    return
  }

  if (Test-Path (Join-Path $dest '.git')) {
    # Idempotency: already cloned. Fetch + checkout the pinned ref instead of re-cloning.
    Add-Plan "CHECKOUT: $slug already present -> fetch + checkout $(if ($Shallow) { $branch } else { $sha })"
    if ($WhatIf) {
      Write-Host "  [WhatIf] would: git -C '$dest' fetch + checkout $(if ($Shallow) { $branch } else { $sha })" -ForegroundColor Magenta
    } else {
      git -C $dest fetch --all -q 2>$null
      $ref = if ($Shallow) { $branch } else { $sha }
      git -C $dest checkout $ref -q 2>$null
      if ($LASTEXITCODE -ne 0) {
        Write-Warn2 "$slug - checkout of $ref FAILED (already-cloned path); repo is NOT on its pinned ref"
        $script:OffRefRepos.Add("$slug (wanted $ref)")
      } else {
        Write-Ok "$slug @ $ref"
      }
    }
    return
  }

  if ($Shallow) {
    Add-Plan "CLONE (shallow): $remote -> $dest  @ branch $branch"
    if ($WhatIf) {
      Write-Host "  [WhatIf] would: git clone --depth 1 --branch $branch $remote '$dest'" -ForegroundColor Magenta
    } else {
      git clone --depth 1 --branch $branch $remote $dest -q
      if ($LASTEXITCODE -ne 0) {
        Write-Warn2 "clone failed: $slug ($remote)"
        $script:OffRefRepos.Add("$slug (shallow clone of $branch failed)")
        return
      }
      Write-Ok "$slug (shallow @ $branch)"
    }
  }
  else {
    Add-Plan "CLONE: $remote -> $dest  @ pinned_sha $sha (branch $branch)"
    if ($WhatIf) {
      Write-Host "  [WhatIf] would: git clone $remote '$dest'; git -C '$dest' checkout $sha" -ForegroundColor Magenta
    } else {
      git clone $remote $dest -q
      if ($LASTEXITCODE -ne 0) {
        Write-Warn2 "clone failed: $slug ($remote)"
        $script:OffRefRepos.Add("$slug (clone failed)")
        return
      }
      # Pin to the exact recorded SHA so the rebuild is byte-reproducible.
      git -C $dest checkout $sha -q 2>$null
      if ($LASTEXITCODE -ne 0) {
        Write-Warn2 "pinned_sha $sha not reachable for $slug - left on $branch tip (NOT on pinned ref)"
        $script:OffRefRepos.Add("$slug (pinned_sha $sha unreachable; on $branch tip)")
      } else {
        Write-Ok "$slug @ $sha (pinned)"
      }
    }
  }
}

# The clone phase runs AFTER the destructive rename. If it throws here, C:\Dev is
# already moved to the backup, so a bare failure would leave the box with no
# C:\Dev and no rollback instructions. Wrap it: on any post-rename failure,
# print the explicit one-line rollback command + the backup location, then
# rethrow so the run still aborts non-zero (never reports COMPLETE).
try {
  Write-Host "  owned (pinned):" -ForegroundColor White
  foreach ($e in $owned)      { Invoke-CloneRepo $e }
  Write-Host "  third-party (shallow):" -ForegroundColor White
  foreach ($e in $thirdParty) { Invoke-CloneRepo $e -Shallow }
  Write-Host "  scratch (skipped - local-only, restore from backup if needed):" -ForegroundColor White
  foreach ($e in $scratch) {
    Write-Skip "$($e.slug) - scratch; restore manually from $BackupRoot if needed"
    Add-Plan "SCRATCH skip: $($e.slug) (restore from backup if needed)"
  }
}
catch {
  if ($script:RenameDone) {
    Write-Host "`n=== CLONE FAILED AFTER RENAME - ROLLBACK AVAILABLE ===" -ForegroundColor Red
    Write-Host "C:\Dev was already renamed to the backup before this failure. Your"   -ForegroundColor Yellow
    Write-Host "original tree is intact at:"                                          -ForegroundColor Yellow
    Write-Host "  $BackupRoot"                                                        -ForegroundColor Yellow
    Write-Host "To roll back (restore the original C:\Dev), run:"                     -ForegroundColor Yellow
    Write-Host "  Remove-Item -Recurse -Force '$DevRoot'   # discard the partial fresh tree" -ForegroundColor Cyan
    Write-Host "  Move-Item '$BackupRoot' '$DevRoot'"                                  -ForegroundColor Cyan
  }
  throw
}

# ============================================================================
# 6. RESTORE CONFIG  (kind:"config" only; secrets were enrolled in step 3)
# ============================================================================
# kind:"secret" entries were already restored by the clauth-enroll in step 3
# (BEFORE the clones, because private-repo auth depends on them). This step
# restores the remaining kind:"config" profile items only - copy from -Src /
# backup, or note the git-tracked ones the repo clone already placed.
Write-Step "`n-- [6] restore profile config (kind:config only; secrets already enrolled in step 3) --"

# Where config-kind items are restored FROM. Prefer an explicit -Src (SSD backup
# Profile dir, copydev.ps1 layout). If not given, we cannot pull config from the
# C:\Dev backup (profile config lives OUTSIDE C:\Dev), so config items that are
# not already in place are reported as manual follow-ups.
$profileSrc = if ($Src) { $Src } else { '' }

$configEntries = @($config.entries | Where-Object { $_.kind -eq 'config' })

# config: copy from backup/-Src, or note git-tracked ones
Write-Host "  config (restore_via=copy|git):" -ForegroundColor White
foreach ($c in $configEntries) {
  $dst = Expand-ManifestPath $c.path
  switch ($c.restore_via) {
    'git' {
      # These live inside a freshly-cloned repo (regen-root/.claude, newmachine, etc.).
      # No copy needed - the clone already placed them.
      Write-Skip "$($c.name) -> tracked in git (restored by repo clone): $dst"
      Add-Plan "CONFIG (git): $($c.name) -> $dst  (provided by repo clone, no copy)"
    }
    default {
      # restore_via = copy
      $leafName = Split-Path $dst -Leaf
      # Source candidate: -Src\<manifest-name> (copydev.ps1 stores by entry Name).
      $srcCandidate = if ($profileSrc) { Join-Path $profileSrc $c.name } else { '' }
      Add-Plan "CONFIG (copy): $($c.name) -> $dst  (from $(if ($srcCandidate) { $srcCandidate } else { '<no -Src given: manual>' }))"
      if ($WhatIf) {
        Write-Host "    [WhatIf] would copy: $(if ($srcCandidate) { $srcCandidate } else { '<-Src not set>' }) -> $dst" -ForegroundColor Magenta
      }
      elseif (-not $profileSrc) {
        Write-Skip "$($c.name) - no -Src backup given; restore manually if needed: $dst"
      }
      elseif (-not (Test-Path $srcCandidate)) {
        Write-Skip "$($c.name) - not present in backup ($srcCandidate)"
      }
      else {
        $parent = Split-Path $dst -Parent
        if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        if (Test-Path $srcCandidate -PathType Leaf) {
          Copy-Item -LiteralPath $srcCandidate -Destination $dst -Force
        } else {
          robocopy $srcCandidate $dst /E /COPY:DAT /R:1 /W:1 /NP /NFL /NDL | Out-Null
        }
        Write-Ok "config $($c.name) -> $dst"
      }
    }
  }
}

# ============================================================================
# 7. pnpm install --frozen-lockfile  (regen-root)
# ============================================================================
Write-Step "`n-- [7] pnpm install --frozen-lockfile (regen-root) --"
Add-Plan "PNPM: corepack enable; pnpm -C $RegenRoot install --frozen-lockfile"
if ($WhatIf) {
  Write-Host "  [WhatIf] would: corepack enable; pnpm -C '$RegenRoot' install --frozen-lockfile" -ForegroundColor Magenta
}
else {
  if (-not (Test-Path $RegenRoot)) {
    Write-Warn2 "regen-root not present at $RegenRoot - skipping pnpm install"
  } else {
    corepack enable 2>$null
    git config --global core.longpaths true 2>$null  # deep node_modules on Windows
    Push-Location $RegenRoot
    try {
      pnpm install --frozen-lockfile
      if ($LASTEXITCODE -ne 0) { $script:PnpmFailed = $true; Write-Warn2 "pnpm install --frozen-lockfile returned $LASTEXITCODE - check lockfile" }
      else { Write-Ok "pnpm install --frozen-lockfile complete" }
    } finally { Pop-Location }
  }
}

# ============================================================================
# 8. pm2 resurrect  (bring the fleet up)
# ============================================================================
Write-Step "`n-- [8] pm2 resurrect (bring the fleet up) --"
Add-Plan "PM2: pm2 resurrect   (restore the saved process list; then pm2 list to verify the fleet)"
if ($WhatIf) {
  Write-Host "  [WhatIf] would: pm2 resurrect; then pm2 list to verify the fleet" -ForegroundColor Magenta
}
else {
  if (Get-Command pm2 -ErrorAction SilentlyContinue) {
    pm2 resurrect 2>$null
    Write-Ok "pm2 resurrect invoked"
    Write-Host "  -- pm2 list --" -ForegroundColor White
    pm2 list
  } else {
    Write-Warn2 "pm2 not on PATH - install with 'npm i -g pm2', then 'pm2 resurrect' (see README)"
  }
}

# ============================================================================
# 9. FINAL SUMMARY
# ============================================================================
if ($WhatIf) {
  Write-Host "`n=== [WhatIf] PLANNED ACTIONS (nothing was changed) ===" -ForegroundColor Magenta
  $i = 0
  foreach ($line in $script:Plan) { $i++; Write-Host ("  {0,2}. {1}" -f $i, $line) -ForegroundColor Gray }
  Write-Host "`n[WhatIf] No rename, no clone, no install, no pm2 change occurred." -ForegroundColor Magenta
  exit 0
}

# Surface any repo that did NOT land on its pinned ref so a silently-wrong
# checkout is never masked by the green COMPLETE banner below.
if ($script:OffRefRepos.Count -gt 0) {
  Write-Host "`n=== WARNING: $($script:OffRefRepos.Count) repo(s) NOT on their pinned ref ===" -ForegroundColor Yellow
  foreach ($r in $script:OffRefRepos) { Write-Warn2 $r }
  Write-Host "  -> the rebuild is NOT byte-reproducible for the repos above; investigate before relying on them." -ForegroundColor Yellow
}

# A failed pnpm install means node_modules is incomplete and the fleet may not run —
# never let that be masked by the green COMPLETE banner.
if ($script:PnpmFailed) {
  Write-Host "`n=== WARNING: pnpm install --frozen-lockfile FAILED ===" -ForegroundColor Yellow
  Write-Warn2 "node_modules may be incomplete - the fleet may not run. Re-run: pnpm -C '$RegenRoot' install --frozen-lockfile"
  Write-Host "  -> this box is NOT fully rebuilt until pnpm install succeeds." -ForegroundColor Yellow
}

Write-Host @"

=== BOOTSTRAP COMPLETE ===

Backup preserved (NOT deleted): $BackupRoot

Next steps:
  [ ] Verify the rebuild:
        node "$RegenRoot\scripts\env-sync.mjs"
      It must report every component IN SYNC (exit 0).
  [ ] Confirm the fleet:  pm2 list   (expected dev apps running)
  [ ] clauth:  curl http://127.0.0.1:52437/ping  -> pong
               curl http://127.0.0.1:52437/list-services  -> services present
  [ ] gh auth status ; ssh -T git@github.com

Once env-sync is green and the fleet is healthy, the backup
  $BackupRoot
can be safely deleted. It is the ONLY copy of any un-captured local state, so
verify FIRST, delete SECOND.
"@ -ForegroundColor Yellow

exit 0
