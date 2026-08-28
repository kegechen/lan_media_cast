[CmdletBinding()]
param(
    [switch]$SkipYtDlpDownload
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$senderDirectory = Join-Path $repositoryRoot 'sender_flutter'
$ytDlpPath = Join-Path $repositoryRoot 'tools\yt-dlp.exe'
$releaseDirectory = Join-Path $senderDirectory 'build\windows\x64\runner\Release'
$installerDirectory = Join-Path $repositoryRoot 'installer\windows'
$installerScript = Join-Path $installerDirectory 'sender.nsi'
$outputDirectory = Join-Path $repositoryRoot 'dist'

if (-not $SkipYtDlpDownload) {
    & (Join-Path $PSScriptRoot 'prepare-yt-dlp.ps1')
}
if (-not (Test-Path -LiteralPath $ytDlpPath)) {
    throw 'tools\yt-dlp.exe is missing. Run scripts\prepare-yt-dlp.ps1 first.'
}

Invoke-ProjectProcess `
    -Command 'flutter' `
    -Arguments @('build', 'windows', '--release') `
    -WorkingDirectory $senderDirectory `
    -TimeoutSeconds 2400

Copy-Item -LiteralPath $ytDlpPath -Destination (Join-Path $releaseDirectory 'yt-dlp.exe') -Force

$nsisCandidates = @()
$nsisOnPath = Get-Command -Name 'makensis' -ErrorAction SilentlyContinue
if ($null -ne $nsisOnPath) {
    $nsisCandidates += $nsisOnPath.Source
}
$nsisCandidates += @(
    'C:\Program Files (x86)\NSIS\makensis.exe',
    'C:\Program Files\NSIS\makensis.exe'
)
$nsisCandidates = $nsisCandidates |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) }
$makensis = $nsisCandidates | Select-Object -First 1
if ($null -eq $makensis) {
    throw 'NSIS 3 was not found. Install it with: winget install --id NSIS.NSIS'
}

$versionLine = Get-Content -LiteralPath (Join-Path $senderDirectory 'pubspec.yaml') |
    Where-Object { $_ -match '^version:\s*' } |
    Select-Object -First 1
if ($null -eq $versionLine -or $versionLine -notmatch '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)') {
    throw 'Could not read the application version from sender_flutter\pubspec.yaml.'
}
$appVersion = $Matches[1]
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

Invoke-ProjectProcess `
    -Command $makensis `
    -Arguments @('/V2', '/WX', "/DAPP_VERSION=$appVersion", $installerScript) `
    -WorkingDirectory $installerDirectory `
    -TimeoutSeconds 600

$installerPath = Join-Path $outputDirectory "LANMediaCast-Sender-$appVersion-Setup.exe"
if (-not (Test-Path -LiteralPath $installerPath)) {
    throw "NSIS completed without creating $installerPath"
}
Write-Host "Windows installer: $installerPath"
