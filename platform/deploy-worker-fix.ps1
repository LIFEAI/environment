#!/usr/bin/env pwsh
# deploy-worker-fix.ps1 — Deploy token-builder with CF token as env var
# Usage: pwsh scripts/deploy-worker-fix.ps1

$ROOT                 = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { 'C:/Dev/regen-root' }
$WORKER_DIR           = "$ROOT/workers/token-builder"
$CLAUTH               = 'http://127.0.0.1:52437/v'
$COOLIFY_API          = (curl.exe -fsS "$CLAUTH/coolify-api").Trim()
$BRAND_STUDIO_UUID    = "a859evmmv0k2sx33kzlq7juv"

# ── Set CF token as env var so wrangler can auth non-interactively ────────────
$env:CLOUDFLARE_API_TOKEN = (curl.exe -fsS "$CLAUTH/cloudflare").Trim()

$SUPABASE_SERVICE_KEY = (curl.exe -fsS "$CLAUTH/supabase-service").Trim()
$WEBHOOK_SECRET       = (curl.exe -fsS "$CLAUTH/token-builder-webhook").Trim()

function Step($n, $msg) { Write-Host "`n─── STEP $n — $msg ───" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  ✓ $msg" -ForegroundColor Green }
function Info($msg) { Write-Host "  → $msg" -ForegroundColor Gray }
function Fail($msg) { Write-Host "  ✗ $msg" -ForegroundColor Red; exit 1 }

Set-Location $WORKER_DIR

# ── STEP 1: Set secrets ───────────────────────────────────────────────────────
Step 1 "Set Wrangler secrets (CF token in env)"

Info "SUPABASE_SERVICE_KEY..."
$SUPABASE_SERVICE_KEY | npx wrangler secret put SUPABASE_SERVICE_KEY
if ($LASTEXITCODE -ne 0) { Fail "SUPABASE_SERVICE_KEY failed" }
Start-Sleep 2

Info "CF_API_TOKEN..."
$env:CLOUDFLARE_API_TOKEN | npx wrangler secret put CF_API_TOKEN
if ($LASTEXITCODE -ne 0) { Fail "CF_API_TOKEN failed" }
Start-Sleep 2

Info "WEBHOOK_SECRET..."
$WEBHOOK_SECRET | npx wrangler secret put WEBHOOK_SECRET
if ($LASTEXITCODE -ne 0) { Fail "WEBHOOK_SECRET failed" }
Start-Sleep 2

Ok "All secrets set"

# ── STEP 2: Deploy ────────────────────────────────────────────────────────────
Step 2 "Deploy token-builder Worker"

npx wrangler deploy
if ($LASTEXITCODE -ne 0) { Fail "wrangler deploy failed" }
Ok "Worker deployed"
Start-Sleep 8

# ── STEP 3: Rebuild token CSS ─────────────────────────────────────────────────
Step 3 "Rebuild all brand token CSS files"

Info "Calling /build?slug=all ..."
try {
    $r = Invoke-WebRequest -Uri "https://token-builder.regendevcorp.com/build?slug=all" -UseBasicParsing -TimeoutSec 30
    Write-Host $r.Content
    Ok "Token CSS files built"
} catch {
    Info "Primary route not yet propagated — note workers.dev URL from Step 2 output and call:"
    Info "  curl https://token-builder.<account>.workers.dev/build?slug=all"
}

# ── STEP 4: Verify R2 ─────────────────────────────────────────────────────────
Step 4 "Verify R2 token objects"
npx wrangler r2 object list regen-media --prefix tokens/

# ── STEP 5: Coolify redeploy ──────────────────────────────────────────────────
Step 5 "Trigger Coolify redeploy of brand-studio"

try {
    $c = Invoke-WebRequest `
        -Uri "https://deploy.regendevcorp.com/api/v1/deploy?uuid=$BRAND_STUDIO_UUID&force=true" `
        -Method Get `
        -Headers @{ Authorization = "Bearer $COOLIFY_API" } `
        -UseBasicParsing
    Write-Host $c.Content
    Ok "Coolify deploy triggered"
} catch {
    Fail "Coolify trigger failed: $_"
}

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  DONE" -ForegroundColor Green
Write-Host "  Studio:       https://studio.regendevcorp.com" -ForegroundColor Green
Write-Host "  Page Builder: https://studio.regendevcorp.com/brands/{id}/builder" -ForegroundColor Green
Write-Host "  Token Worker: https://token-builder.regendevcorp.com/build?slug=prt" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Green
