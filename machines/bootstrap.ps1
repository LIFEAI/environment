# ================================================================
#  LIFEAI Dev Setup — Bootstrap Script
#  Provisions a fresh Windows machine into a fully configured
#  LIFEAI/regen-root development environment.
#
#  Usage:
#    powershell -ExecutionPolicy Bypass -File scripts/dev-setup/bootstrap.ps1
#
#  Idempotent — safe to re-run. Skips already-installed tools.
#  Does NOT start dev servers or modify node_modules directly.
# ================================================================

#Requires -Version 5.1

param(
  [string]$GitName,
  [string]$GitEmail,
  [string]$CloneDir = "C:\Dev\regen-root",
  [switch]$SkipClone,
  [switch]$SkipVSCode,
  [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"  # speeds up Invoke-WebRequest

# ── HELPERS ─────────────────────────────────────────────────────

function Write-Banner {
  param($m)
  Write-Host ""
  Write-Host "============================================================" -ForegroundColor Cyan
  Write-Host "  $m" -ForegroundColor Cyan
  Write-Host "============================================================" -ForegroundColor Cyan
  Write-Host ""
}

function Write-Step  { param($m) Write-Host "`n>>  $m" -ForegroundColor Cyan }
function Write-OK    { param($m) Write-Host "    [OK]  $m" -ForegroundColor Green }
function Write-Warn  { param($m) Write-Host "    [!!]  $m" -ForegroundColor Yellow }
function Write-Skip  { param($m) Write-Host "    [--]  $m" -ForegroundColor DarkGray }
function Write-Fail  { param($m) Write-Host "    [XX]  $m" -ForegroundColor Red }

function Test-CommandExists {
  param([string]$Name)
  $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Install-ViaWinget {
  param(
    [string]$PackageId,
    [string]$FriendlyName
  )
  if (-not (Test-CommandExists "winget")) {
    Write-Fail "winget not available — install $FriendlyName manually"
    return $false
  }
  Write-Host "    Installing $FriendlyName via winget ($PackageId)..." -ForegroundColor Yellow
  $result = winget install --id $PackageId --silent --accept-source-agreements --accept-package-agreements 2>&1
  if ($LASTEXITCODE -eq 0 -or $result -match "already installed") {
    Write-OK "$FriendlyName installed"
    return $true
  } else {
    # winget returns non-zero for "already installed" on some versions
    if ($result -match "already installed" -or $result -match "No available upgrade") {
      Write-OK "$FriendlyName already installed"
      return $true
    }
    Write-Warn "$FriendlyName install returned code $LASTEXITCODE — may need manual check"
    return $true
  }
}

function Refresh-Path {
  # Reload PATH from registry so newly installed tools are visible
  $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
  $userPath    = [System.Environment]::GetEnvironmentVariable("Path", "User")
  $env:Path    = "$machinePath;$userPath"
}

# ================================================================
#  PHASE A — INSTALL CORE TOOLS
# ================================================================

Write-Banner "LIFEAI Dev Setup — Phase A: Core Tools"

# ── A1: winget check ────────────────────────────────────────────

Write-Step "Checking winget availability"
if (Test-CommandExists "winget") {
  $wingetVer = (winget --version 2>$null)
  Write-OK "winget $wingetVer"
} else {
  Write-Fail "winget not found. Install App Installer from the Microsoft Store first."
  Write-Host "    https://apps.microsoft.com/detail/9nblggh4nns1" -ForegroundColor Yellow
  Write-Host "    Re-run this script after installing winget." -ForegroundColor Yellow
  exit 1
}

# ── A2: Git ─────────────────────────────────────────────────────

Write-Step "Git"
if (Test-CommandExists "git") {
  $gitVer = (git --version 2>$null)
  Write-OK "$gitVer"
} else {
  Install-ViaWinget "Git.Git" "Git"
  Refresh-Path
}

# ── A3: Node.js LTS ────────────────────────────────────────────

Write-Step "Node.js LTS"
if (Test-CommandExists "node") {
  $nodeVer = (node --version 2>$null)
  Write-OK "Node $nodeVer"
  # Check major version — warn if not 20.x
  $major = [int]($nodeVer -replace "^v(\d+)\..*", '$1')
  if ($major -lt 20) {
    Write-Warn "Node $major detected — LIFEAI requires Node 20 LTS (Coolify builds use NIXPACKS_NODE_VERSION=20)"
  }
} else {
  Install-ViaWinget "OpenJS.NodeJS.LTS" "Node.js LTS"
  Refresh-Path
}

# ── A4: pnpm ───────────────────────────────────────────────────

Write-Step "pnpm"
if (Test-CommandExists "pnpm") {
  $pnpmVer = (pnpm --version 2>$null)
  Write-OK "pnpm $pnpmVer"
} else {
  if (Test-CommandExists "npm") {
    Write-Host "    Installing pnpm via npm..." -ForegroundColor Yellow
    npm install -g pnpm 2>&1 | Out-Null
    Refresh-Path
    if (Test-CommandExists "pnpm") {
      Write-OK "pnpm installed"
    } else {
      Write-Warn "pnpm install completed but not in PATH — close and reopen terminal"
    }
  } else {
    Write-Fail "npm not available — install Node.js first, then re-run"
  }
}

# ── A5: Python 3.12 ────────────────────────────────────────────

Write-Step "Python 3.12"
if (Test-CommandExists "python") {
  $pyVer = (python --version 2>$null)
  Write-OK "$pyVer"
} elseif (Test-CommandExists "python3") {
  $pyVer = (python3 --version 2>$null)
  Write-OK "$pyVer"
} else {
  Install-ViaWinget "Python.Python.3.12" "Python 3.12"
  Refresh-Path
}

# ── A6: VS Code ────────────────────────────────────────────────

Write-Step "Visual Studio Code"
if ($SkipVSCode) {
  Write-Skip "Skipped (--SkipVSCode flag)"
} elseif (Test-CommandExists "code") {
  $codeVer = (code --version 2>$null | Select-Object -First 1)
  Write-OK "VS Code $codeVer"
} else {
  Install-ViaWinget "Microsoft.VisualStudioCode" "Visual Studio Code"
  Refresh-Path
}

# ── A7: Windows Terminal ────────────────────────────────────────

Write-Step "Windows Terminal"
$wtInstalled = Get-AppxPackage -Name "Microsoft.WindowsTerminal" -ErrorAction SilentlyContinue
if ($wtInstalled) {
  Write-OK "Windows Terminal $($wtInstalled.Version)"
} else {
  Install-ViaWinget "Microsoft.WindowsTerminal" "Windows Terminal"
}

# ── A8: GitHub CLI ──────────────────────────────────────────────

Write-Step "GitHub CLI (gh)"
if (Test-CommandExists "gh") {
  $ghVer = (gh --version 2>$null | Select-Object -First 1)
  Write-OK "$ghVer"
} else {
  Install-ViaWinget "GitHub.cli" "GitHub CLI"
  Refresh-Path
}

# ── A9: Claude Code CLI ────────────────────────────────────────

Write-Step "Claude Code CLI"
if (Test-CommandExists "claude") {
  $claudeVer = (claude --version 2>$null | Select-Object -First 1)
  Write-OK "Claude Code $claudeVer"
} else {
  if (Test-CommandExists "npm") {
    Write-Host "    Installing Claude Code via npm..." -ForegroundColor Yellow
    npm install -g @anthropic-ai/claude-code 2>&1 | Out-Null
    Refresh-Path
    if (Test-CommandExists "claude") {
      Write-OK "Claude Code installed"
    } else {
      Write-Warn "Claude Code install completed — close and reopen terminal if not in PATH"
    }
  } else {
    Write-Fail "npm not available — install Node.js first"
  }
}

# ── A10: clauth ─────────────────────────────────────────────────

Write-Step "clauth (LIFEAI credential vault)"
$clauthCmd = "$env:APPDATA\npm\clauth.cmd"
if (Test-Path $clauthCmd) {
  Write-OK "clauth found at $clauthCmd"
} elseif (Test-CommandExists "clauth") {
  Write-OK "clauth available in PATH"
} else {
  if (Test-CommandExists "npm") {
    Write-Host "    Installing clauth via npm..." -ForegroundColor Yellow
    npm install -g @lifeaitools/clauth 2>&1 | Out-Null
    Refresh-Path
    Write-OK "clauth installed (configure with clauth init after setup)"
  } else {
    Write-Warn "npm not available — install clauth manually: npm install -g @lifeaitools/clauth"
  }
}


# ================================================================
#  PHASE B — CONFIGURE GIT
# ================================================================

Write-Banner "LIFEAI Dev Setup — Phase B: Git Configuration"

# ── B1: Git user identity ───────────────────────────────────────

Write-Step "Git user identity"

$currentName  = git config --global user.name 2>$null
$currentEmail = git config --global user.email 2>$null

if ($currentName -and $currentEmail) {
  Write-OK "Already configured: $currentName <$currentEmail>"
} else {
  # Use params, env vars, or prompt
  if (-not $GitName) {
    $GitName = $env:LIFEAI_GIT_NAME
    if (-not $GitName) {
      $GitName = Read-Host "    Enter your full name for git commits"
    }
  }
  if (-not $GitEmail) {
    $GitEmail = $env:LIFEAI_GIT_EMAIL
    if (-not $GitEmail) {
      $GitEmail = Read-Host "    Enter your email for git commits"
    }
  }

  if ($GitName) {
    git config --global user.name "$GitName"
    Write-OK "Set git user.name = $GitName"
  }
  if ($GitEmail) {
    git config --global user.email "$GitEmail"
    Write-OK "Set git user.email = $GitEmail"
  }
}

# ── B2: SSH key ─────────────────────────────────────────────────

Write-Step "SSH key for GitHub"

$sshKeyPath = "$env:USERPROFILE\.ssh\id_ed25519"
if (Test-Path $sshKeyPath) {
  Write-OK "SSH key exists: $sshKeyPath"
} else {
  Write-Host "    Generating Ed25519 SSH key..." -ForegroundColor Yellow
  $sshEmail = (git config --global user.email 2>$null)
  if (-not $sshEmail) { $sshEmail = "dev@lifeai.tools" }

  $sshDir = "$env:USERPROFILE\.ssh"
  if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
  }

  ssh-keygen -t ed25519 -C "$sshEmail" -f "$sshKeyPath" -N '""' 2>&1 | Out-Null

  if (Test-Path $sshKeyPath) {
    Write-OK "SSH key generated: $sshKeyPath"
  } else {
    Write-Warn "SSH key generation may have failed — check $sshDir"
  }
}

# Start ssh-agent and add key
Write-Step "SSH agent"
try {
  $agentService = Get-Service ssh-agent -ErrorAction SilentlyContinue
  if ($agentService) {
    if ($agentService.Status -ne "Running") {
      if ($agentService.StartType -eq "Disabled") {
        Write-Warn "ssh-agent service is disabled. Enable it:"
        Write-Host "    Set-Service ssh-agent -StartupType Manual" -ForegroundColor Yellow
        Write-Host "    Start-Service ssh-agent" -ForegroundColor Yellow
      } else {
        Start-Service ssh-agent -ErrorAction SilentlyContinue
        Write-OK "ssh-agent started"
      }
    } else {
      Write-OK "ssh-agent already running"
    }
    # Add key if agent is running
    if ((Get-Service ssh-agent -ErrorAction SilentlyContinue).Status -eq "Running") {
      ssh-add $sshKeyPath 2>&1 | Out-Null
      Write-OK "SSH key added to agent"
    }
  } else {
    Write-Warn "ssh-agent service not found — OpenSSH may not be installed"
  }
} catch {
  Write-Warn "Could not configure ssh-agent: $($_.Exception.Message)"
}

# Show public key for GitHub
if (Test-Path "$sshKeyPath.pub") {
  Write-Host ""
  Write-Host "    ---- PUBLIC KEY (add to GitHub at https://github.com/settings/keys) ----" -ForegroundColor Yellow
  Get-Content "$sshKeyPath.pub" | Write-Host -ForegroundColor White
  Write-Host "    -----------------------------------------------------------------------" -ForegroundColor Yellow
  Write-Host ""
}

# ── B3: GitHub CLI auth ─────────────────────────────────────────

Write-Step "GitHub CLI authentication"
if (Test-CommandExists "gh") {
  $ghAuth = gh auth status 2>&1
  if ($ghAuth -match "Logged in") {
    Write-OK "gh CLI authenticated"
  } else {
    Write-Warn "gh CLI not authenticated. Run interactively after setup:"
    Write-Host "    gh auth login -h github.com -p ssh -w" -ForegroundColor Yellow
  }
} else {
  Write-Skip "gh not installed — skipping auth check"
}

# ── B4: Useful git config ──────────────────────────────────────

Write-Step "Git defaults"
git config --global init.defaultBranch main 2>$null
git config --global pull.rebase true 2>$null
git config --global core.autocrlf true 2>$null
git config --global core.longpaths true 2>$null
Write-OK "defaultBranch=main, pull.rebase=true, autocrlf=true, longpaths=true"


# ================================================================
#  PHASE C — CLONE & INSTALL
# ================================================================

Write-Banner "LIFEAI Dev Setup — Phase C: Clone & Install"

# ── C1: Clone repo ──────────────────────────────────────────────

Write-Step "Clone LIFEAI/regen-root"

if ($SkipClone) {
  Write-Skip "Skipped (--SkipClone flag)"
} elseif (Test-Path "$CloneDir\.git") {
  Write-OK "Repo already cloned at $CloneDir"
  # Fetch latest
  Write-Host "    Fetching latest from origin..." -ForegroundColor Yellow
  Push-Location $CloneDir
  git fetch origin 2>&1 | Out-Null
  Pop-Location
  Write-OK "Fetched origin"
} else {
  # Ensure parent directory exists
  $parentDir = Split-Path $CloneDir
  if (-not (Test-Path $parentDir)) {
    New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
    Write-OK "Created $parentDir"
  }

  Write-Host "    Cloning via SSH..." -ForegroundColor Yellow
  $cloneResult = git clone git@github.com:LIFEAI/regen-root.git "$CloneDir" 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Warn "SSH clone failed — trying HTTPS..."
    $cloneResult = git clone https://github.com/LIFEAI/regen-root.git "$CloneDir" 2>&1
    if ($LASTEXITCODE -ne 0) {
      Write-Fail "Clone failed. Ensure you have access to LIFEAI/regen-root."
      Write-Host "    $cloneResult" -ForegroundColor Red
      exit 1
    }
  }
  Write-OK "Cloned to $CloneDir"
}

# ── C2: pnpm install ───────────────────────────────────────────

Write-Step "pnpm install"

if (-not (Test-Path $CloneDir)) {
  Write-Fail "Repo not found at $CloneDir — cannot install dependencies"
} else {
  Push-Location $CloneDir
  if (Test-CommandExists "pnpm") {
    Write-Host "    Running pnpm install (this may take a few minutes)..." -ForegroundColor Yellow
    pnpm install 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -eq 0) {
      Write-OK "Dependencies installed"
    } else {
      Write-Warn "pnpm install exited with code $LASTEXITCODE — check output above"
    }
  } else {
    Write-Fail "pnpm not in PATH — close and reopen terminal, then run: cd $CloneDir && pnpm install"
  }
  Pop-Location
}

