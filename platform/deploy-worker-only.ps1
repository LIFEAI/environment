#!/usr/bin/env pwsh
# deploy-worker-only.ps1 — Deploy token-builder Worker + rebuild tokens
# Picks up after pnpm install completed successfully.
# Run from anywhere. Usage: pwsh scripts/deploy-worker-only.ps1

$ROOT = "C:/Dev/regen-root"
$SUPABASE_SERVICE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InV2b2plenVvcmpncXptaGhnbHV1Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3MTMxNDcxNywiZXhwIjoyMDg2ODkwNzE3fQ.8nlxAyvJkUXlDaS87oV4j6ZyJd_5qH_aijB1pUFVlBQ"
$CF_API_TOKEN = $(curl -s http://127.0.0.1:52437/v/cloudflare)
$WEBHOOK_SECRET       = "regen-webhook-secret-2026"
$WORKER_DIR           = "$ROOT/workers/token-builder"
$COOLIFY_API = $(curl -s http://127.0.0.1:52437/v/coolify-api)
$BRAND_STUDIO_UUID    = "a859evmmv0k2sx33kzlq7juv"

function Step($n, $msg) { Write-Host "`n─── STEP $n — $msg ───" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  ✓ $msg" -ForegroundColor Green }
function Info($msg) { Write-Host "  → $msg" -ForegroundColor Gray }
function Fail($msg) { Write-Host "  ✗ $msg" -ForegroundColor Red }

# ── STEP 1: Worker deps ───────────────────────────────────────────────────────
Step 1 "Install token-builder deps"
Set-Location $WORKER_DIR
npm install --silent
Ok "node_modules ready"

# ── STEP 2: Set secrets ───────────────────────────────────────────────────────
Step 2 "Set Wrangler secrets"

Info "SUPABASE_SERVICE_KEY..."
$SUPABASE_SERVICE_KEY | npx wrangler secret put SUPABASE_SERVICE_KEY
Start-Sleep 3

Info "CF_API_TOKEN..."
$CF_API_TOKEN | npx wrangler secret put CF_API_TOKEN
Start-Sleep 3

Info "WEBHOOK_SECRET..."
$WEBHOOK_SECRET | npx wrangler secret put WEBHOOK_SECRET
Start-Sleep 3

Ok "All secrets set"

# ── STEP 3: Deploy ────────────────────────────────────────────────────────────
Step 3 "Deploy token-builder to Cloudflare"
Set-Location $WORKER_DIR
npx wrangler deploy
$deployExit = $LASTEXITCODE
if ($deployExit -ne 0) {
    Fail "wrangler deploy failed (exit $deployExit)"
    exit 1
}
Ok "Worker deployed"
Start-Sleep 8

# ── STEP 4: Rebuild token CSS files ──────────────────────────────────────────
Step 4 "Rebuild all brand token CSS files"

# Try primary domain first
Info "Hitting token-builder.regendevcorp.com/build?slug=all ..."
try {
    $result = Invoke-WebRequest -Uri "https://token-builder.regendevcorp.com/build?slug=all" -UseBasicParsing -TimeoutSec 30
    Write-Host $result.Content
    Ok "Token CSS files built via primary domain"
} catch {
    Fail "Primary domain not routed yet (worker may need route propagation)"
    Info "Trying workers.dev fallback — check wrangler output above for your subdomain URL"
    Info "Manual fallback: curl https://token-builder.<YOUR_SUBDOMAIN>.workers.dev/build?slug=all"
}

# ── STEP 5: Verify R2 ─────────────────────────────────────────────────────────
Step 5 "Verify R2 token objects"
Set-Location $WORKER_DIR
npx wrangler r2 object list regen-media --prefix tokens/

# ── STEP 6: Coolify redeploy ──────────────────────────────────────────────────
Step 6 "Trigger Coolify redeploy of brand-studio"
Info "POSTing to Coolify deploy endpoint..."
try {
    $coolify = Invoke-WebRequest `
        -Uri "https://deploy.regendevcorp.com/api/v1/deploy?uuid=$BRAND_STUDIO_UUID&force=true" `
        -Method Get `
        -Headers @{ Authorization = "Bearer $COOLIFY_API" } `
        -UseBasicParsing
    Write-Host $coolify.Content
    Ok "Coolify deploy triggered — brand-studio rebuilding with @puckeditor/core"
} catch {
    Fail "Coolify trigger failed: $_"
    Info "Manual: curl -H 'Authorization: Bearer $COOLIFY_API' https://deploy.regendevcorp.com/api/v1/deploy?uuid=$BRAND_STUDIO_UUID&force=true"
}

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  COMPLETE" -ForegroundColor Green
Write-Host "  Studio:       https://studio.regendevcorp.com" -ForegroundColor Green
Write-Host "  Page Builder: https://studio.regendevcorp.com/brands/{id}/builder" -ForegroundColor Green
Write-Host "  Token check:  https://token-builder.regendevcorp.com/build?slug=prt" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Green
