[CmdletBinding()]
param(
    [string]$Tag
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot

function Read-ProjectText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    return Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot $RelativePath)
}

$pubspec = Read-ProjectText -RelativePath 'sender_flutter\pubspec.yaml'
$senderMatch = [regex]::Match(
    $pubspec,
    '(?m)^version:\s*(?<version>\d+\.\d+\.\d+)\+(?<code>\d+)\s*$'
)
if (-not $senderMatch.Success) {
    throw 'sender_flutter\pubspec.yaml does not contain a valid release version.'
}
$releaseVersion = $senderMatch.Groups['version'].Value
$senderVersionCode = [int]$senderMatch.Groups['code'].Value

$appVersionSource = Read-ProjectText -RelativePath 'sender_flutter\lib\app_version.dart'
$expectedSenderVersion = "const String senderAppVersion = '$releaseVersion+$senderVersionCode';"
if (-not $appVersionSource.Contains($expectedSenderVersion)) {
    throw 'sender_flutter app_version.dart does not match pubspec.yaml.'
}

$receiverBuild = Read-ProjectText -RelativePath 'receiver_android\app\build.gradle.kts'
$receiverNameMatch = [regex]::Match(
    $receiverBuild,
    '(?m)^\s*versionName\s*=\s*"(?<version>\d+\.\d+\.\d+)"\s*$'
)
$receiverCodeMatch = [regex]::Match(
    $receiverBuild,
    '(?m)^\s*versionCode\s*=\s*(?<code>\d+)\s*$'
)
if (-not $receiverNameMatch.Success -or -not $receiverCodeMatch.Success) {
    throw 'receiver_android build.gradle.kts does not contain a valid release version.'
}
if ($receiverNameMatch.Groups['version'].Value -ne $releaseVersion) {
    throw 'Receiver versionName does not match the sender release version.'
}
$receiverVersionCode = [int]$receiverCodeMatch.Groups['code'].Value

$installer = Read-ProjectText -RelativePath 'installer\windows\sender.nsi'
$escapedVersion = [regex]::Escape($releaseVersion)
if ($installer -notmatch "(?m)^!define APP_VERSION `"$escapedVersion`"$") {
    throw 'The NSIS default APP_VERSION does not match the release version.'
}

if (-not [string]::IsNullOrWhiteSpace($Tag)) {
    $expectedTag = "v$releaseVersion"
    if ($Tag -ne $expectedTag) {
        throw "Release tag '$Tag' does not match '$expectedTag'."
    }
}

[pscustomobject]@{
    Version = $releaseVersion
    SenderVersionCode = $senderVersionCode
    ReceiverVersionCode = $receiverVersionCode
    Tag = if ([string]::IsNullOrWhiteSpace($Tag)) { $null } else { $Tag }
} | ConvertTo-Json -Compress