# ── C3: Verify turbo ───────────────────────────────────────────

Write-Step "Verify turbo"
if (Test-Path "$CloneDir\node_modules\.bin\turbo.cmd") {
  Write-OK "turbo available via node_modules/.bin"
} elseif (Test-CommandExists "turbo") {
  Write-OK "turbo available globally"
} else {
  Write-Warn "turbo not found — it should be installed via pnpm install (devDependency in root package.json)"
}


# ================================================================
#  PHASE D — ENVIRONMENT FILES
# ================================================================

Write-Banner "LIFEAI Dev Setup — Phase D: Environment Files"

Write-Step "Creating .env.local templates for apps"

$supabaseUrl    = "https://uvojezuorjgqzmhhgluu.supabase.co"
$envPlaceholder = @"
# ── LIFEAI Dev Setup — Generated Template ──
# Fill in real values from clauth daemon: curl -s http://127.0.0.1:52437/get/<service>
# Or ask a team member for the shared dev credentials.
#
# NEVER commit this file. It is in .gitignore.

NEXT_PUBLIC_SUPABASE_URL=$supabaseUrl
NEXT_PUBLIC_SUPABASE_ANON_KEY=REPLACE_WITH_ANON_KEY
"@

$envWithServiceRole = @"
# ── LIFEAI Dev Setup — Generated Template ──
# Fill in real values from clauth daemon: curl -s http://127.0.0.1:52437/get/<service>
# Or ask a team member for the shared dev credentials.
#
# NEVER commit this file. It is in .gitignore.

