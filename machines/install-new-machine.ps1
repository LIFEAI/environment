# Re-launch in pwsh elevated if needed
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "Relaunching in PowerShell 7..." -ForegroundColor Yellow
    Start-Process pwsh -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Relaunching elevated..." -ForegroundColor Yellow
    Start-Process pwsh -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

# install-new-machine.ps1 -- Pre-restore setup for a LIFEAI dev workstation
# Run in ELEVATED PowerShell BEFORE restoring E:\DevMigration\Dev and Profile.
# Source: CARBON7 inventory snapshot 2026-06-09.

$ErrorActionPreference = 'Continue'

function Write-Step($msg) { Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "   OK: $msg" -ForegroundColor Green }
function Write-Skip($msg) { Write-Host "   SKIP: $msg" -ForegroundColor Yellow }

function Ensure-SystemPath($dir) {
    $machPath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $entries = $machPath -split ';' | Where-Object { $_ }
    if ($entries -notcontains $dir) {
        [System.Environment]::SetEnvironmentVariable("Path", ($machPath.TrimEnd(';') + ";$dir"), "Machine")
        Write-OK "Added to System PATH: $dir"
    }
}

function Remove-UserPath($dir) {
    $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $userPath) { return }
    $entries = $userPath -split ';' | Where-Object { $_ -and $_ -ne $dir }
    [System.Environment]::SetEnvironmentVariable("Path", ($entries -join ';'), "User")
}

# ─────────────────────────────────────────────────────
# LIVE-MACHINE GUARD
# This is a FRESH-MACHINE provisioning script (see header). Running it on a
# working box has force-closed every live terminal session at once: its winget/
# MSIX PowerShell reinstall triggers Windows Installer Restart Manager, which
# shuts down every process using the package — all open pwsh panes died mid-work.
# Refuse to run when the machine is already provisioned or has live agent
# sessions, unless the operator explicitly opts in.
# ─────────────────────────────────────────────────────
if ($env:PROVISION_FRESH_MACHINE -ne '1') {
    $looksProvisioned = Test-Path 'C:\Dev\regen-root'
    $liveAgents = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'claude|codex|cell-init|clauth|pm2|wezterm' }).Count
    if ($looksProvisioned -or $liveAgents -gt 0) {
        Write-Host ""
        Write-Host "REFUSING TO RUN -- this is a FRESH-MACHINE provisioning script." -ForegroundColor Red
        Write-Host "  C:\Dev\regen-root exists : $looksProvisioned" -ForegroundColor Yellow
        Write-Host "  live agent/pwsh sessions : $liveAgents" -ForegroundColor Yellow
        Write-Host "  Its winget/MSIX PowerShell reinstall can force-close every open" -ForegroundColor Yellow
        Write-Host "  terminal via Restart Manager. If you REALLY mean to run this on an" -ForegroundColor Yellow
        Write-Host "  already-live machine, set  `$env:PROVISION_FRESH_MACHINE = '1'  and re-run." -ForegroundColor Yellow
        exit 1
    }
}

# ─────────────────────────────────────────────────────
# 1. Package manager: Chocolatey
# ─────────────────────────────────────────────────────
Write-Step "Chocolatey"
if (Get-Command choco -ErrorAction SilentlyContinue) {
    Write-Skip "already installed ($(choco --version))"
} else {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    Write-OK "Chocolatey installed"
}

# ─────────────────────────────────────────────────────
# 2. Core runtimes via choco
# ─────────────────────────────────────────────────────
Write-Step "Core runtimes (Node 22, Python 3.12, Git)"

$chocoPackages = @(
    @{ name='nodejs-lts';    version='22.14.0';  check='node --version' }
    @{ name='python312';     version='';          check='python --version' }
    @{ name='git';           version='';          check='git --version' }
    @{ name='ripgrep';       version='';          check='rg --version' }
    @{ name='fzf';           version='';          check='fzf --version' }
    @{ name='unzip';         version='';          check='unzip -v' }
    @{ name='dotnetfx';      version='';          check='' }
)

foreach ($pkg in $chocoPackages) {
    $installed = choco list --exact $pkg.name 2>$null | Select-String $pkg.name
    if ($installed) {
        Write-Skip "$($pkg.name) already installed"
    } else {
        $cmd = "choco install $($pkg.name) -y --no-progress"
        if ($pkg.version) { $cmd += " --version=$($pkg.version)" }
        Invoke-Expression $cmd
        Write-OK "$($pkg.name)"
    }
}

# Refresh session PATH from Machine only
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine")

