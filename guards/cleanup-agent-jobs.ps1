param(
  [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [int]$MinAgeSeconds = 15,
  [switch]$CleanAgentBrowsers,
  [switch]$CleanAgentDevServers,
  [ValidateSet('None', 'Codex', 'Claude')]
  [string]$HookOutput = 'None',
  [switch]$DryRun,
  # -WhatIf is an alias for -DryRun: print the RECOVER/GC plan, delete nothing.
  [switch]$WhatIf
)

$ErrorActionPreference = 'SilentlyContinue'

# -WhatIf and -DryRun are equivalent: a dry-run that prints the plan and never
# deletes. Honor either; downstream logic gates on $DryRun.
if ($WhatIf) { $DryRun = $true }

# --- Stop-hook gate ---------------------------------------------------------
# This script is wired as a Stop hook, which fires after EVERY turn. Cleaning up
# agent processes/worktrees/browsers only makes sense after a turn that actually
# spawned agents or ran fixit/build/deploy/promote/overnight. On a plain
# conversational turn there is nothing to clean, so skip (and avoid the Add-Type
# compile below). The Stop hook delivers a JSON payload on stdin carrying
# `transcript_path`; we inspect the current turn for agent/skill activity.
# A manual invocation (no stdin JSON) falls through and runs unconditionally.
$gateRaw = ''
try { if ([Console]::IsInputRedirected) { $gateRaw = [Console]::In.ReadToEnd() } } catch { $gateRaw = '' }
if ($gateRaw -and $gateRaw.TrimStart().StartsWith('{')) {
  $runCleanup = $false
  try {
    $payload = $gateRaw | ConvertFrom-Json
    $tp = $payload.transcript_path
    if ($tp -and (Test-Path -LiteralPath $tp)) {
      $lines = Get-Content -LiteralPath $tp -ErrorAction SilentlyContinue
      # Collect lines back to the start of the current turn (last real user
      # prompt — a user message that is not a tool_result echo).
      $turn = New-Object System.Collections.Generic.List[string]
      for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $ln = $lines[$i]
        $turn.Add($ln)
        if (($ln -match '"role"\s*:\s*"user"' -or $ln -match '"type"\s*:\s*"user"') -and $ln -notmatch 'tool_result') { break }
      }
      $blob = ($turn -join "`n")
      # Agent work = Task/Agent tool use. Named skills = build/fixit/deploy/release/overnight.
      if ($blob -match '"name"\s*:\s*"(Task|Agent)"' -or
          $blob -match 'rdc:(build|fixit|deploy|release|overnight)' -or
          $blob -match '"(skill|command)"\s*:\s*"(rdc:)?(build|fixit|deploy|release|overnight)"') {
        $runCleanup = $true
      }
    }
  } catch { $runCleanup = $false }
  if (-not $runCleanup) { exit 0 }
}
# --- end Stop-hook gate -----------------------------------------------------

$source = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class RegenProcessInfo {
  [StructLayout(LayoutKind.Sequential)]
  public struct PROCESS_BASIC_INFORMATION {
    public IntPtr Reserved1;
    public IntPtr PebBaseAddress;
    public IntPtr Reserved2_0;
    public IntPtr Reserved2_1;
    public IntPtr UniqueProcessId;
    public IntPtr InheritedFromUniqueProcessId;
  }

  [DllImport("ntdll.dll")]
  public static extern int NtQueryInformationProcess(IntPtr hProcess, int processInformationClass, ref PROCESS_BASIC_INFORMATION pbi, int processInformationLength, out int returnLength);

  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern IntPtr OpenProcess(int access, bool inherit, int pid);

  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, int dwSize, out IntPtr lpNumberOfBytesRead);

  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool CloseHandle(IntPtr hObject);

  const int PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
  const int PROCESS_VM_READ = 0x0010;

  static long ReadInt64(IntPtr h, long addr) {
    byte[] b = new byte[8];
    IntPtr n;
    if (!ReadProcessMemory(h, new IntPtr(addr), b, b.Length, out n)) return 0;
    return BitConverter.ToInt64(b, 0);
  }

  public static string CommandLine(int pid, out long parentPid) {
    parentPid = -1;
    IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ, false, pid);
    if (h == IntPtr.Zero) return "";
    try {
      PROCESS_BASIC_INFORMATION pbi = new PROCESS_BASIC_INFORMATION();
      int ret;
      int status = NtQueryInformationProcess(h, 0, ref pbi, Marshal.SizeOf(typeof(PROCESS_BASIC_INFORMATION)), out ret);
      if (status != 0) return "";
      parentPid = pbi.InheritedFromUniqueProcessId.ToInt64();
      long peb = pbi.PebBaseAddress.ToInt64();
      long procParams = ReadInt64(h, peb + 0x20);
      if (procParams == 0) return "";
      byte[] us = new byte[16];
      IntPtr n;
      if (!ReadProcessMemory(h, new IntPtr(procParams + 0x70), us, us.Length, out n)) return "";
      ushort len = BitConverter.ToUInt16(us, 0);
      long buf = BitConverter.ToInt64(us, 8);
      if (len == 0 || buf == 0) return "";
      byte[] str = new byte[len];
      if (!ReadProcessMemory(h, new IntPtr(buf), str, str.Length, out n)) return "";
      return Encoding.Unicode.GetString(str);
    } finally {
      CloseHandle(h);
    }
  }
}
'@