NEXT_PUBLIC_SUPABASE_URL=$supabaseUrl
NEXT_PUBLIC_SUPABASE_ANON_KEY=REPLACE_WITH_ANON_KEY
SUPABASE_SERVICE_ROLE_KEY=REPLACE_WITH_SERVICE_ROLE_KEY
"@

$envMarketing = @"
# ── LIFEAI Dev Setup — Generated Template ──
# Fill in real values from clauth daemon: curl -s http://127.0.0.1:52437/get/<service>
# Or ask a team member for the shared dev credentials.
#
# NEVER commit this file. It is in .gitignore.

# Supabase
NEXT_PUBLIC_SUPABASE_URL=$supabaseUrl
NEXT_PUBLIC_SUPABASE_ANON_KEY=REPLACE_WITH_ANON_KEY
SUPABASE_SERVICE_ROLE_KEY=REPLACE_WITH_SERVICE_ROLE_KEY

# Claude API (for AI content generation)
ANTHROPIC_API_KEY=REPLACE_WITH_ANTHROPIC_KEY
"@

# Apps that need .env.local with standard Supabase vars
$standardApps = @("prt", "rdc", "lifeai", "place-fund", "regenity", "future-city", "rccs-admin", "daf-intelligence")
# Apps that also need service role key
$serviceRoleApps = @("rdc-marketing-engine")

