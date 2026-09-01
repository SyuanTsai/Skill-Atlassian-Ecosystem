#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ApiBaseUrl = 'https://api.bitbucket.org/2.0',
    [Parameter(Mandatory = $true)]
    [string]$Email,
    [Parameter(Mandatory = $true)]
    [string]$Workspace,
    [ValidateSet('Process','User')]
    [string]$TargetScope = 'Process',
    [switch]$PersistTokenToUser,
    [switch]$TestConnection,
    [string]$RepositorySlug,
    [int]$PullRequestId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-BitbucketApiBase {
    param([string]$Value)

    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) { return $false }
    return $uri.Scheme -ceq 'https' `
        -and $uri.DnsSafeHost -ceq 'api.bitbucket.org' `
        -and $uri.AbsolutePath.TrimEnd('/') -ceq '/2.0' `
        -and [string]::IsNullOrEmpty($uri.UserInfo) `
        -and [string]::IsNullOrEmpty($uri.Query) `
        -and [string]::IsNullOrEmpty($uri.Fragment)
}

function Test-EmailShape {
    param([string]$Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[^@\s]+@[^@\s]+\.[^@\s]+$'
}

function Test-WorkspaceShape {
    param([string]$Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[A-Za-z0-9][A-Za-z0-9_-]*$'
}

$runningOnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if ($TargetScope -ceq 'User' -and -not $runningOnWindows) {
    throw 'User-scope persistence in this Fast Path is supported on Windows only. Use Process scope or an approved secret-store launcher on this host.'
}
if (-not (Test-BitbucketApiBase $ApiBaseUrl)) { throw 'BITBUCKET_API_BASE_URL must be https://api.bitbucket.org/2.0.' }
if (-not (Test-EmailShape $Email)) { throw 'BITBUCKET_EMAIL is not a valid email-shaped value.' }
if (-not (Test-WorkspaceShape $Workspace)) { throw 'BITBUCKET_WORKSPACE is not a valid workspace slug.' }
if ($PersistTokenToUser -and $TargetScope -cne 'User') { throw '-PersistTokenToUser requires -TargetScope User.' }
if (($PullRequestId -gt 0) -xor (-not [string]::IsNullOrWhiteSpace($RepositorySlug))) {
    throw '-RepositorySlug and -PullRequestId must be supplied together.'
}

$normalizedApiBase = $ApiBaseUrl.TrimEnd('/')
$target = if ($TargetScope -ceq 'User') { [EnvironmentVariableTarget]::User } else { [EnvironmentVariableTarget]::Process }
[Environment]::SetEnvironmentVariable('BITBUCKET_API_BASE_URL', $normalizedApiBase, $target)
[Environment]::SetEnvironmentVariable('BITBUCKET_EMAIL', $Email, $target)
[Environment]::SetEnvironmentVariable('BITBUCKET_WORKSPACE', $Workspace, $target)

$secureToken = Read-Host 'Bitbucket API token' -AsSecureString
$tokenPointer = [IntPtr]::Zero
$plainToken = $null
try {
    $tokenPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPointer)
    if ([string]::IsNullOrWhiteSpace($plainToken)) { throw 'Bitbucket API token cannot be empty.' }

    if ($TargetScope -ceq 'Process') {
        [Environment]::SetEnvironmentVariable('BITBUCKET_API_TOKEN', $plainToken, [EnvironmentVariableTarget]::Process)
    }
    elseif ($PersistTokenToUser) {
        [Environment]::SetEnvironmentVariable('BITBUCKET_API_TOKEN', $plainToken, [EnvironmentVariableTarget]::User)
    }
    else {
        [Environment]::SetEnvironmentVariable('BITBUCKET_API_TOKEN', $plainToken, [EnvironmentVariableTarget]::Process)
    }
}
finally {
    if ($tokenPointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPointer) }
    $plainToken = $null
    if ($null -ne $secureToken) { $secureToken.Dispose() }
}

$validatorPath = Join-Path $PSScriptRoot 'Test-BitbucketApiAccess.ps1'
if (-not (Test-Path -LiteralPath $validatorPath -PathType Leaf)) { throw 'Test-BitbucketApiAccess.ps1 is missing from the Skill scripts directory.' }

$validationArgs = @{}
if ($TestConnection) { $validationArgs.TestConnection = $true }
if (-not [string]::IsNullOrWhiteSpace($RepositorySlug)) {
    $validationArgs.RepositorySlug = $RepositorySlug
    $validationArgs.PullRequestId = $PullRequestId
}
$validationResult = & $validatorPath @validationArgs

[pscustomobject]@{
    Product = 'Bitbucket Cloud'
    TargetScope = $TargetScope
    NonSecretSettingsPersisted = ($TargetScope -ceq 'User')
    TokenPersistedToUser = [bool]$PersistTokenToUser
    Validation = $validationResult
    HostReloadRequired = ($TargetScope -ceq 'User')
    SecretsRedacted = $true
}
