#!/usr/bin/env pwsh
# wrangler-deploy.ps1
# Sets CF token as env var FIRST then runs all wrangler commands.

$ROOT                 = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { 'C:/Dev/regen-root' }
$WORKER_DIR           = "$ROOT/workers/token-builder"
$CLAUTH               = 'http://127.0.0.1:52437/v'
$SUPABASE_SERVICE_KEY = (curl.exe -fsS "$CLAUTH/supabase-service").Trim()
$WEBHOOK_SECRET       = (curl.exe -fsS "$CLAUTH/token-builder-webhook").Trim()

# ── Auth: set BEFORE any wrangler call ───────────────────────────────────────
$env:CLOUDFLARE_API_TOKEN = (curl.exe -fsS "$CLAUTH/cloudflare").Trim()

function Step($n, $msg) { Write-Host "`n─── STEP $n — $msg ───" -ForegroundColor Cyan }
function Ok($msg) { Write-Host "  ✓ $msg" -ForegroundColor Green }
function Info($msg) { Write-Host "  → $msg" -ForegroundColor Gray }

Set-Location $WORKER_DIR

Step 1 "Verify CF auth"
npx wrangler whoami
if ($LASTEXITCODE -ne 0) { Write-Host "Auth failed — check token" -ForegroundColor Red; exit 1 }
Ok "Authenticated"

Step 2 "Set secrets"
Info "SUPABASE_SERVICE_KEY"
$SUPABASE_SERVICE_KEY | npx wrangler secret put SUPABASE_SERVICE_KEY
Start-Sleep 2

Info "CF_API_TOKEN"
$env:CLOUDFLARE_API_TOKEN | npx wrangler secret put CF_API_TOKEN
Start-Sleep 2

Info "WEBHOOK_SECRET"
$WEBHOOK_SECRET | npx wrangler secret put WEBHOOK_SECRET
Start-Sleep 2
Ok "Secrets set"

Step 3 "Deploy Worker"
npx wrangler deploy
if ($LASTEXITCODE -ne 0) { Write-Host "Deploy failed" -ForegroundColor Red; exit 1 }
Ok "Deployed"
Start-Sleep 8

Step 4 "Rebuild all brand token CSS"
Info "Calling /build?slug=all"
try {
    $r = Invoke-WebRequest -Uri "https://token-builder.regendevcorp.com/build?slug=all" -UseBasicParsing -TimeoutSec 30
    Write-Host $r.Content
    Ok "Token CSS built"
} catch {
    Write-Host "  Primary route not propagated yet — use workers.dev URL from Step 3 output" -ForegroundColor Yellow
    Write-Host "  Run: curl https://token-builder.<account>.workers.dev/build?slug=all" -ForegroundColor Yellow
}

Write-Host "`nDone." -ForegroundColor Green
