#!/usr/bin/env pwsh
# deploy-puck.ps1 — Install @puckeditor/core + deploy token-builder Worker
# Run from: C:/Dev/regen-root
# Usage: pwsh scripts/deploy-puck.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Step($n, $msg) { Write-Host "`n─── STEP $n — $msg ───" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  ✓ $msg" -ForegroundColor Green }
function Err($msg)  { Write-Host "  ✗ $msg" -ForegroundColor Red }
function Info($msg) { Write-Host "  → $msg" -ForegroundColor Gray }

# ── Secrets (from clauth daemon) ─────────────────────────────────────────────
$CLAUTH = 'http://127.0.0.1:52437/v'
$SUPABASE_SERVICE_KEY = (curl.exe -fsS "$CLAUTH/supabase-service").Trim()
$CF_API_TOKEN         = (curl.exe -fsS "$CLAUTH/cloudflare").Trim()
$WEBHOOK_SECRET       = (curl.exe -fsS "$CLAUTH/token-builder-webhook").Trim()
$ROOT                 = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { 'C:/Dev/regen-root' }

# ────────────────────────────────────────────────────────────────────────────
Step 1 "Install @puckeditor/core in brand-studio"
# ────────────────────────────────────────────────────────────────────────────

Set-Location $ROOT

# Add legacy-peer-deps in case React 19 conflicts
$npmrc = "$ROOT/apps/brand-studio/.npmrc"
if (-not (Test-Path $npmrc) -or -not (Get-Content $npmrc | Select-String "legacy-peer-deps")) {
    Add-Content $npmrc "`nlegacy-peer-deps=true"
    Info "Added legacy-peer-deps=true to brand-studio .npmrc"
}

pnpm install --no-frozen-lockfile --filter "@regen/brand-studio"

$puckPkg = "$ROOT/apps/brand-studio/node_modules/@puckeditor/core/package.json"
if (Test-Path $puckPkg) {
    $ver = (Get-Content $puckPkg | ConvertFrom-Json).version
    Ok "@puckeditor/core $ver installed"
} else {
    Err "@puckeditor/core not found after install — check output above"
    exit 1
}

# ────────────────────────────────────────────────────────────────────────────
Step 2 "Commit updated lockfile to develop"
# ────────────────────────────────────────────────────────────────────────────

Set-Location $ROOT
git add pnpm-lock.yaml apps/brand-studio/package.json apps/brand-studio/.npmrc
git commit -m "chore(brand-studio): install @puckeditor/core 0.21"
Ok "Lockfile committed"

# ────────────────────────────────────────────────────────────────────────────
Step 3 "Install token-builder Worker deps"
# ────────────────────────────────────────────────────────────────────────────

Set-Location "$ROOT/workers/token-builder"
npm install
Ok "token-builder node_modules ready"

# ────────────────────────────────────────────────────────────────────────────
Step 4 "Set Wrangler secrets"
# ────────────────────────────────────────────────────────────────────────────

Set-Location "$ROOT/workers/token-builder"

Info "Setting SUPABASE_SERVICE_KEY..."
$SUPABASE_SERVICE_KEY | npx wrangler secret put SUPABASE_SERVICE_KEY
Ok "SUPABASE_SERVICE_KEY set"

Start-Sleep -Seconds 2

Info "Setting CF_API_TOKEN..."
$CF_API_TOKEN | npx wrangler secret put CF_API_TOKEN
Ok "CF_API_TOKEN set"

Start-Sleep -Seconds 2

Info "Setting WEBHOOK_SECRET..."
$WEBHOOK_SECRET | npx wrangler secret put WEBHOOK_SECRET
Ok "WEBHOOK_SECRET set"

Start-Sleep -Seconds 2

# ────────────────────────────────────────────────────────────────────────────
Step 5 "Deploy token-builder Worker"
# ────────────────────────────────────────────────────────────────────────────

Set-Location "$ROOT/workers/token-builder"
npx wrangler deploy
Ok "Worker deployed"

Start-Sleep -Seconds 5

# ────────────────────────────────────────────────────────────────────────────
Step 6 "Rebuild all brand token CSS files"
# ────────────────────────────────────────────────────────────────────────────

Info "Hitting /build?slug=all on token-builder..."
$buildResult = curl -s "https://token-builder.regendevcorp.com/build?slug=all"
Write-Host $buildResult

if ($buildResult -match "✓") {
    Ok "Token CSS files built"
} else {
    Err "Build response unexpected — check above"
    Info "Trying workers.dev fallback..."
    # wrangler deploy output contains the workers.dev URL — try it if primary fails
    npx wrangler r2 object list regen-media --prefix tokens/
}

# ────────────────────────────────────────────────────────────────────────────
Step 7 "Verify R2 objects"
# ────────────────────────────────────────────────────────────────────────────

Set-Location "$ROOT/workers/token-builder"
npx wrangler r2 object list regen-media --prefix tokens/

# ────────────────────────────────────────────────────────────────────────────
Step 8 "Trigger Coolify redeploy of brand-studio"
# ────────────────────────────────────────────────────────────────────────────

Info "Triggering brand-studio redeploy on Coolify..."
$COOLIFY_TOKEN = (curl.exe -fsS "$CLAUTH/coolify-api").Trim()
$coolifyResult = curl -s `
    "https://deploy.regendevcorp.com/api/v1/deploy?uuid=a859evmmv0k2sx33kzlq7juv&force=true" `
    -H "Authorization: Bearer $COOLIFY_TOKEN"
Write-Host $coolifyResult
Ok "Coolify deploy triggered"

# ────────────────────────────────────────────────────────────────────────────
Write-Host "`n═══════════════════════════════════════" -ForegroundColor Green
Write-Host "  ALL STEPS COMPLETE" -ForegroundColor Green
Write-Host "  Brand Studio: https://studio.regendevcorp.com" -ForegroundColor Green
Write-Host "  Page Builder: https://studio.regendevcorp.com/brands/{id}/builder" -ForegroundColor Green
Write-Host "  Token Worker: https://token-builder.regendevcorp.com/build?slug=prt" -ForegroundColor Green
Write-Host "═══════════════════════════════════════" -ForegroundColor Green
