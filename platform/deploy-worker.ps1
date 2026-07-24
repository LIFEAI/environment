#!/usr/bin/env pwsh
# deploy-worker.ps1 — Deploy token-builder CF Worker + rebuild token CSS
# Run from: C:/Dev/regen-root
# Usage: pwsh scripts/deploy-worker.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Step($n, $msg) { Write-Host "`n─── STEP $n — $msg ───" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  ✓ $msg" -ForegroundColor Green }
function Info($msg) { Write-Host "  → $msg" -ForegroundColor Gray }

$ROOT                 = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { 'C:/Dev/regen-root' }
$CLAUTH               = 'http://127.0.0.1:52437/v'
$SUPABASE_SERVICE_KEY = (curl.exe -fsS "$CLAUTH/supabase-service").Trim()
$CF_API_TOKEN         = (curl.exe -fsS "$CLAUTH/cloudflare").Trim()
$WEBHOOK_SECRET       = (curl.exe -fsS "$CLAUTH/token-builder-webhook").Trim()

# ────────────────────────────────────────────────────────────────────────────
Step 1 "Commit updated lockfile"
# ────────────────────────────────────────────────────────────────────────────

Set-Location $ROOT
git add pnpm-lock.yaml apps/brand-studio/package.json apps/brand-studio/.npmrc
git diff --cached --quiet
if ($LASTEXITCODE -eq 0) {
    Info "Nothing to commit — lockfile already up to date"
} else {
    git commit -m "chore(brand-studio): install @puckeditor/core 0.21.2"
    Ok "Lockfile committed"
}

# ────────────────────────────────────────────────────────────────────────────
Step 2 "Install token-builder deps"
# ────────────────────────────────────────────────────────────────────────────

Set-Location "$ROOT/workers/token-builder"
npm install
Ok "token-builder node_modules ready"

# ────────────────────────────────────────────────────────────────────────────
Step 3 "Set Wrangler secrets"
# ────────────────────────────────────────────────────────────────────────────

Set-Location "$ROOT/workers/token-builder"

Info "SUPABASE_SERVICE_KEY..."
$SUPABASE_SERVICE_KEY | npx wrangler secret put SUPABASE_SERVICE_KEY
Start-Sleep 2

Info "CF_API_TOKEN..."
$CF_API_TOKEN | npx wrangler secret put CF_API_TOKEN
Start-Sleep 2

Info "WEBHOOK_SECRET..."
$WEBHOOK_SECRET | npx wrangler secret put WEBHOOK_SECRET
Start-Sleep 2

Ok "All secrets set"

# ────────────────────────────────────────────────────────────────────────────
Step 4 "Deploy Worker"
# ────────────────────────────────────────────────────────────────────────────

Set-Location "$ROOT/workers/token-builder"
npx wrangler deploy
Ok "Worker deployed"
Start-Sleep 5

# ────────────────────────────────────────────────────────────────────────────
Step 5 "Rebuild all brand token CSS"
# ────────────────────────────────────────────────────────────────────────────

Info "Triggering /build?slug=all ..."
$result = Invoke-RestMethod -Uri "https://token-builder.regendevcorp.com/build?slug=all" -Method Get -ErrorAction SilentlyContinue
if ($result) {
    Write-Host $result
    Ok "Token CSS built"
} else {
    Info "Primary route not yet active — check wrangler deploy output for workers.dev URL"
    Info "Run manually: curl https://<account>.workers.dev/build?slug=all"
}

# ────────────────────────────────────────────────────────────────────────────
Step 6 "Verify R2 objects"
# ────────────────────────────────────────────────────────────────────────────

Set-Location "$ROOT/workers/token-builder"
npx wrangler r2 object list regen-media --prefix tokens/

# ────────────────────────────────────────────────────────────────────────────
Step 7 "Trigger Coolify redeploy of brand-studio"
# ────────────────────────────────────────────────────────────────────────────

Info "Triggering brand-studio Coolify redeploy..."
$COOLIFY_TOKEN = (curl.exe -fsS "$CLAUTH/coolify-api").Trim()
Invoke-RestMethod -Uri "https://deploy.regendevcorp.com/api/v1/deploy?uuid=a859evmmv0k2sx33kzlq7juv&force=true" -Method Get -Headers @{ Authorization = "Bearer $COOLIFY_TOKEN" }
Ok "Coolify deploy triggered"

# ────────────────────────────────────────────────────────────────────────────
Write-Host "`n═══════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  DONE" -ForegroundColor Green
Write-Host "  Brand Studio: https://studio.regendevcorp.com" -ForegroundColor Green
Write-Host "  Page Builder: https://studio.regendevcorp.com/brands/{id}/builder" -ForegroundColor Green
Write-Host "  Token check:  https://token-builder.regendevcorp.com/build?slug=prt" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Green
