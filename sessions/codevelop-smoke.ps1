param(
  [int]$Port = 53137,
  [string]$ClauthCli = "C:\Dev\clauth\cli\index.js",
  [string]$Repo = "C:\Dev\regen-root"
)

$ErrorActionPreference = "Stop"

if ($Port -eq 52437 -or $Port -eq 52438) {
  throw "Refusing to run codevelop smoke on reserved clauth port $Port"
}

$existing = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($existing) {
  throw "Port $Port is already listening; choose a free isolated port"
}

function Invoke-CodevelopJson {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Uri,
    [object]$Body,
    [hashtable]$Headers
  )

  $params = @{
    Method = $Method
    Uri = $Uri
    TimeoutSec = 5
  }
  if ($Headers) {
    $params.Headers = $Headers
  }
  if ($null -ne $Body) {
    $params.ContentType = "application/json"
    $params.Body = ($Body | ConvertTo-Json -Depth 20)
  }
  Invoke-RestMethod @params
}

$sandboxRoot = Join-Path $env:TEMP ("clauth-codevelop-smoke-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $sandboxRoot | Out-Null
$stdout = Join-Path $sandboxRoot "stdout.log"
$stderr = Join-Path $sandboxRoot "stderr.log"

$proc = Start-Process -FilePath node `
  -ArgumentList @($ClauthCli, "serve", "foreground", "--port", "$Port", "--isolated") `
  -WindowStyle Hidden `
  -PassThru `
  -RedirectStandardOutput $stdout `
  -RedirectStandardError $stderr

try {
  $base = "http://127.0.0.1:$Port"
  $ready = $false
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $ping = Invoke-CodevelopJson -Method "GET" -Uri "$base/ping"
      if ($ping.status -eq "ok") {
        $ready = $true
        break
      }
    } catch {}
  }
  if (-not $ready) {
    $out = Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue
    $err = Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue
    throw "isolated clauth did not become ready. stdout=$out stderr=$err"
  }

  $fakeProject = Join-Path $Repo ".rdc\co-develop\fake-projects\basic-widget"
  $started = Invoke-CodevelopJson -Method "POST" -Uri "$base/codevelop/start" -Body @{
    name = "fake-basic-widget"
    repo = $fakeProject
  }
  $sessionId = $started.session_id

  $null = Invoke-CodevelopJson -Method "POST" -Uri "$base/codevelop/join" -Body @{
    session_id = $sessionId
    peer_id = "claude"
    role = "supervisor"
    target_peer = "codex"
  }
  $null = Invoke-CodevelopJson -Method "POST" -Uri "$base/codevelop/join" -Body @{
    session_id = $sessionId
    peer_id = "codex"
    role = "implementation_partner"
    target_peer = "claude"
  }

  $request = Invoke-CodevelopJson -Method "POST" -Uri "$base/codevelop/send" -Body @{
    session_id = $sessionId
    from = "claude"
    to = "codex"
    type = "build_request"
    role = "builder"
    skill = "rdc:fixit"
    task = "Use the fake Basic Widget project to propose the smallest patch that marks the widget Passed."
    context = @{
      repo = $fakeProject
      owned_files = @(
        (Join-Path $fakeProject "component.txt")
      )
    }
    expect = @{
      response_format = "CO_DEVELOP_REPLY"
      evidence_required = $true
      commit_allowed = $false
    }
  }

  $codexInbox = Invoke-CodevelopJson -Method "POST" -Uri "$base/codevelop/poll" -Body @{
    session_id = $sessionId
    peer_id = "codex"
  }

  if ($codexInbox.count -ne 1 -or $codexInbox.messages[0].from -ne "claude") {
    throw "codex inbox routing failed"
  }

  $null = Invoke-CodevelopJson -Method "POST" -Uri "$base/codevelop/send" -Body @{
    session_id = $sessionId
    turn_id = $request.turn_id
    from = "codex"
    to = "claude"
    type = "reply"
    task = "CO_DEVELOP_REPLY"
    context = @{
      verdict = "pass"
      summary = "Fake widget patch proposal: change Status from Pending to Passed and set Last updated."
      evidence = @("Received one addressed build_request from claude", "No live clauth port used")
      files_changed = @()
      commits = @()
      blockers = @()
      next = @("Claude can accept the fake patch proposal")
    }
  }

  $claudeInbox = Invoke-CodevelopJson -Method "POST" -Uri "$base/codevelop/poll" -Body @{
    session_id = $sessionId
    peer_id = "claude"
  }

  if ($claudeInbox.count -ne 1 -or $claudeInbox.messages[0].from -ne "codex") {
    throw "claude inbox routing failed"
  }

  $tools = Invoke-CodevelopJson `
    -Method "POST" `
    -Uri "$base/codevelop" `
    -Headers @{ Accept = "application/json"; Host = "clauth.regendevcorp.com" } `
    -Body @{
      jsonrpc = "2.0"
      id = 1
      method = "tools/list"
    }

  $toolNames = @($tools.result.tools | Where-Object { $_.name -like "codevelop_*" } | Select-Object -ExpandProperty name)
  $stopped = Invoke-CodevelopJson -Method "POST" -Uri "$base/codevelop/stop" -Body @{
    session_id = $sessionId
  }

  [pscustomobject]@{
    verdict = "PASS"
    port = $Port
    reserved_ports_used = $false
    session_id = $sessionId
    request_turn = $request.turn_id
    codex_inbox_count = $codexInbox.count
    codex_received_from = $codexInbox.messages[0].from
    claude_inbox_count = $claudeInbox.count
    claude_received_from = $claudeInbox.messages[0].from
    codevelop_tools = ($toolNames -join ",")
    fake_project = $fakeProject
    stopped = $stopped.stopped
    sandbox = $sandboxRoot
  } | ConvertTo-Json -Depth 10
} finally {
  if ($proc -and -not $proc.HasExited) {
    Stop-Process -Id $proc.Id -Force
  }
}
