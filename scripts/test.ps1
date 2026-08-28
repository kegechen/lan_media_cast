param(
    [ValidateSet('all', 'sender', 'receiver')]
    [string]$Target = 'all',

    [switch]$ConnectedReceiver,

    [string]$DeviceSerial
)

. (Join-Path $PSScriptRoot 'common.ps1')
$repositoryRoot = Split-Path -Parent $PSScriptRoot

if ($Target -in @('all', 'receiver')) {
    Initialize-AndroidSdkEnvironment -RepositoryRoot $repositoryRoot
}

function Resolve-AdbCommand {
    $adbCommand = Get-Command -Name 'adb' -ErrorAction SilentlyContinue
    if ($null -ne $adbCommand) {
        return $adbCommand.Source
    }
    $sdkRoots = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($sdkRoot in $sdkRoots) {
        $candidate = Join-Path $sdkRoot 'platform-tools\adb.exe'
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw 'adb was not found. Set ANDROID_HOME or ANDROID_SDK_ROOT.'
}

function Resolve-DeviceSerial {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AdbCommand,

        [string]$RequestedSerial
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedSerial)) {
        $deviceState = & $AdbCommand -s $RequestedSerial get-state 2>$null
        if ($LASTEXITCODE -ne 0 -or ([string]::Join('', $deviceState)).Trim() -ne 'device') {
            throw "Android device '$RequestedSerial' is not connected and authorized."
        }
        return $RequestedSerial
    }

    $deviceLines = & $AdbCommand devices
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to list Android devices.'
    }
    $serials = @()
    foreach ($line in $deviceLines) {
        $match = [regex]::Match($line, '^(\S+)\s+device(?:\s|$)')
        if ($match.Success) {
            $serials += $match.Groups[1].Value
        }
    }
    if ($serials.Count -ne 1) {
        throw "Expected exactly one authorized Android device, found $($serials.Count). Use -DeviceSerial when needed."
    }
    return $serials[0]
}

function Invoke-AndroidInstrumentation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AdbCommand,

        [Parameter(Mandatory = $true)]
        [string]$Serial
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $AdbCommand
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
        '-s',
        $Serial,
        'shell',
        'am',
        'instrument',
        '-w',
        '-r',
        'com.iflytek.lanmediacast.receiver.device_test.test/androidx.test.runner.AndroidJUnitRunner'
    )) {
        $startInfo.ArgumentList.Add($argument)
    }

    $instrumentation = [System.Diagnostics.Process]::new()
    $instrumentation.StartInfo = $startInfo
    try {
        if (-not $instrumentation.Start()) {
            throw 'Unable to start Android instrumentation.'
        }
        $standardOutputTask = $instrumentation.StandardOutput.ReadToEndAsync()
        $standardErrorTask = $instrumentation.StandardError.ReadToEndAsync()
        if (-not $instrumentation.WaitForExit(60000)) {
            $instrumentation.Kill($true)
            throw 'Android instrumentation exceeded the 60 second timeout.'
        }
        $standardOutput = $standardOutputTask.GetAwaiter().GetResult()
        $standardError = $standardErrorTask.GetAwaiter().GetResult()
        Write-Host $standardOutput
        if (-not [string]::IsNullOrWhiteSpace($standardError)) {
            Write-Host $standardError
        }
        $combinedOutput = "$standardOutput`n$standardError"
        if (
            $instrumentation.ExitCode -ne 0 -or
            $combinedOutput -match 'FAILURES!!!|INSTRUMENTATION_FAILED|Process crashed' -or
            $combinedOutput -notmatch '(?m)^OK \(\d+ tests?\)'
        ) {
            throw "Android instrumentation failed with code $($instrumentation.ExitCode)."
        }
    }
    finally {
        $instrumentation.Dispose()
    }
}