try {
  Add-Type -TypeDefinition $source | Out-Null
} catch {
  # The class may already exist when the script is dot-sourced in a long-lived shell.
}

function Normalize-Text([string]$value) {
  if (-not $value) { return '' }
  return $value.ToLowerInvariant().Replace('/', '\')
}

function Get-CommandInfo([int]$processId) {
  $parent = 0L
  $command = [RegenProcessInfo]::CommandLine($processId, [ref]$parent)
  [pscustomobject]@{
    ParentId = [int]$parent
    CommandLine = $command
  }
}

function Get-ListeningPids {
  $ids = @{}
  $lines = netstat -ano -p tcp | Select-String 'LISTENING'
  foreach ($line in $lines) {
    $parts = ($line.ToString() -split '\s+') | Where-Object { $_ }
    if ($parts.Count -ge 5) {
      $ids[[int]$parts[-1]] = $true
    }
  }
  return $ids
}

function Get-CurrentAncestry {
  $ids = @{}
  $cursor = $PID
  for ($i = 0; $i -lt 12 -and $cursor -gt 0; $i++) {
    $ids[$cursor] = $true
    $proc = Get-Process -Id $cursor -ErrorAction SilentlyContinue
    if (-not $proc) { break }
    $info = Get-CommandInfo $cursor
    if ($info.ParentId -le 0 -or $ids.ContainsKey($info.ParentId)) { break }
    $cursor = $info.ParentId
  }
  return $ids
}

function Shorten-Text([string]$value, [int]$max = 280) {
  if (-not $value) { return '' }
  $compact = ($value -replace '\s+', ' ').Trim()
  $compact = $compact -replace '(?i)(--pw|--password|--token|--secret|--api-key)\s+("[^"]*"|\S+)', '$1 [REDACTED]'
  $compact = $compact -replace '(?i)(password|token|secret|api[_-]?key)=("[^"]*"|\S+)', '$1=[REDACTED]'
  $compact = $compact -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]+', '$1[REDACTED]'
  if ($compact.Length -le $max) { return $compact }
  return $compact.Substring(0, $max - 3) + '...'
}

function Get-StopReportPath {
  $dir = Join-Path $RepoRoot '.codex'
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  return (Join-Path $dir 'cleanup-agent-jobs-stop-report.json')
}

function Get-LocalhostBrowserReason([string]$command) {
  if ($command.Contains('@playwright\mcp') -or $command.Contains('@playwright/mcp') -or $command.Contains('playwright-mcp')) {
    return 'playwright-mcp'
  }
  if ($command.Contains('\.codex\playwright-output') -or $command.Contains('/.codex/playwright-output')) {
    return 'codex-playwright-output'
  }
  if ($command.Contains('playwright_chromiumdev_profile')) {
    return 'playwright-temp-profile'
  }
  if (($command.Contains('chrome.exe') -or $command.Contains('msedge.exe')) -and (
      $command.Contains('http://localhost') -or
      $command.Contains('http:\\localhost') -or
      $command.Contains('http://127.0.0.1') -or
      $command.Contains('http:\\127.0.0.1') -or
      $command.Contains('http://[::1]') -or
      $command.Contains('http:\\[::1]'))) {
    return 'localhost-browser-launch'
  }
  return ''
}

