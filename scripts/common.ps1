Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-AndroidSdkEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $sdkCandidates = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $localProperties = Join-Path $RepositoryRoot 'sender_flutter\android\local.properties'
    if (Test-Path -LiteralPath $localProperties) {
        $sdkProperty = Get-Content -LiteralPath $localProperties |
            Where-Object { $_ -match '^sdk\.dir\s*=' } |
            Select-Object -First 1
        if ($null -ne $sdkProperty) {
            $sdkPath = ($sdkProperty -replace '^sdk\.dir\s*=\s*', '').Trim().Replace('\\', '\')
            if (-not [string]::IsNullOrWhiteSpace($sdkPath)) {
                $sdkCandidates += $sdkPath
            }
        }
    }

    foreach ($sdkCandidate in $sdkCandidates) {
        if (
            (Test-Path -LiteralPath (Join-Path $sdkCandidate 'platforms')) -and
            (Test-Path -LiteralPath (Join-Path $sdkCandidate 'build-tools'))
        ) {
            $resolvedSdk = (Resolve-Path -LiteralPath $sdkCandidate).Path
            $env:ANDROID_HOME = $resolvedSdk
            $env:ANDROID_SDK_ROOT = $resolvedSdk
            return
        }
    }

    throw 'Android SDK was not found. Set ANDROID_HOME or ANDROID_SDK_ROOT.'
}

function Invoke-ProjectProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 7200)]
        [int]$TimeoutSeconds
    )

    $resolvedCommand = (Get-Command -Name $Command -ErrorAction Stop).Source
    Write-Host "[$Command] $($Arguments -join ' ')"
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $commandExtension = [System.IO.Path]::GetExtension($resolvedCommand)
    if ($commandExtension -in @('.bat', '.cmd')) {
        $startInfo.FileName = $env:ComSpec
        foreach ($launcherArgument in @('/d', '/s', '/c', 'call', $resolvedCommand)) {
            [void]$startInfo.ArgumentList.Add($launcherArgument)
        }
    }
    else {
        $startInfo.FileName = $resolvedCommand
    }
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) {
        throw "Unable to start $Command."
    }
    $exitCode = $null
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "$Command exceeded the $TimeoutSeconds second timeout."
        }
        $exitCode = $process.ExitCode
    }
    finally {
        if (-not $process.HasExited) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        $process.Dispose()
    }
    if ($exitCode -ne 0) {
        throw "$Command exited with code $exitCode."
    }
}