# python3 symlink (Windows ships a Store redirector stub that breaks scripts)
Write-Step "python3 symlink"
if (Test-Path "C:\Python312\python.exe") {
    if (-not (Test-Path "C:\Python312\python3.exe")) {
        New-Item -ItemType SymbolicLink -Path "C:\Python312\python3.exe" -Target "C:\Python312\python.exe" -Force | Out-Null
        Write-OK "Created python3.exe symlink in C:\Python312"
    } else {
        Write-Skip "python3.exe already exists"
    }
} else {
    Write-Host "   WARN: C:\Python312\python.exe not found -- create symlink manually" -ForegroundColor Yellow
}

# ─────────────────────────────────────────────────────
# 3. WSL2 + Docker Desktop (WSL backend, no Hyper-V)
# ─────────────────────────────────────────────────────
Write-Step "WSL2"
$wslInstalled = wsl --status 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Skip "WSL already enabled"
} else {
    wsl --install --no-distribution 2>$null
    Write-OK "WSL2 enabled (reboot required before Docker works)"
}

Write-Step "Docker Desktop (WSL2 backend, no Hyper-V)"
if (Get-Command docker -ErrorAction SilentlyContinue) {
    Write-Skip "already installed ($(docker --version))"
} else {
    choco install docker-desktop -y --no-progress --params="'/WSL2'"
    Write-OK "Docker Desktop -- reboot required"
}

# ─────────────────────────────────────────────────────
# 4. WezTerm
# ─────────────────────────────────────────────────────
Write-Step "WezTerm"
if (Get-Command wezterm -ErrorAction SilentlyContinue) {
    Write-Skip "already installed"
} else {
    choco install wezterm -y --no-progress
    Write-OK "WezTerm"
}

# ─────────────────────────────────────────────────────
# 5. VS Code
# ─────────────────────────────────────────────────────
Write-Step "VS Code"
if (Get-Command code -ErrorAction SilentlyContinue) {
    Write-Skip "already installed ($(code --version 2>$null | Select-Object -First 1))"
} else {
    choco install vscode -y --no-progress
    Write-OK "VS Code"
}

# ─────────────────────────────────────────────────────
# 6. GitHub CLI
# ─────────────────────────────────────────────────────
Write-Step "GitHub CLI"
if (Get-Command gh -ErrorAction SilentlyContinue) {
    Write-Skip "already installed ($(gh --version 2>$null | Select-Object -First 1))"
} else {
    choco install gh -y --no-progress
    Write-OK "GitHub CLI"
}

# ─────────────────────────────────────────────────────
# 7. Cloudflared (tunnel client)
# ─────────────────────────────────────────────────────
Write-Step "Cloudflared"
if (Get-Command cloudflared -ErrorAction SilentlyContinue) {
    Write-Skip "already installed ($(cloudflared --version 2>$null))"
} else {
    choco install cloudflared -y --no-progress
    Write-OK "Cloudflared"
}

# ─────────────────────────────────────────────────────
# 8. Visual Studio Build Tools (native modules)
# ─────────────────────────────────────────────────────
Write-Step "Visual Studio 2019 Build Tools (for native node modules)"
$vsInstalled = choco list --exact visualstudio2019buildtools 2>$null | Select-String 'visualstudio2019buildtools'
if ($vsInstalled) {
    Write-Skip "already installed"
} else {
    choco install visualstudio2019buildtools -y --no-progress
    Write-OK "VS Build Tools"
}

# Refresh session PATH from Machine only
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine")