foreach ($app in $standardApps) {
  $envPath = "$CloneDir\apps\$app\.env.local"
  if (Test-Path $envPath) {
    Write-Skip "apps/$app/.env.local already exists"
  } else {
    $envPlaceholder | Out-File -FilePath $envPath -Encoding utf8NoBOM -Force
    Write-OK "Created apps/$app/.env.local (template)"
  }
}

foreach ($app in $serviceRoleApps) {
  $envPath = "$CloneDir\apps\$app\.env.local"
  if (Test-Path $envPath) {
    Write-Skip "apps/$app/.env.local already exists"
  } else {
    $envMarketing | Out-File -FilePath $envPath -Encoding utf8NoBOM -Force
    Write-OK "Created apps/$app/.env.local (template with service role + Anthropic)"
  }
}


# ================================================================
#  PHASE E — VERIFY
# ================================================================

Write-Banner "LIFEAI Dev Setup — Phase E: Verification"

# ── E1: Build check ────────────────────────────────────────────

Write-Step "Build verification"
if ($SkipBuild) {
  Write-Skip "Skipped (--SkipBuild flag)"
} elseif (-not (Test-Path $CloneDir)) {
  Write-Skip "Repo not found — skipping build"
} else {
  Push-Location $CloneDir
  if (Test-CommandExists "pnpm") {
    Write-Host "    Running pnpm build (this may take several minutes)..." -ForegroundColor Yellow
    $buildOutput = pnpm build 2>&1
    if ($LASTEXITCODE -eq 0) {
      Write-OK "pnpm build succeeded"
    } else {
      Write-Warn "pnpm build exited with code $LASTEXITCODE"
      Write-Host "    This is common on first setup if .env.local values are still placeholders." -ForegroundColor Yellow
      Write-Host "    Fill in real Supabase keys and re-run: cd $CloneDir && pnpm build" -ForegroundColor Yellow
    }
  } else {
    Write-Skip "pnpm not in PATH — skipping build"
  }
  Pop-Location
}