function Get-AgentDevServerReason([string]$command) {
  if (-not $command.Contains($repoNeedle)) { return '' }
  if ($command.Contains(' next dev')) { return 'repo-next-dev' }
  if ($command.Contains(' vite ') -or $command.Contains('\vite\bin\')) { return 'repo-vite-dev' }
  if (($command.Contains(' serve ') -or $command.Contains('\serve\build\main.js')) -and -not $command.Contains('pm2')) { return 'repo-serve-dev' }
  if ($command.Contains('http-server') -or $command.Contains('python -m http.server')) { return 'repo-static-dev-server' }
  return ''
}

function Get-AgentTransferReason([string]$command) {
  if ($command.Contains($repoNeedle)) { return 'repo-transfer-job' }
  if ($command.Contains('\sites\') -or $command.Contains('/sites/')) { return 'site-transfer-job' }
  if ($command.Contains('/srv/regen/regen-root') -or $command.Contains('\srv\regen\regen-root')) { return 'remote-regen-transfer-job' }
  return ''
}

$repoNeedle = Normalize-Text $RepoRoot
$now = Get-Date
$listening = Get-ListeningPids
$protected = Get-CurrentAncestry
$candidates = @()
$reviewed = @()

foreach ($proc in Get-Process node,bash,cmd,python,python3,pwsh,powershell,chrome,msedge,scp,ssh -ErrorAction SilentlyContinue) {
  if ($protected.ContainsKey($proc.Id)) {
    continue
  }

  $info = Get-CommandInfo $proc.Id
  $command = Normalize-Text $info.CommandLine
  $age = ($now - $proc.StartTime).TotalSeconds
  if ($age -lt $MinAgeSeconds) {
    continue
  }

  $parentMissing = $info.ParentId -gt 0 -and -not (Get-Process -Id $info.ParentId -ErrorAction SilentlyContinue)
  $repoProcess = $command.Contains($repoNeedle)
  $browserReason = if ($CleanAgentBrowsers) { Get-LocalhostBrowserReason $command } else { '' }
  $devServerReason = if ($CleanAgentDevServers -and $listening.ContainsKey($proc.Id)) { Get-AgentDevServerReason $command } else { '' }
  $parentProc = if ($info.ParentId -gt 0) { Get-Process -Id $info.ParentId -ErrorAction SilentlyContinue } else { $null }
  $transferReason = if ($proc.ProcessName -in @('scp', 'ssh')) {
    $reason = Get-AgentTransferReason $command
    if ($reason) {
      $reason
    } elseif ($proc.ProcessName -eq 'ssh' -and $parentProc -and $parentProc.ProcessName -eq 'scp' -and $command.Contains(' sftp')) {
      'scp-child-sftp'
    } else {
      ''
    }
  } else {
    ''
  }
  $vitestProcess = $repoProcess -and (
    $command.Contains('\tinypool\') -or
    $command.Contains('\vitest\vitest.mjs') -or
    $command.Contains(' vitest run') -or
    ($command.Contains('npx-cli.js') -and $command.Contains('vitest'))
  )
  $orphanClaudeHook = $parentMissing -and (
    $command.Contains('\.claude\hooks\rdc-statusline.js') -or
    $command.Contains('\hooks\pretooluse.py') -or
    $command.Contains('claude_plugin_root')
  )

  if ($listening.ContainsKey($proc.Id) -or $browserReason) {
    $reviewed += [pscustomobject]@{
      Id = $proc.Id
      Name = $proc.ProcessName
      ParentId = $info.ParentId
      AgeSeconds = [math]::Round($age, 0)
      Listening = [bool]$listening.ContainsKey($proc.Id)
      Reason = if ($browserReason) { $browserReason } elseif ($devServerReason) { $devServerReason } else { 'review-only' }
      CommandLine = Shorten-Text $info.CommandLine
    }
  }

  if ($vitestProcess -or $orphanClaudeHook -or $browserReason -or $devServerReason -or $transferReason) {
    $candidates += [pscustomobject]@{
      Id = $proc.Id
      Name = $proc.ProcessName
      ParentId = $info.ParentId
      AgeSeconds = [math]::Round($age, 0)
      CPUSeconds = [math]::Round($proc.CPU, 1)
      Reason = if ($vitestProcess) {
        'repo-vitest-or-tinypool'
      } elseif ($orphanClaudeHook) {
        'orphan-claude-hook'
      } elseif ($browserReason) {
        $browserReason
      } elseif ($transferReason) {
        $transferReason
      } else {
        $devServerReason
      }
      CommandLine = Shorten-Text $info.CommandLine
    }
  }
}

$stopped = @()
foreach ($candidate in $candidates | Sort-Object Reason, Id) {
  if ($DryRun) {
    $stopped += $candidate
    continue
  }
  try {
    Stop-Process -Id $candidate.Id -Force -ErrorAction Stop
    $stopped += $candidate
  } catch {
    # Best-effort cleanup hook: do not block agent shutdown.
  }
}

# ─── Git worktree / branch GC ────────────────────────────────────────────────
# WP-3 (Worktree Isolation epic 3e300047): sibling worktrees under
# C:/Dev/regen-root.wt/* are crash-isolated cell/agent trees. The cleanup hook
# must NEVER destroy a hung/aborted session's work:
#   - dirty *.wt/* worktree              -> PRESERVE + emit a RECOVER report line
#                                           (never `git worktree remove`, never -Force)
#   - clean + branch merged into develop -> GC (git worktree remove)
#   - clean but UNmerged                 -> KEEP (carries committed work)
#   - worktree with a live owning process -> KEEP (Codex/cell still running)
#   - warm pool slot (claude-N | x-codex-N) -> KEEP (handed out instantly; never GC'd)
#   - gone wt/*|cell/* branch, no worktree -> git branch -D
#   - branch WITH a live worktree            -> KEEP (never -D)
# "Live owning process" is proven two ways: (a) a non-protected process whose
# command line contains the worktree path, AND (b) a .cell-state/<lane>.lock whose
# PID is alive — because a Codex launcher's command line is the launch SCRIPT path,
# not the worktree path, so (a) alone misses a leased lane.
# The contract is mirrored + unit-tested in scripts/__tests__/cleanup-worktree.test.mjs
# (classifyWorktree / shouldDeleteBranch). CORE INVARIANT: a dirty worktree is
# never passed to `git worktree remove` under any code path.

# Classify a worktree exactly like JS classifyWorktree() in the sibling test.
# $isPoolSlot: warm launcher-cd claude-* pool slot (regen-root.wt[\\/]claude-\d+),
# kept warm on purpose so the launcher can hand it out instantly -> exempt from GC.
function Classify-Worktree([int]$dirty, [bool]$merged, [bool]$liveProcess, [bool]$isPoolSlot) {
  if ($liveProcess) { return 'KEEP' }
  if ($dirty -gt 0) { return 'PRESERVE' }
  if ($isPoolSlot) { return 'KEEP' }
  if ($merged) { return 'GC' }
  return 'KEEP'
}

# Eligibility for `git branch -D`, mirroring JS shouldDeleteBranch().
function Select-BranchGc([string]$name, [bool]$goneOnRemote, [bool]$hasWorktree) {
  if ($name -notmatch '^(wt|cell)/') { return $false }
  if ($hasWorktree) { return $false }
  return [bool]$goneOnRemote
}

# Does any non-protected live process hold this worktree path open? Reuse the
# already-enumerated command lines (Codex/cell launchers carry the worktree path).
function Test-WorktreeLiveProcess([string]$wtPath) {
  $needle = Normalize-Text $wtPath
  if (-not $needle) { return $false }
  foreach ($proc in Get-Process node,bash,cmd,python,python3,pwsh,powershell,claude,codex -ErrorAction SilentlyContinue) {
    if ($protected.ContainsKey($proc.Id)) { continue }
    $cmd = Normalize-Text (Get-CommandInfo $proc.Id).CommandLine
    if ($cmd -and $cmd.Contains($needle)) { return $true }
  }
  return $false
}

# Ownership evidence #2 — the lock-PID path. A warm cell/agent lane records its
# owner PID in .cell-state/<lane>.lock. The Codex launcher's command line is the
# launch SCRIPT path (scripts\codex-worktree-launch.ps1), NOT the worktree path, so
# Test-WorktreeLiveProcess (command-line match) judges a live/leased Codex lane dead
# and GC's it. Consult the lock PID directly: lane leaf -> .cell-state/<leaf>.lock
# -> PID=<n> alive? Covers x-codex-N and claude-N (and any cell whose leaf matches).
function Test-WorktreeLeased([string]$wtPath) {
  if (-not $wtPath) { return $false }
  $leaf = Split-Path -Leaf $wtPath
  if (-not $leaf) { return $false }
  $lock = Join-Path $RepoRoot ".cell-state\$leaf.lock"
  if (-not (Test-Path -LiteralPath $lock)) { return $false }
  $pidLine = Get-Content -LiteralPath $lock -ErrorAction SilentlyContinue |
    Where-Object { $_ -like 'PID=*' } | Select-Object -First 1
  if (-not $pidLine) { return $false }
  $parsed = 0
  if (-not [int]::TryParse($pidLine.Substring(4).Trim(), [ref]$parsed)) { return $false }
  if ($parsed -le 0) { return $false }
  return [bool](Get-Process -Id $parsed -ErrorAction SilentlyContinue)
}

$worktreeReport = @()
$branchReport = @()
$worktreesPruned = 0
$worktreesDirty = 0
$worktreesRecover = @()
$branchesDeleted = 0

try {
  $mainWt = (git -C $RepoRoot rev-parse --show-toplevel 2>$null).Trim()
  $mainWtNorm = Normalize-Text $mainWt
  $wtLines = git -C $RepoRoot worktree list --porcelain 2>$null
  $currentWt = $null
  $currentBranch = $null
  # Branch names that currently have a live worktree — never -D these.
  $branchesWithWorktree = @{}

  foreach ($line in $wtLines) {
    if ($line -match '^worktree (.+)$') {
      $currentWt = $Matches[1].Trim()
      $currentBranch = $null
    } elseif ($line -match '^branch refs/heads/(.+)$') {
      $currentBranch = $Matches[1].Trim()
    } elseif ($line -eq '' -and $currentWt) {
      if ($currentBranch) { $branchesWithWorktree[$currentBranch] = $true }
      if ((Normalize-Text $currentWt) -eq $mainWtNorm) {
        $currentWt = $null
        continue
      }

      $dirty = 0
      try { $dirty = (git -C $currentWt status --porcelain 2>$null | Measure-Object).Count } catch {}

      # Is this a crash-isolated sibling worktree (regen-root.wt/*)?
      $isWtSibling = (Normalize-Text $currentWt).Contains('regen-root.wt\')

      # Is this a warm launcher-cd pool slot? Both claude-N (Claude pool) and
      # x-codex-N (Codex warm lanes) are kept warm on purpose so the launcher can
      # hand them out instantly — exempt from GC even when clean+merged. Without the
      # x-codex-N arm, an idle clean+merged Codex lane was classified GC and
      # `git worktree remove`d out from under Codex (the lane-disappearance bug).
      # Normalize-Text lowercases and turns '/' into '\', so match the backslash form.
      $isPoolSlot = (Normalize-Text $currentWt) -match 'regen-root\.wt\\(claude|x-codex)-\d+'

      # Merged-into-develop check (only meaningful when clean + has a branch).
      $merged = $false
      if ($currentBranch -and $dirty -eq 0) {
        try {
          $mergedList = git -C $RepoRoot branch --merged develop --format '%(refname:short)' 2>$null
          if ($mergedList -and ($mergedList -contains $currentBranch)) { $merged = $true }
        } catch {}
      }

      $liveProcess = (Test-WorktreeLiveProcess $currentWt) -or (Test-WorktreeLeased $currentWt)
      $decision = Classify-Worktree $dirty $merged $liveProcess $isPoolSlot

      $action = 'skip'
      switch ($decision) {
        'PRESERVE' {
          # Dirty/aborted work — NEVER removed. Emit a RECOVER line so the
          # owning session can resume exactly where it left off.
          $action = if ($isWtSibling) { 'RECOVER-preserve' } else { 'DIRTY-warn' }
          $worktreesDirty++
          $worktreesRecover += [pscustomobject]@{
            Path = $currentWt
            Branch = if ($currentBranch) { $currentBranch } else { 'DETACHED' }
            DirtyFiles = $dirty
          }
        }
        'GC' {
          # Clean + merged → eligible to reclaim. Never -Force (clean by definition).
          if (-not $DryRun) {
            try {
              git -C $RepoRoot worktree remove $currentWt 2>$null
              $action = 'GC-removed'
              $worktreesPruned++
            } catch {
              $action = 'gc-failed'
            }
          } else {
            $action = 'would-GC'
          }
        }
        'KEEP' {
          # Clean-but-unmerged, a live owning process, or a warm pool slot. Leave it alone.
          $action = if ($liveProcess) { 'KEEP-live' } elseif ($isPoolSlot) { 'KEEP-pool' } else { 'KEEP-unmerged' }
        }
      }

      $worktreeReport += [pscustomobject]@{
        Path = $currentWt
        Branch = if ($currentBranch) { $currentBranch } else { 'DETACHED' }
        DirtyFiles = $dirty
        Merged = $merged
        Live = $liveProcess
        Action = $action
      }
      $currentWt = $null
    }
  }

  # `git worktree prune` only removes administrative entries for already-deleted
  # directories; it never touches a dirty/live worktree. Safe to run.
  if (-not $DryRun) {
    git -C $RepoRoot worktree prune 2>$null
  }

  # ── Branch GC: gone wt/*|cell/* branches with no live worktree → git branch -D
  try {
    $branchLines = git -C $RepoRoot branch -vv 2>$null
    foreach ($bl in $branchLines) {
      # Format: "  wt/foo  abc1234 [origin/wt/foo: gone] msg" (leading * for current)
      if ($bl -match '^\*?\s+(\S+)\s') {
        $bname = $Matches[1]
        if ($bname -notmatch '^(wt|cell)/') { continue }
        $goneOnRemote = ($bl -match '\[[^\]]*:\s*gone\]')
        $hasWorktree = $branchesWithWorktree.ContainsKey($bname)
        $delete = Select-BranchGc $bname $goneOnRemote $hasWorktree
        $baction = 'keep'
        if ($delete) {
          if (-not $DryRun) {
            try {
              git -C $RepoRoot branch -D $bname 2>$null
              $baction = 'deleted'
              $branchesDeleted++
            } catch {
              $baction = 'delete-failed'
            }
          } else {
            $baction = 'would-delete'
          }
        } elseif ($hasWorktree) {
          $baction = 'keep-live-worktree'
        }
        if ($delete -or $hasWorktree) {
          $branchReport += [pscustomobject]@{
            Branch = $bname
            GoneOnRemote = [bool]$goneOnRemote
            HasWorktree = [bool]$hasWorktree
            Action = $baction
          }
        }
      }
    }
  } catch {
    # Best-effort: branch GC must not block agent shutdown.
  }
} catch {
  # Best-effort: worktree GC must not block agent shutdown.
}

$report = [pscustomobject]@{
  generatedAt = (Get-Date).ToString('o')
  repoRoot = $RepoRoot
  dryRun = [bool]$DryRun
  cleanAgentBrowsers = [bool]$CleanAgentBrowsers
  cleanAgentDevServers = [bool]$CleanAgentDevServers
  reviewed = $reviewed
  stopped = $stopped
  worktrees = $worktreeReport
  worktreesRecover = $worktreesRecover
  branches = $branchReport
  worktreesPruned = $worktreesPruned
  worktreesDirty = $worktreesDirty
  branchesDeleted = $branchesDeleted
}

try {
  $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Get-StopReportPath) -Encoding UTF8
} catch {
  # Best-effort report write.
}

if ($HookOutput -in @('Codex', 'Claude')) {
  $parts = @()
  if ($stopped.Count -gt 0) {
    $parts += "cleaned $($stopped.Count) stale process(es)"
  }
  if ($worktreesPruned -gt 0) {
    $parts += "GC'd $worktreesPruned clean+merged worktree(s)"
  }
  if ($branchesDeleted -gt 0) {
    $parts += "deleted $branchesDeleted gone branch(es)"
  }
  if ($worktreesDirty -gt 0) {
    $parts += "RECOVER: $worktreesDirty dirty worktree(s) PRESERVED - resume to recover"
  }
  $message = if ($parts.Count -gt 0) {
    "cleanup-agent-jobs: " + ($parts -join '; ') + "."
  } else {
    "cleanup-agent-jobs: no stale processes or worktrees found."
  }
  [pscustomobject]@{
    continue = $true
    suppressOutput = $true
    systemMessage = $message
  } | ConvertTo-Json -Compress
} elseif ($DryRun -or $stopped.Count -gt 0 -or $worktreeReport.Count -gt 0 -or $branchReport.Count -gt 0) {
  if ($DryRun) { Write-Host "[WhatIf/DryRun] plan only - nothing deleted." }
  $stopped | Format-Table -AutoSize
  if ($worktreesRecover.Count -gt 0) {
    Write-Host "`nRECOVER (dirty/aborted worktrees PRESERVED - never auto-removed):"
    $worktreesRecover | Format-Table -AutoSize
  }
  if ($worktreeReport.Count -gt 0) {
    Write-Host "`nWorktree GC plan:"
    $worktreeReport | Format-Table -AutoSize
  }
  if ($branchReport.Count -gt 0) {
    Write-Host "`nBranch GC plan (wt/*|cell/* only):"
    $branchReport | Format-Table -AutoSize
  }
}
