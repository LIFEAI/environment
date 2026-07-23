#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

function Get-LifeAIShellCommandRoot {
    'HKCU:\Software\LifeAI\ShellCommands'
}

function Get-LifeAIShellProjectRoot {
    Join-Path $PSScriptRoot '..\tools\lifeai-shell'
}

function Get-LifeAIShellBinRoot {
    Join-Path (Get-LifeAIShellProjectRoot) 'bin\x64\Release'
}

function Get-LifeAIShellPackageName {
    'LifeAI.Shell'
}

function Get-LifeAIShellPublisher {
    'CN=Life AI Dev'
}

function Ensure-LifeAIShellCommandRoot {
    $root = Get-LifeAIShellCommandRoot
    New-Item -Path $root -Force | Out-Null
    return $root
}

function Register-LifeAICommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandId,

        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [string[]]$Extensions,

        [string]$Icon
    )

    $root = Ensure-LifeAIShellCommandRoot
    $commandKey = Join-Path $root $CommandId
    New-Item -Path $commandKey -Force | Out-Null
    New-ItemProperty -Path $commandKey -Name 'Label' -Value $Label -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $commandKey -Name 'Command' -Value $Command -PropertyType ExpandString -Force | Out-Null
    New-ItemProperty -Path $commandKey -Name 'Extensions' -Value ($Extensions -join ';') -PropertyType String -Force | Out-Null

    if ($Icon) {
        New-ItemProperty -Path $commandKey -Name 'Icon' -Value $Icon -PropertyType ExpandString -Force | Out-Null
    } else {
        Remove-ItemProperty -Path $commandKey -Name 'Icon' -ErrorAction SilentlyContinue
    }
}

function Unregister-LifeAICommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandId
    )

    $commandKey = Join-Path (Get-LifeAIShellCommandRoot) $CommandId
    if (Test-Path $commandKey) {
        Remove-Item -LiteralPath $commandKey -Recurse -Force
    }
}

function Register-LegacyContextMenuVerb {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Extensions,

        [Parameter(Mandatory = $true)]
        [string]$VerbId,

        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [string]$Command,

        [string]$Icon
    )

    foreach ($extension in $Extensions) {
        $normalized = if ($extension.StartsWith('.')) { $extension } else { ".$extension" }
        $verbKey = "HKCU:\Software\Classes\SystemFileAssociations\$normalized\shell\$VerbId"
        $commandKey = Join-Path $verbKey 'command'
        New-Item -Path $commandKey -Force | Out-Null
        New-ItemProperty -Path $verbKey -Name 'MUIVerb' -Value $Label -PropertyType String -Force | Out-Null
        if ($Icon) {
            New-ItemProperty -Path $verbKey -Name 'Icon' -Value $Icon -PropertyType ExpandString -Force | Out-Null
        } else {
            Remove-ItemProperty -Path $verbKey -Name 'Icon' -ErrorAction SilentlyContinue
        }
        Set-ItemProperty -Path $commandKey -Name '(default)' -Value $Command
    }
}

function Unregister-LegacyContextMenuVerb {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Extensions,

        [Parameter(Mandatory = $true)]
        [string]$VerbId
    )

    foreach ($extension in $Extensions) {
        $normalized = if ($extension.StartsWith('.')) { $extension } else { ".$extension" }
        $verbKey = "HKCU:\Software\Classes\SystemFileAssociations\$normalized\shell\$VerbId"
        if (Test-Path $verbKey) {
            Remove-Item -LiteralPath $verbKey -Recurse -Force
        }
    }
}

function Remove-LegacyLifeAIRegistryMenus {
    $legacyKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CommandStore\shell\LifeAI.BuildCorpusToMarkdown',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CommandStore\shell\LifeAI.BuildCorpusToWord',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CommandStore\shell\LifeAI.UploadToRegenMedia',
        'HKCU:\Software\Classes\SystemFileAssociations\.docx\shell\Life AI',
        'HKCU:\Software\Classes\SystemFileAssociations\.md\shell\Life AI',
        'HKCU:\Software\Classes\SystemFileAssociations\.png\shell\Life AI',
        'HKCU:\Software\Classes\SystemFileAssociations\.jpg\shell\Life AI',
        'HKCU:\Software\Classes\SystemFileAssociations\.jpeg\shell\Life AI',
        'HKCU:\Software\Classes\SystemFileAssociations\.webp\shell\Life AI',
        'HKCU:\Software\Classes\SystemFileAssociations\.gif\shell\Life AI',
        'HKCU:\Software\Classes\SystemFileAssociations\.tiff\shell\Life AI',
        'HKCU:\Software\Classes\SystemFileAssociations\.tif\shell\Life AI',
        'HKCU:\Software\Classes\SystemFileAssociations\.bmp\shell\Life AI',
        'HKCU:\Software\LifeAI\ShellCommands\BuildCorpusToMarkdown',
        'HKCU:\Software\LifeAI\ShellCommands\BuildCorpusToWord',
        'HKCU:\Software\LifeAI\ShellCommands\UploadToRegenMedia'
    )

    foreach ($key in $legacyKeys) {
        if (Test-Path $key) {
            Remove-Item -LiteralPath $key -Recurse -Force
        }
    }
}

