#!/usr/bin/env pwsh
# wrangler-deploy.ps1
# Sets CF token as env var FIRST then runs all wrangler commands.

$WORKER_DIR           = "C:/Dev/regen-root/workers/token-builder"
$SUPABASE_SERVICE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InV2b2plenVvcmpncXptaGhnbHV1Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3MTMxNDcxNywiZXhwIjoyMDg2ODkwNzE3fQ.8nlxAyvJkUXlDaS87oV4j6ZyJd_5qH_aijB1pUFVlBQ"
$WEBHOOK_SECRET       = "regen-webhook-secret-2026"

# ── Auth: set BEFORE any wrangler call ───────────────────────────────────────
$env:CLOUDFLARE_API_TOKEN = $(curl -s http://127.0.0.1:52437/v/cloudflare)

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
