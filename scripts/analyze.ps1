param(
    [ValidateSet('all', 'sender', 'receiver')]
    [string]$Target = 'all'
)

. (Join-Path $PSScriptRoot 'common.ps1')
$repositoryRoot = Split-Path -Parent $PSScriptRoot

if ($Target -in @('all', 'receiver')) {
    Initialize-AndroidSdkEnvironment -RepositoryRoot $repositoryRoot
}

if ($Target -in @('all', 'sender')) {
    Invoke-ProjectProcess `
        -Command 'flutter' `
        -Arguments @('analyze') `
        -WorkingDirectory (Join-Path $repositoryRoot 'sender_flutter') `
        -TimeoutSeconds 600
}

if ($Target -in @('all', 'receiver')) {
    Invoke-ProjectProcess `
        -Command (Join-Path $repositoryRoot 'receiver_android\gradlew.bat') `
        -Arguments @('--no-daemon', 'lintDebug') `
        -WorkingDirectory (Join-Path $repositoryRoot 'receiver_android') `
        -TimeoutSeconds 1200
}