function Get-MsBuildPath {
    $candidates = @(
        'C:\Program Files\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\MSBuild.exe',
        'C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe'
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }
    throw 'MSBuild.exe was not found.'
}

function Get-VcVarsPath {
    $candidates = @(
        'C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat',
        'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat'
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }
    throw 'vcvars64.bat was not found.'
}

function Get-MakeAppxPath {
    $paths = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter makeappx.exe -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending
    if ($paths.Count -gt 0) {
        return $paths[0].FullName
    }
    throw 'makeappx.exe was not found.'
}

function Get-SignToolPath {
    $paths = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending
    if ($paths.Count -gt 0) {
        return $paths[0].FullName
    }
    throw 'signtool.exe was not found.'
}

function Ensure-LifeAICodeSigningCert {
    $subject = Get-LifeAIShellPublisher
    $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $subject } | Sort-Object NotAfter -Descending | Select-Object -First 1
    if (-not $cert) {
        $cert = New-SelfSignedCertificate `
            -Type CodeSigningCert `
            -Subject $subject `
            -CertStoreLocation 'Cert:\CurrentUser\My' `
            -KeyExportPolicy Exportable `
            -HashAlgorithm 'SHA256'
    }

    $tempCer = Join-Path $env:TEMP 'lifeai-shell-cert.cer'
    Export-Certificate -Cert $cert -FilePath $tempCer -Force | Out-Null
    Import-Certificate -FilePath $tempCer -CertStoreLocation 'Cert:\CurrentUser\TrustedPeople' | Out-Null
    Import-Certificate -FilePath $tempCer -CertStoreLocation 'Cert:\CurrentUser\Root' | Out-Null
    try { [System.IO.File]::Delete($tempCer) } catch {}
    return $cert
}

function Invoke-LifeAIMSBuild {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Project
    )

    $msbuild = Get-MsBuildPath
    $vcvars = Get-VcVarsPath
    $escapedVcVars = $vcvars.Replace('"', '""')
    $escapedMsBuild = $msbuild.Replace('"', '""')
    $escapedProject = $Project.Replace('"', '""')
    $cmd = "call ""$escapedVcVars"" && ""$escapedMsBuild"" ""$escapedProject"" /t:Build /p:Configuration=Release /p:Platform=x64 /nologo /verbosity:minimal"
    cmd /c $cmd
    if ($LASTEXITCODE -ne 0) {
        throw "MSBuild failed for $Project"
    }
}

function Install-LifeAISparsePackage {
    $projectRoot = Get-LifeAIShellProjectRoot
    $binRoot = Get-LifeAIShellBinRoot
    $packageRoot = Join-Path $projectRoot 'package'
    $stageRoot = Join-Path $projectRoot 'stage'
    $stagePackageRoot = Join-Path $stageRoot 'package'
    $msixPath = Join-Path $stageRoot 'LifeAI.Shell.msix'

    Invoke-LifeAIMSBuild -Project (Join-Path $projectRoot 'LifeAIContextMenu\LifeAIContextMenu.vcxproj')
    Invoke-LifeAIMSBuild -Project (Join-Path $projectRoot 'LifeAIShellHost\LifeAIShellHost.vcxproj')

    New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
    Copy-Item -Force (Join-Path $packageRoot 'resources.pri') (Join-Path $binRoot 'resources.pri')
    if (Test-Path (Join-Path $binRoot 'Assets')) {
        Remove-Item -LiteralPath (Join-Path $binRoot 'Assets') -Recurse -Force
    }
    Copy-Item -Recurse -Force (Join-Path $packageRoot 'Assets') (Join-Path $binRoot 'Assets')

    if (Test-Path $stageRoot) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $stagePackageRoot | Out-Null
    Copy-Item -Force (Join-Path $packageRoot 'AppxManifest.xml') (Join-Path $stagePackageRoot 'AppxManifest.xml')
    Copy-Item -Force (Join-Path $packageRoot 'resources.pri') (Join-Path $stagePackageRoot 'resources.pri')
    Copy-Item -Recurse -Force (Join-Path $packageRoot 'Assets') (Join-Path $stagePackageRoot 'Assets')

    $makeappx = Get-MakeAppxPath
    & $makeappx pack /d $stagePackageRoot /p $msixPath /nv
    if ($LASTEXITCODE -ne 0) {
        throw 'makeappx pack failed.'
    }

    $cert = Ensure-LifeAICodeSigningCert
    $signtool = Get-SignToolPath
    & $signtool sign /sha1 $cert.Thumbprint /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 $msixPath
    if ($LASTEXITCODE -ne 0) {
        throw 'signtool sign failed.'
    }

    $packageName = Get-LifeAIShellPackageName
    Get-AppxPackage -Name $packageName -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction SilentlyContinue
    Add-AppxPackage -Path $msixPath -ExternalLocation $binRoot
    Remove-LegacyLifeAIRegistryMenus
}

function Uninstall-LifeAISparsePackage {
    $packageName = Get-LifeAIShellPackageName
    Get-AppxPackage -Name $packageName -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction SilentlyContinue
    Remove-LegacyLifeAIRegistryMenus
}

function Restart-LifeAIExplorer {
    Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Process explorer.exe
}
