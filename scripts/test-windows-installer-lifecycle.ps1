[CmdletBinding()]
param(
    [string]$InstallerPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')

$principal = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this lifecycle test from an elevated PowerShell terminal.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
    $versionLine = Get-Content -LiteralPath (Join-Path $repositoryRoot 'sender_flutter\pubspec.yaml') |
        Where-Object { $_ -match '^version:\s*' } |
        Select-Object -First 1
    if ($null -eq $versionLine -or $versionLine -notmatch '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)') {
        throw 'Could not read the sender version.'
    }
    $InstallerPath = Join-Path $repositoryRoot "dist\LANMediaCast-Sender-$($Matches[1])-Setup.exe"
}
$resolvedInstaller = (Resolve-Path -LiteralPath $InstallerPath).Path
$testTempRoot = [IO.Path]::GetTempPath()
if ($testTempRoot -match '\s') {
    $testTempRoot = Join-Path $env:SystemRoot 'Temp'
}
$resolvedTestTempRoot = (Resolve-Path -LiteralPath $testTempRoot -ErrorAction Stop).Path
if ($resolvedTestTempRoot -match '\s') {
    throw "NSIS /D= lifecycle tests require a temporary root without whitespace: $resolvedTestTempRoot"
}
$installRoot = Join-Path $resolvedTestTempRoot (
    'lan-media-cast-installer-test-' + [guid]::NewGuid().ToString('N')
)
$expectedTempRoot = [IO.Path]::GetFullPath($resolvedTestTempRoot)
$resolvedInstallRoot = [IO.Path]::GetFullPath($installRoot)
if (-not $resolvedInstallRoot.StartsWith($expectedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to use a lifecycle test directory outside the system temp root: $resolvedInstallRoot"
}

$uninstallRegistryPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\LANMediaCastSender'
$existingInstallLocation = (
    Get-ItemPropertyValue `
        -LiteralPath $uninstallRegistryPath `
        -Name 'InstallLocation' `
        -ErrorAction SilentlyContinue
)
if (
    -not [string]::IsNullOrWhiteSpace($existingInstallLocation)
) {
    throw "An existing LAN Media Cast installation record points to '$existingInstallLocation'. Run this lifecycle test on a clean test machine. If that path is under a temporary directory, it is probably left by an interrupted lifecycle test; run its uninstall.exe before retrying."
}

Write-Host "Lifecycle test install root: $resolvedInstallRoot"
Invoke-ProjectProcess `
    -Command $resolvedInstaller `
    -Arguments @('/S', "/D=$resolvedInstallRoot") `
    -WorkingDirectory $repositoryRoot `
    -TimeoutSeconds 180

$applicationPath = Join-Path $resolvedInstallRoot 'app\lan_media_cast_sender.exe'
if (-not (Test-Path -LiteralPath $applicationPath -PathType Leaf)) {
    throw "Fresh install did not create $applicationPath"
}

$staleMarker = Join-Path $resolvedInstallRoot 'app\upgrade-stale-marker.txt'
Set-Content -LiteralPath $staleMarker -Value 'must be removed by an upgrade' -Encoding utf8NoBOM
Invoke-ProjectProcess `
    -Command $resolvedInstaller `
    -Arguments @('/S') `
    -WorkingDirectory $repositoryRoot `
    -TimeoutSeconds 180
if (Test-Path -LiteralPath $staleMarker) {
    throw 'Upgrade did not replace the installer-owned app directory.'
}
if (-not (Test-Path -LiteralPath $applicationPath -PathType Leaf)) {
    throw 'Upgrade did not restore the application payload.'
}

$uninstallerPath = Join-Path $resolvedInstallRoot 'uninstall.exe'
Invoke-ProjectProcess `
    -Command $uninstallerPath `
    -Arguments @('/S') `
    -WorkingDirectory $repositoryRoot `
    -TimeoutSeconds 180

$deadline = [DateTime]::UtcNow.AddSeconds(15)
while ((Test-Path -LiteralPath $resolvedInstallRoot) -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 250
}
if (Test-Path -LiteralPath $resolvedInstallRoot) {
    $remaining = Get-ChildItem -LiteralPath $resolvedInstallRoot -Force |
        Select-Object -ExpandProperty FullName
    throw "Uninstall left files behind: $([string]::Join(', ', $remaining))"
}

Write-Host 'Windows installer fresh install, upgrade, and uninstall lifecycle passed.'
