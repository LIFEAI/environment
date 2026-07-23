#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\lifeai-shell.ps1"

Unregister-LifeAICommand -CommandId 'UploadToRegenMedia'
Unregister-LegacyContextMenuVerb -Extensions @('jpg','jpeg','png','webp','gif','tiff','tif','bmp') -VerbId 'UploadToRegenMedia'

$sendTo = [System.IO.Path]::Combine($env:APPDATA, 'Microsoft\Windows\SendTo\Regen Media.lnk')
if (Test-Path $sendTo) {
    [System.IO.File]::Delete($sendTo)
}

Uninstall-LifeAISparsePackage

Restart-LifeAIExplorer
