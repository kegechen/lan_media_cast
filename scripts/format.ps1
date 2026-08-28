param(
    [ValidateSet('all', 'sender', 'receiver')]
    [string]$Target = 'all'
)

. (Join-Path $PSScriptRoot 'common.ps1')
$repositoryRoot = Split-Path -Parent $PSScriptRoot

if ($Target -in @('all', 'sender')) {
    Invoke-ProjectProcess `
        -Command 'dart' `
        -Arguments @('format', 'lib', 'test') `
        -WorkingDirectory (Join-Path $repositoryRoot 'sender_flutter') `
        -TimeoutSeconds 300
}

if ($Target -eq 'receiver') {
    Write-Host 'Receiver formatting is enforced by Kotlin style checks during lint.'
}