# ─────────────────────────────────────────────────────
# 9. PowerShell 7
# ─────────────────────────────────────────────────────
Write-Step "PowerShell 7"
if (Test-Path 'C:\Program Files\PowerShell\7\pwsh.exe') {
    Write-Skip "already installed (MSI, stable path)"
} else {
    # Install the MSI to the stable C:\Program Files\PowerShell\7 path -- NOT the
    # winget/Store MSIX build, whose version-stamped WindowsApps dir is renamed on
    # every Store auto-update, breaking any resolved path to pwsh (this is what took
    # down clauth fs_exec). MSIRESTARTMANAGERCONTROL=Disable stops the installer from
    # force-closing running sessions; ENABLE_MU=0 keeps Microsoft Update from
    # shuffling it back to a versioned dir.
    $ps7Msi = Join-Path $env:TEMP 'PowerShell-7-win-x64.msi'
    try {
        $rel   = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -Headers @{ 'User-Agent' = 'lifeai-setup' }
        $asset = $rel.assets | Where-Object { $_.name -match 'win-x64\.msi$' } | Select-Object -First 1
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $ps7Msi -UseBasicParsing
        Start-Process msiexec.exe -Wait -ArgumentList @('/i',"`"$ps7Msi`"",'/qn','/norestart','ADD_PATH=1','ENABLE_MU=0','DISABLE_TELEMETRY=1','MSIRESTARTMANAGERCONTROL=Disable')
        Write-OK "PowerShell 7 (MSI, stable path)"
    } catch {
        Write-Host "   WARN: MSI install failed ($($_.Exception.Message)); falling back to choco powershell-core" -ForegroundColor Yellow
        choco install powershell-core -y --no-progress
    }
}

# ─────────────────────────────────────────────────────
# 10. Desktop and dev tools via winget
# ─────────────────────────────────────────────────────
Write-Step "Desktop and dev tools (winget)"

$wingetPackages = @(
    @{ id='7zip.7zip';                  name='7-Zip' }
    @{ id='JohnMacFarlane.Pandoc';      name='Pandoc' }
    @{ id='Notepad++.Notepad++';        name='Notepad++' }
    @{ id='Obsidian.Obsidian';          name='Obsidian' }
    @{ id='JGraph.Draw';                name='draw.io' }
    @{ id='Audacity.Audacity';          name='Audacity' }
    @{ id='Google.GoogleDrive';         name='Google Drive' }
    @{ id='Adobe.Acrobat.Pro';          name='Adobe Acrobat' }
    @{ id='Musescore.Musescore';        name='MuseScore' }
    @{ id='Mozilla.Firefox';            name='Firefox' }
    @{ id='Logitech.GHUB';             name='Logitech G HUB' }
    @{ id='REALiX.HWiNFO';             name='HWiNFO' }
    @{ id='CrystalDewWorld.CrystalDiskInfo'; name='CrystalDiskInfo' }
    @{ id='Piriform.CCleaner';          name='CCleaner' }
    @{ id='Malwarebytes.Malwarebytes';  name='Malwarebytes' }
    @{ id='Anthropic.Claude';           name='Claude Desktop' }
    @{ id='DuckDuckGo.DesktopBrowser';  name='DuckDuckGo' }
)

foreach ($pkg in $wingetPackages) {
    $check = winget list --id $pkg.id --accept-source-agreements 2>$null | Select-String $pkg.id
    if ($check) {
        Write-Skip "$($pkg.name) already installed"
    } else {
        winget install --id $pkg.id --accept-source-agreements --accept-package-agreements -s winget 2>$null
        if ($LASTEXITCODE -eq 0) { Write-OK "$($pkg.name)" } else { Write-Host "   WARN: $($pkg.name) install returned $LASTEXITCODE" -ForegroundColor Yellow }
    }
}

# ─────────────────────────────────────────────────────
# 11. npm global packages
# ─────────────────────────────────────────────────────
Write-Step "npm global packages"

$npmGlobals = @(
    'pnpm@10'
    'bun'
    'pm2'
    'playwright'
    'serve'
    'pagedjs-cli'
    'turbo'
    'tsx'
    'supabase'
    'build-corpus'
    'regen-mde'
    '@lifeaitools/clauth@latest'
    '@anthropic-ai/claude-code'
    '@openai/codex'
    '@swiftlysingh/excalidraw-cli'
    'firecrawl-cli'
    'impeccable'
    '@googleworkspace/cli'
    '@masonator/coolify-mcp'
    'opencode-ai'
)

foreach ($pkg in $npmGlobals) {
    npm install -g $pkg 2>$null
    if ($LASTEXITCODE -eq 0) { Write-OK "$pkg" }
    else { Write-Host "   WARN: $pkg install failed (exit $LASTEXITCODE)" -ForegroundColor Yellow }
}

# ─────────────────────────────────────────────────────
# 12. Playwright browsers (Chromium)
# ─────────────────────────────────────────────────────
Write-Step "CodeFlow enforcement hooks (Claude Code)"
if (Test-Path "C:\Dev\regen-root\scripts\claude-hooks\install-codeflow-hooks.mjs") {
    node "C:\Dev\regen-root\scripts\claude-hooks\install-codeflow-hooks.mjs"
    if ($LASTEXITCODE -eq 0) { Write-OK "codeflow hooks installed + verified" }
    else { Write-Host "   WARN: codeflow hook verify failed (is codeflow-mcp on 3109 up?) -- re-run after codeflow install" -ForegroundColor Yellow }
} else {
    Write-Skip "regen-root not cloned yet -- run install-codeflow-hooks.mjs after clone"
}

Write-Step "Playwright browsers (Chromium)"
npx playwright install chromium 2>$null
Write-OK "Playwright Chromium installed"

# ─────────────────────────────────────────────────────
# 13. Python packages (pip)
# ─────────────────────────────────────────────────────
Write-Step "Python pip packages"

$pipPackages = @(
    'anthropic'
    'beautifulsoup4'
    'boto3'
    'build'
    'playwright'
    'requests'
    'Authlib'
    'markitdown'
    'docling'
    'python-docx'
    'python-pptx'
    'PyMuPDF'
    'supabase'
    'openai'
    'mcp'
    'torch'
    'torchvision'
    'easyocr'
    'pandas'
    'numpy'
    'scipy'
    'matplotlib'
    'Pillow'
    'httpx'
    'pydantic'
    'rich'
    'fastmcp'
    'notebooklm-py'
    'neo4j'
)

foreach ($pkg in $pipPackages) {
    pip install --quiet $pkg 2>$null
    if ($LASTEXITCODE -eq 0) { Write-OK "pip: $pkg" }
    else { Write-Host "   WARN: pip $pkg install failed (exit $LASTEXITCODE)" -ForegroundColor Yellow }
}

# ─────────────────────────────────────────────────────
# 14. Consolidate all paths to System (Machine) PATH
# ─────────────────────────────────────────────────────
Write-Step "Consolidating all paths to System (Machine) PATH"

$requiredPaths = @(
    "C:\Program Files\nodejs"
    "C:\Python312"
    "C:\Python312\Scripts"
    "C:\Program Files\Git\cmd"
    "C:\Program Files\Docker\Docker\resources\bin"
    "C:\Program Files\WezTerm"
    "C:\Program Files\Microsoft VS Code\bin"
    "C:\Program Files\GitHub CLI"
    "C:\Program Files\Cloudflared"
    "C:\ProgramData\chocolatey\bin"
)
# npm/pnpm paths are user-specific — must stay in User PATH, not Machine PATH
# (elevated runs resolve $env:APPDATA to the admin account, not the dev user)
$userSpecificPaths = @(
    "$env:APPDATA\npm"
    "$env:LOCALAPPDATA\pnpm"
)
foreach ($p in $userSpecificPaths) {
    $expanded = [System.Environment]::ExpandEnvironmentVariables($p)
    if (Test-Path $expanded) {
        $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
        if (-not ($userPath -split ';' | Where-Object { $_ -eq $expanded })) {
            [System.Environment]::SetEnvironmentVariable("Path", ($userPath.TrimEnd(';') + ";$expanded"), "User")
            Write-OK "Added to User PATH: $expanded"
        }
    }
}

foreach ($p in $requiredPaths) {
    $expanded = [System.Environment]::ExpandEnvironmentVariables($p)
    if (Test-Path $expanded) {
        Ensure-SystemPath $expanded
        Remove-UserPath $expanded
    }
}

# Move anything npm/node/python put in User PATH to Machine PATH
$userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath) {
    $movedCount = 0
    foreach ($entry in ($userPath -split ';' | Where-Object { $_ })) {
        if ($entry -match 'npm|pnpm|nodejs|Python|bun|\.local|Scripts') {
            Ensure-SystemPath $entry
            Remove-UserPath $entry
            $movedCount++
        }
    }
    if ($movedCount -gt 0) { Write-OK "Moved $movedCount entries from User PATH to System PATH" }
}

# Clear User PATH entirely if it's now empty or duplicates
$finalUserPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
$remaining = ($finalUserPath -split ';' | Where-Object { $_ }).Count
if ($remaining -eq 0) {
    [System.Environment]::SetEnvironmentVariable("Path", $null, "User")
    Write-OK "User PATH cleared (all entries in System PATH)"
} else {
    Write-Host "   INFO: $remaining entries remain in User PATH (non-dev paths)" -ForegroundColor Gray
}

# Final refresh
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine")

# ─────────────────────────────────────────────────────
# 15. Create C:\Dev if it doesn't exist
# ─────────────────────────────────────────────────────
Write-Step "Create C:\Dev"
if (Test-Path "C:\Dev") {
    Write-Skip "C:\Dev already exists"
} else {
    New-Item -ItemType Directory -Path "C:\Dev" -Force | Out-Null
    Write-OK "C:\Dev created"
}

# ─────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Install complete. REBOOT then run:" -ForegroundColor Green
Write-Host "  .\restore-profile.ps1" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green



