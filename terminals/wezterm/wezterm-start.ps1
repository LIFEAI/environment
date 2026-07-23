Set-Location 'C:\Dev\regen-root'

$WezProfiles = @(
  [pscustomobject]@{ Name = 'PowerShell'; Cwd = 'C:\Dev\regen-root'; Command = @('pwsh.exe', '-NoLogo') },
  [pscustomobject]@{ Name = 'SV'; Cwd = 'C:\Dev\regen-root'; Command = @('pwsh.exe', '-NoLogo', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', 'C:\Dev\regen-root\scripts\cell-init.ps1', 'sv') },
  [pscustomobject]@{ Name = 'Portal'; Cwd = 'C:\Dev\regen-root'; Command = @('pwsh.exe', '-NoLogo', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', 'C:\Dev\regen-root\scripts\cell-init.ps1', 'cell-portal') },
  [pscustomobject]@{ Name = 'Data'; Cwd = 'C:\Dev\regen-root'; Command = @('pwsh.exe', '-NoLogo', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', 'C:\Dev\regen-root\scripts\cell-init.ps1', 'cell-data') },
  [pscustomobject]@{ Name = 'CS2'; Cwd = 'C:\Dev\regen-root'; Command = @('pwsh.exe', '-NoLogo', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', 'C:\Dev\regen-root\scripts\cell-init.ps1', 'cell-cs2') },
  [pscustomobject]@{ Name = 'Mktg'; Cwd = 'C:\Dev\regen-root'; Command = @('pwsh.exe', '-NoLogo', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', 'C:\Dev\regen-root\scripts\cell-init.ps1', 'cell-mktg') },
  [pscustomobject]@{ Name = 'Infra'; Cwd = 'C:\Dev\regen-root'; Command = @('pwsh.exe', '-NoLogo', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', 'C:\Dev\regen-root\scripts\cell-init.ps1', 'cell-infra') },
  [pscustomobject]@{ Name = 'Spec'; Cwd = 'C:\Dev\regen-root'; Command = @('pwsh.exe', '-NoLogo', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', 'C:\Dev\regen-root\scripts\cell-init.ps1', 'specialist') },
  [pscustomobject]@{ Name = 'Codex'; Cwd = 'C:\Dev\regen-root'; Command = @('pwsh.exe', '-NoLogo', '-NoExit', '-Command', 'codex') },
  [pscustomobject]@{ Name = 'Claude'; Cwd = 'C:\Dev\regen-root'; Command = @('pwsh.exe', '-NoLogo', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', 'C:\Dev\regen-root\scripts\cell-init.ps1', 'sv') },
  [pscustomobject]@{ Name = 'Co Develop Claude'; Cwd = 'C:\Dev\regen-root'; Command = @('cmd.exe', '/k', "$env:APPDATA\clauth\codevelop-claude.cmd") },
  [pscustomobject]@{ Name = 'Co Develop Codex'; Cwd = 'C:\Dev\regen-root'; Command = @('cmd.exe', '/k', "$env:APPDATA\clauth\codevelop-codex.cmd") },
  [pscustomobject]@{ Name = 'CCandMe 4-pane'; Cwd = 'C:\Dev\CCandMe'; Command = @('__CCANDME_LAYOUT__') }
)

function Start-WezTermTab {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string[]]$Command,
    [string]$Cwd = 'C:\Dev\regen-root'
  )

  $args = @('cli', 'spawn', '--cwd', $Cwd, '--') + $Command
  & wezterm @args | Out-Null
  Write-Host "Opened $Name"
}

function Start-CCandMeLayout {
  $cc = 'C:\Dev\CCandMe'
  $work = 'C:\Dev\regen-root'

  $supervisor = (& wezterm cli spawn --cwd $cc -- cmd.exe /k "title Supervisor && node C:\Dev\CCandMe\bin\ccandme.mjs supervisor").Trim()
  if (-not $supervisor) { throw 'Failed to create CCandMe supervisor pane.' }

  $claude = (& wezterm cli split-pane --pane-id $supervisor --top --percent 66 --cwd $work -- cmd.exe /k "cd /d $work && title Claude && claude").Trim()
  if (-not $claude) { throw 'Failed to create CCandMe Claude pane.' }

  $codex = (& wezterm cli split-pane --pane-id $claude --right --percent 50 --cwd $work -- pwsh.exe -NoLogo -NoExit -Command "codex").Trim()
  if (-not $codex) { throw 'Failed to create CCandMe Codex pane.' }

  $me = (& wezterm cli split-pane --pane-id $supervisor --right --percent 50 --cwd $cc -- cmd.exe /k "title Me && prompt Me$G$S && cls").Trim()
  if (-not $me) { throw 'Failed to create CCandMe Me pane.' }

  & wezterm cli activate-pane --pane-id $me | Out-Null
  Write-Host 'Opened CCandMe 4-pane layout'
}

function Show-WezTermProfileMenu {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing

  $form = New-Object System.Windows.Forms.Form
  $form.Text = 'Open WezTerm Profile'
  $form.StartPosition = 'CenterScreen'
  $form.Width = 360
  $form.Height = 470
  $form.TopMost = $true
  $form.BackColor = [System.Drawing.Color]::FromArgb(21, 20, 19)
  $form.ForeColor = [System.Drawing.Color]::FromArgb(216, 210, 200)
  $form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

  $label = New-Object System.Windows.Forms.Label
  $label.Text = 'Choose a profile'
  $label.Left = 16
  $label.Top = 14
  $label.Width = 300
  $label.Height = 24
  $form.Controls.Add($label)

  $list = New-Object System.Windows.Forms.ListBox
  $list.Left = 16
  $list.Top = 44
  $list.Width = 310
  $list.Height = 320
  $list.BackColor = [System.Drawing.Color]::FromArgb(30, 28, 25)
  $list.ForeColor = [System.Drawing.Color]::FromArgb(240, 232, 220)
  $list.BorderStyle = 'FixedSingle'
  $list.IntegralHeight = $false
  foreach ($profile in $WezProfiles) { [void]$list.Items.Add($profile.Name) }
  $list.SelectedIndex = 0
  $form.Controls.Add($list)

  $open = New-Object System.Windows.Forms.Button
  $open.Text = 'Open'
  $open.Left = 166
  $open.Top = 378
  $open.Width = 76
  $open.Height = 32
  $open.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $form.AcceptButton = $open
  $form.Controls.Add($open)

  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = 'Cancel'
  $cancel.Left = 250
  $cancel.Top = 378
  $cancel.Width = 76
  $cancel.Height = 32
  $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $form.CancelButton = $cancel
  $form.Controls.Add($cancel)

  $list.Add_DoubleClick({ $form.DialogResult = [System.Windows.Forms.DialogResult]::OK; $form.Close() })
  $result = $form.ShowDialog()
  if ($result -ne [System.Windows.Forms.DialogResult]::OK -or $list.SelectedIndex -lt 0) {
    return $null
  }
  return $WezProfiles[$list.SelectedIndex]
}

function Open-WezTermProfileMenu {
  $profile = Show-WezTermProfileMenu
  if ($null -eq $profile) {
    wez-menu
    return
  }

  if ($profile.Command.Count -eq 1 -and $profile.Command[0] -eq '__CCANDME_LAYOUT__') {
    Start-CCandMeLayout
  } else {
    Start-WezTermTab $profile.Name $profile.Command $profile.Cwd
  }
  if ($env:WEZTERM_PANE) {
    Start-Sleep -Milliseconds 150
    & wezterm cli kill-pane --pane-id $env:WEZTERM_PANE | Out-Null
  }
}

function sv {
  Start-WezTermTab 'SV' @('pwsh.exe', '-NoLogo', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', 'C:\Dev\regen-root\scripts\cell-init.ps1', 'sv')
}

function portal {
  Start-WezTermTab 'Portal' @('pwsh.exe', '-NoLogo', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', 'C:\Dev\regen-root\scripts\cell-init.ps1', 'cell-portal')
}

function data {
  Start-WezTermTab 'Data' @('pwsh.exe', '-NoLogo', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', 'C:\Dev\regen-root\scripts\cell-init.ps1', 'cell-data')
}

function cs2 {
  Start-WezTermTab 'CS2' @('pwsh.exe', '-NoLogo', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', 'C:\Dev\regen-root\scripts\cell-init.ps1', 'cell-cs2')
}

function mktg {
  Start-WezTermTab 'Mktg' @('pwsh.exe', '-NoLogo', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', 'C:\Dev\regen-root\scripts\cell-init.ps1', 'cell-mktg')
}

function infra {
  Start-WezTermTab 'Infra' @('pwsh.exe', '-NoLogo', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', 'C:\Dev\regen-root\scripts\cell-init.ps1', 'cell-infra')
}

function spec {
  Start-WezTermTab 'Spec' @('pwsh.exe', '-NoLogo', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', 'C:\Dev\regen-root\scripts\cell-init.ps1', 'specialist')
}

function codex-tab {
  Start-WezTermTab 'Codex' @('pwsh.exe', '-NoLogo', '-NoExit', '-Command', 'codex')
}

function claude-tab {
  Start-WezTermTab 'Claude' @('pwsh.exe', '-NoLogo', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', 'C:\Dev\regen-root\scripts\cell-init.ps1', 'sv')
}

function codev-claude {
  Start-WezTermTab 'Co Develop Claude' @('cmd.exe', '/k', "$env:APPDATA\clauth\codevelop-claude.cmd")
}

function codev-codex {
  Start-WezTermTab 'Co Develop Codex' @('cmd.exe', '/k', "$env:APPDATA\clauth\codevelop-codex.cmd")
}

function ccandme {
  Start-CCandMeLayout
}

function wezterm-restart {
  # Reopen the agent cockpit on workspace 'regen' (resume Claude + Codex).
  & pwsh -NoProfile -ExecutionPolicy Bypass -File 'C:\Dev\regen-root\scripts\wezterm-restart.ps1' @args
}

function save-cockpit {
  # Capture the current Claude + Codex session ids into the cockpit manifest.
  & pwsh -NoProfile -ExecutionPolicy Bypass -File 'C:\Dev\regen-root\scripts\save-cockpit-session.ps1' @args
}

function clipimg {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing

  $image = [System.Windows.Forms.Clipboard]::GetImage()
  if ($null -eq $image) {
    Write-Host 'No image found on the Windows clipboard.'
    return
  }

  $dir = 'C:\Dev\regen-root\.codex\clipboard-images'
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $path = Join-Path $dir ("clipboard-{0}.png" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
  $image.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  Write-Host "Saved clipboard image:"
  Write-Host $path
}

function wez-menu {
  Write-Host ''
  Write-Host 'WezTerm profiles'
  Write-Host '  sv            Supervisor Claude cell'
  Write-Host '  portal        Portal cell'
  Write-Host '  data          Data cell'
  Write-Host '  cs2           CS2 cell'
  Write-Host '  mktg          Marketing cell'
  Write-Host '  infra         Infra cell'
  Write-Host '  spec          Specialist cell'
  Write-Host '  codex-tab     Codex tab'
  Write-Host '  claude-tab    Claude SV tab'
  Write-Host '  codev-claude  Co-develop Claude peer'
  Write-Host '  codev-codex   Co-develop Codex peer'
  Write-Host '  ccandme         Open CCandMe as a 4-pane WezTerm layout'
  Write-Host '  wezterm-restart Reopen the agent cockpit (resume Claude + Codex) on workspace regen'
  Write-Host '  save-cockpit    Save current Claude + Codex session ids to the cockpit manifest'
  Write-Host '  clipimg       Save clipboard image to .codex\clipboard-images'
  Write-Host ''
  Write-Host 'Keyboard shortcuts also work: Alt+1..Alt+9'
  Write-Host ''
}

wez-menu
Open-WezTermProfileMenu
