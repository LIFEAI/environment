# ================================================================
#  LIFEAI CELL-BASED DEV ENVIRONMENT — INSTALLER
#  Run: powershell -ExecutionPolicy Bypass -File scripts/install-env.ps1
#
#  Simple: backs up existing files, copies source files. No merge.
#  Source of truth: scripts/env/
# ================================================================

$ErrorActionPreference = "Stop"
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot   = Split-Path -Parent $ScriptDir
$SourceDir  = "$ScriptDir\env"

$VscodeDir      = "$RepoRoot\.vscode"
$WTSettingsPath = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
$VSCodeUserDir  = "$env:APPDATA\Code\User"

# ── HELPERS ───────────────────────────────────────────────────

function Write-Step { param($m) Write-Host "`n>  $m" -ForegroundColor Cyan }
function Write-OK   { param($m) Write-Host "   OK  $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "   !!  $m" -ForegroundColor Yellow }
function Write-Skip { param($m) Write-Host "   --  $m" -ForegroundColor DarkGray }

function Install-File {
  param(
    [string]$Source,
    [string]$Dest,
    [string]$Label
  )
  Write-Step $Label

  if (-not (Test-Path $Source)) {
    Write-Warn "Source not found: $Source — skipping."
    return
  }

  # Create destination directory
  $dir = Split-Path $Dest
  if ($dir -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }

  # Backup existing
  if (Test-Path $Dest) {
    $stamp  = Get-Date -Format "yyyyMMdd-HHmmss"
    $backup = "$Dest.bak-$stamp"
    Copy-Item $Dest $backup
    Write-Warn "Backed up -> $backup"
  }

  # Copy source to destination
  Copy-Item $Source $Dest -Force
  Write-OK "$Dest"
}

# ── VERIFY ────────────────────────────────────────────────────

Write-Step "Verifying paths"
if (-not (Test-Path $RepoRoot)) {
  Write-Host "   X  Repo root not found: $RepoRoot" -ForegroundColor Red; exit 1
}
if (-not (Test-Path $SourceDir)) {
  Write-Host "   X  Source dir not found: $SourceDir" -ForegroundColor Red; exit 1
}
Write-OK "Repo: $RepoRoot"
Write-OK "Source: $SourceDir"

# ── CREATE DIRECTORIES ────────────────────────────────────────

Write-Step "Creating directories"
@("$VscodeDir", "$RepoRoot\.cell-state") | ForEach-Object {
  if (-not (Test-Path $_)) { New-Item -ItemType Directory -Force -Path $_ | Out-Null; Write-OK "Created $_" }
  else { Write-Skip "$_ exists" }
}

# ── VS CODE WORKSPACE FILES ──────────────────────────────────

Install-File "$SourceDir\vscode\settings.json"    "$VscodeDir\settings.json"    ".vscode/settings.json"
Install-File "$SourceDir\vscode\extensions.json"   "$VscodeDir\extensions.json"  ".vscode/extensions.json"
Install-File "$SourceDir\vscode\launch.json"       "$VscodeDir\launch.json"      ".vscode/launch.json"
Install-File "$SourceDir\vscode\tasks.json"        "$VscodeDir\tasks.json"       ".vscode/tasks.json"

# ── VS CODE USER KEYBINDINGS ─────────────────────────────────

Install-File "$SourceDir\vscode\keybindings.json"  "$VSCodeUserDir\keybindings.json"  "VS Code keybindings (user-level)"

# ── WINDOWS TERMINAL ─────────────────────────────────────────

$wtDir = Split-Path $WTSettingsPath
if (Test-Path $wtDir) {
  Install-File "$SourceDir\windows-terminal\settings.json"  $WTSettingsPath  "Windows Terminal settings"
} else {
  Write-Step "Windows Terminal"
  Write-Warn "Not installed — skipping."
}

# ── WEZTERM ───────────────────────────────────────────────────

Install-File "$SourceDir\wezterm\wezterm.lua"  "$env:USERPROFILE\.wezterm.lua"  "WezTerm config (~/.wezterm.lua)"

# ── POWERSHELL PROFILE ────────────────────────────────────────

$psProfileDir = "$env:USERPROFILE\Documents\PowerShell"
if (-not (Test-Path $psProfileDir)) { New-Item -ItemType Directory -Force -Path $psProfileDir | Out-Null }
Install-File "$SourceDir\powershell\Microsoft.PowerShell_profile.ps1"  "$psProfileDir\Microsoft.PowerShell_profile.ps1"  "PowerShell 7 profile (claude iso wrapper)"

# ── CODEX CONFIG ──────────────────────────────────────────────

$codexDir = "$RepoRoot\.codex"
if (-not (Test-Path $codexDir)) { New-Item -ItemType Directory -Force -Path $codexDir | Out-Null }
Install-File "$SourceDir\codex\config.toml"  "$codexDir\config.toml"  "Codex config (.codex/config.toml)"

# ── ENSURE .CMD/.BAT HAVE CRLF ───────────────────────────────

Write-Step "Fixing line endings on batch files"
Get-ChildItem "$RepoRoot\scripts\*.cmd","$RepoRoot\scripts\*.bat" -ErrorAction SilentlyContinue | ForEach-Object {
  $content = [System.IO.File]::ReadAllText($_.FullName)
  $fixed = ($content -replace "`r`n", "`n") -replace "`n", "`r`n"
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($_.FullName, $fixed, $utf8NoBom)
  Write-OK "$($_.Name) -> CRLF"
}

# ── CHECK TOOLS ───────────────────────────────────────────────

Write-Step "Checking required tools"
$tools = @(
  @{ Name="node";   Winget="OpenJS.NodeJS.LTS" },
  @{ Name="pnpm";   Winget="pnpm.pnpm" },
  @{ Name="git";    Winget="Git.Git" },
  @{ Name="code";   Winget="Microsoft.VisualStudioCode" },
  @{ Name="claude"; Winget=$null }
)
foreach ($t in $tools) {
  if (Get-Command $t.Name -ErrorAction SilentlyContinue) {
    Write-OK "$($t.Name)"
  } else {
    if ($t.Winget -and (Get-Command winget -ErrorAction SilentlyContinue)) {
      Write-Warn "$($t.Name) missing -> installing..."
      winget install --id $t.Winget --silent --accept-source-agreements --accept-package-agreements
    } elseif ($t.Name -eq "claude") {
      Write-Warn "claude not found -> npm install -g @anthropic-ai/claude-code"
    } else {
      Write-Warn "$($t.Name) not found -> install manually"
    }
  }
}

# ── INSTALL VS CODE EXTENSIONS ────────────────────────────────

Write-Step "Installing VS Code extensions"
$exts = @(
  "zhuangtongfa.material-theme","pkief.material-icon-theme",
  "dbaeumer.vscode-eslint","esbenp.prettier-vscode",
  "ms-vscode.vscode-typescript-next","bradlc.vscode-tailwindcss",
  "csstools.postcss","formulahendry.auto-rename-tag",
  "eamodio.gitlens","mhutchie.git-graph",
  "mtxr.sqltools","mtxr.sqltools-driver-pg","supabase.supabase",
  "mikestead.dotenv","anthropic.claude-code",
  "gruntfuggly.todo-tree","christian-kohler.path-intellisense",
  "editorconfig.editorconfig"
)
if (Get-Command code -ErrorAction SilentlyContinue) {
  foreach ($ext in $exts) {
    Write-Host "   $ext..." -NoNewline
    code --install-extension $ext --force 2>&1 | Out-Null
    Write-Host " OK" -ForegroundColor Green
  }
} else {
  Write-Warn "VS Code not in PATH -> extensions skipped."
}

# ── CLAUTH STARTUP TASK ───────────────────────────────────────

Write-Step "Registering clauth daemon as startup task"
$clauthCmd = "$env:APPDATA\npm\clauth.cmd"
if (Test-Path $clauthCmd) {
  try {
    $action   = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"$clauthCmd`" serve start"
    $trigger  = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName "clauth-daemon" -Action $action -Trigger $trigger -Settings $settings -RunLevel Limited -Force | Out-Null
    Write-OK "clauth-daemon task registered (runs at logon)"
    Start-ScheduledTask -TaskName "clauth-daemon"
    Start-Sleep -Seconds 5
    try { $ping = Invoke-RestMethod -Uri "http://127.0.0.1:52437/ping" -TimeoutSec 5; Write-OK "Daemon running: $ping" }
    catch { Write-Warn "Daemon not responding yet — will start on next logon" }
  } catch {
    Write-Warn "Could not register task (needs admin). Run install-env.ps1 as Administrator."
  }
} else {
  Write-Warn "clauth not found at $clauthCmd — skipping startup task. Run: npm install -g clauth"
}

# ── DONE ──────────────────────────────────────────────────────

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  Done. Source files installed, originals backed up." -ForegroundColor Green
Write-Host ""
Write-Host "  Cell profiles (Ctrl+Alt+N in Windows Terminal):" -ForegroundColor Yellow
Write-Host "    1  SV (Supervisor)    5  Mktg (Marketing)"
Write-Host "    2  Portal             6  Infra"
Write-Host "    3  Data               7  Specialist"
Write-Host "    4  CS2"
Write-Host ""
Write-Host "  Next:" -ForegroundColor Yellow
Write-Host "    1. Close and reopen Windows Terminal"
Write-Host "    2. SV tab opens automatically with Claude Code"
Write-Host "========================================================" -ForegroundColor Cyan