function Install-ApkIfChanged {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AdbCommand,

        [Parameter(Mandatory = $true)]
        [string]$Serial,

        [Parameter(Mandatory = $true)]
        [string]$PackageName,

        [Parameter(Mandatory = $true)]
        [string]$ApkPath,

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory
    )

    $localHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ApkPath).Hash
    $packagePathLines = & $AdbCommand -s $Serial shell pm path $PackageName 2>$null
    $packagePaths = @(
        @($packagePathLines) |
            Where-Object { $null -ne $_ } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '^package:' }
    )
    $remotePath = if ($packagePaths.Count -gt 0) {
        $packagePaths[0] -replace '^package:', ''
    }
    else {
        ''
    }
    $remoteHash = ''
    if (-not [string]::IsNullOrWhiteSpace($remotePath)) {
        $hashCommands = @(
            @('sha256sum', $remotePath),
            @('toybox', 'sha256sum', $remotePath)
        )
        foreach ($hashArguments in $hashCommands) {
            $remoteHashLine = [string]::Join('', (& $AdbCommand -s $Serial shell @hashArguments 2>$null))
            $hashMatch = [regex]::Match($remoteHashLine, '^([0-9a-fA-F]{64})')
            if ($hashMatch.Success) {
                $remoteHash = $hashMatch.Groups[1].Value
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($remoteHash)) {
            Write-Warning "[$PackageName] unable to hash the installed base APK; reinstalling explicitly."
        }
    }
    else {
        Write-Host "[$PackageName] package is not installed; installing."
    }
    if ($localHash.Equals($remoteHash, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "[$PackageName] installed APK is unchanged; skipping install."
        return
    }

    Invoke-ProjectProcess `
        -Command $AdbCommand `
        -Arguments @('-s', $Serial, 'install', '-r', '-t', $ApkPath) `
        -WorkingDirectory $WorkingDirectory `
        -TimeoutSeconds 120
}

if ($Target -in @('all', 'sender')) {
    Invoke-ProjectProcess `
        -Command 'flutter' `
        -Arguments @('test') `
        -WorkingDirectory (Join-Path $repositoryRoot 'sender_flutter') `
        -TimeoutSeconds 1200
}

if ($Target -in @('all', 'receiver')) {
    $receiverTasks = @('--no-daemon', 'testDebugUnitTest')
    $timeoutSeconds = 1200
    if ($ConnectedReceiver) {
        $receiverTasks += @('assembleDeviceTest', 'assembleDeviceTestAndroidTest')
        $timeoutSeconds = 1800
    }
    Invoke-ProjectProcess `
        -Command (Join-Path $repositoryRoot 'receiver_android\gradlew.bat') `
        -Arguments $receiverTasks `
        -WorkingDirectory (Join-Path $repositoryRoot 'receiver_android') `
        -TimeoutSeconds $timeoutSeconds

    if ($ConnectedReceiver) {
        $adbCommand = Resolve-AdbCommand
        $resolvedSerial = Resolve-DeviceSerial -AdbCommand $adbCommand -RequestedSerial $DeviceSerial
        $receiverDirectory = Join-Path $repositoryRoot 'receiver_android'
        Install-ApkIfChanged `
            -AdbCommand $adbCommand `
            -Serial $resolvedSerial `
            -PackageName 'com.iflytek.lanmediacast.receiver.device_test' `
            -ApkPath (Join-Path $receiverDirectory 'app\build\outputs\apk\deviceTest\app-deviceTest.apk') `
            -WorkingDirectory $receiverDirectory
        Install-ApkIfChanged `
            -AdbCommand $adbCommand `
            -Serial $resolvedSerial `
            -PackageName 'com.iflytek.lanmediacast.receiver.device_test.test' `
            -ApkPath (Join-Path $receiverDirectory 'app\build\outputs\apk\androidTest\deviceTest\app-deviceTest-androidTest.apk') `
            -WorkingDirectory $receiverDirectory
        Invoke-AndroidInstrumentation -AdbCommand $adbCommand -Serial $resolvedSerial
    }
}
