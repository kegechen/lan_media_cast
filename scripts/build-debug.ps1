param(
    [ValidateSet('all', 'sender', 'receiver')]
    [string]$Target = 'all',

    [switch]$DisableKotlinIncremental
)

. (Join-Path $PSScriptRoot 'common.ps1')
$repositoryRoot = Split-Path -Parent $PSScriptRoot

Initialize-AndroidSdkEnvironment -RepositoryRoot $repositoryRoot

if ($Target -in @('all', 'receiver')) {
    Invoke-ProjectProcess `
        -Command (Join-Path $repositoryRoot 'receiver_android\gradlew.bat') `
        -Arguments @('--no-daemon', 'assembleDebug') `
        -WorkingDirectory (Join-Path $repositoryRoot 'receiver_android') `
        -TimeoutSeconds 1800
}

if ($Target -in @('all', 'sender')) {
    $senderDirectory = Join-Path $repositoryRoot 'sender_flutter'
    $previousGradleOptions = $env:GRADLE_OPTS
    $previousIncremental = [Environment]::GetEnvironmentVariable(
        'ORG_GRADLE_PROJECT_kotlin.incremental',
        'Process'
    )
    $previousCompilerStrategy = [Environment]::GetEnvironmentVariable(
        'ORG_GRADLE_PROJECT_kotlin.compiler.execution.strategy',
        'Process'
    )
    try {
        if ($DisableKotlinIncremental) {
            $fallbackOptions = '-Dkotlin.incremental=false -Dkotlin.compiler.execution.strategy=in-process'
            $env:GRADLE_OPTS = if ([string]::IsNullOrWhiteSpace($previousGradleOptions)) {
                $fallbackOptions
            }
            else {
                "$previousGradleOptions $fallbackOptions"
            }
            [Environment]::SetEnvironmentVariable(
                'ORG_GRADLE_PROJECT_kotlin.incremental',
                'false',
                'Process'
            )
            [Environment]::SetEnvironmentVariable(
                'ORG_GRADLE_PROJECT_kotlin.compiler.execution.strategy',
                'in-process',
                'Process'
            )
        }
        Invoke-ProjectProcess `
            -Command 'flutter' `
            -Arguments @('build', 'apk', '--debug') `
            -WorkingDirectory $senderDirectory `
            -TimeoutSeconds 1800
    }
    finally {
        $env:GRADLE_OPTS = $previousGradleOptions
        [Environment]::SetEnvironmentVariable(
            'ORG_GRADLE_PROJECT_kotlin.incremental',
            $previousIncremental,
            'Process'
        )
        [Environment]::SetEnvironmentVariable(
            'ORG_GRADLE_PROJECT_kotlin.compiler.execution.strategy',
            $previousCompilerStrategy,
            'Process'
        )
    }
    Invoke-ProjectProcess `
        -Command 'flutter' `
        -Arguments @('build', 'windows', '--debug') `
        -WorkingDirectory $senderDirectory `
        -TimeoutSeconds 2400
}
