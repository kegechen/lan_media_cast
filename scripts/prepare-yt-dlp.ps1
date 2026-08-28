[CmdletBinding()]
param(
    [string]$Destination,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = Join-Path $repositoryRoot 'tools\yt-dlp.exe'
}

$ytDlpVersion = '2026.08.19'
$downloadUrl = "https://github.com/yt-dlp/yt-dlp/releases/download/$ytDlpVersion/yt-dlp.exe"
$expectedSha256 = '66674953fe251b89f4d08c5f0e35e0728679bd67ab3d7d05c0562af101dd3e7a'
$resolvedDestination = [System.IO.Path]::GetFullPath($Destination)
$destinationDirectory = Split-Path -Parent $resolvedDestination

New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null

if (Test-Path -LiteralPath $resolvedDestination) {
    $actualSha256 = (Get-FileHash -LiteralPath $resolvedDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -eq $expectedSha256) {
        Write-Host "yt-dlp $ytDlpVersion is ready: $resolvedDestination"
        return
    }
    if (-not $Force) {
        throw "Existing yt-dlp.exe failed SHA-256 verification. Re-run with -Force to preserve it as a backup and replace it."
    }
    $backup = "$resolvedDestination.invalid-$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
    Move-Item -LiteralPath $resolvedDestination -Destination $backup
    Write-Warning "The unverified file was preserved at $backup"
}

$temporary = "$resolvedDestination.download"
if (Test-Path -LiteralPath $temporary) {
    Remove-Item -LiteralPath $temporary -Force
}

try {
    Write-Host "Downloading yt-dlp $ytDlpVersion..."
    Invoke-WebRequest -Uri $downloadUrl -OutFile $temporary -TimeoutSec 120
    $actualSha256 = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $expectedSha256) {
        throw "Downloaded yt-dlp.exe SHA-256 mismatch. Expected $expectedSha256, got $actualSha256."
    }
    Move-Item -LiteralPath $temporary -Destination $resolvedDestination
    Unblock-File -LiteralPath $resolvedDestination
}
finally {
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Force
    }
}

Write-Host "yt-dlp $ytDlpVersion is ready: $resolvedDestination"