# ── E1b: Windows Defender exclusion for clauth SSH keys ────────

Write-Step "Windows Defender exclusion (clauth SSH temp keys)"
$sshExclPath = Join-Path $env:TEMP "regen-clauth-ssh"
try {
  Add-MpExclusion -Path $sshExclPath -ErrorAction Stop
  Write-OK "Defender exclusion added: $sshExclPath"
} catch {
  Write-Warn "Could not add Defender exclusion (needs admin). Run manually:"
  Write-Host "    Add-MpExclusion -Path `"$sshExclPath`"" -ForegroundColor Yellow
}

# ── E2: Git status ──────────────────────────────────────────────

Write-Step "Git status"
if (Test-Path "$CloneDir\.git") {
  Push-Location $CloneDir
  $branch = git rev-parse --abbrev-ref HEAD 2>$null
  $status = git status --porcelain 2>$null
  Write-OK "Branch: $branch"
  if ($status) {
    $changeCount = ($status | Measure-Object).Count
    Write-OK "Working tree: $changeCount changes (expected — .env.local files)"
  } else {
    Write-OK "Working tree: clean"
  }
  Pop-Location
} else {
  Write-Skip "No git repo at $CloneDir"
}

# ── E3: Summary ─────────────────────────────────────────────────

Write-Banner "LIFEAI Dev Setup — Summary"

$tools = @(
  @{ Name = "git";     Cmd = "git" },
  @{ Name = "node";    Cmd = "node" },
  @{ Name = "pnpm";    Cmd = "pnpm" },
  @{ Name = "python";  Cmd = "python" },
  @{ Name = "code";    Cmd = "code" },
  @{ Name = "gh";      Cmd = "gh" },
  @{ Name = "claude";  Cmd = "claude" },
  @{ Name = "clauth";  Cmd = "clauth" }
)

Write-Host "  Tool Status:" -ForegroundColor White
Write-Host "  ──────────────────────────────────────" -ForegroundColor DarkGray

foreach ($t in $tools) {
  if (Test-CommandExists $t.Cmd) {
    $ver = & $t.Cmd --version 2>$null | Select-Object -First 1
    Write-Host "    $($t.Name.PadRight(10))  OK   $ver" -ForegroundColor Green
  } else {
    Write-Host "    $($t.Name.PadRight(10))  --   not found" -ForegroundColor Yellow
  }
}

Write-Host ""
Write-Host "  Repo: $CloneDir" -ForegroundColor White
Write-Host ""
Write-Host "  ──────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  NEXT STEPS:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  1. Add SSH key to GitHub:" -ForegroundColor White
Write-Host "       https://github.com/settings/keys" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  2. Authenticate gh CLI:" -ForegroundColor White
Write-Host "       gh auth login -h github.com -p ssh -w" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  3. Fill in .env.local files with real Supabase keys:" -ForegroundColor White
Write-Host "       curl -s http://127.0.0.1:52437/get/supabase" -ForegroundColor DarkGray
Write-Host "       (requires clauth daemon running and unlocked)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  4. Install VS Code extensions + Windows Terminal profiles:" -ForegroundColor White
Write-Host "       powershell -File $CloneDir\scripts\install-env.ps1" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  5. Configure clauth:" -ForegroundColor White
Write-Host "       clauth init" -ForegroundColor DarkGray
Write-Host "       $CloneDir\scripts\restart-clauth.bat" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  6. Start developing:" -ForegroundColor White
Write-Host "       cd $CloneDir" -ForegroundColor DarkGray
Write-Host "       pnpm dev  (all apps)" -ForegroundColor DarkGray
Write-Host "       pnpm --filter @regen/prt-portal dev  (single app)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  7. Cell-based terminal (after install-env.ps1):" -ForegroundColor White
Write-Host "       Ctrl+Alt+1  SV (Supervisor)" -ForegroundColor DarkGray
Write-Host "       Ctrl+Alt+2  Portal" -ForegroundColor DarkGray
Write-Host "       Ctrl+Alt+3  Data" -ForegroundColor DarkGray
Write-Host "       Ctrl+Alt+4  CS2" -ForegroundColor DarkGray
Write-Host "       Ctrl+Alt+5  Mktg" -ForegroundColor DarkGray
Write-Host "       Ctrl+Alt+6  Infra" -ForegroundColor DarkGray
Write-Host "       Ctrl+Alt+7  Specialist" -ForegroundColor DarkGray
Write-Host ""
Write-Host ">> Patching startup environment (env-sync --fix: MCP registry, desktop shortcuts, clauth autostart, codeflow)" -ForegroundColor Cyan
if (Test-Path "$CloneDir\scripts\env-sync.mjs") {
  Push-Location $CloneDir
  try {
    node "scripts\env-sync.mjs" --fix
  } catch {
    Write-Host "   WARN: env-sync --fix errored -- re-run 'pnpm env:patch' after clauth is unlocked" -ForegroundColor Yellow
  } finally {
    Pop-Location
  }
} else {
  Write-Host "   SKIP: env-sync.mjs not found (clone incomplete) -- run 'pnpm env:patch' after clone" -ForegroundColor Yellow
}
Write-Host ""

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Setup complete." -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
