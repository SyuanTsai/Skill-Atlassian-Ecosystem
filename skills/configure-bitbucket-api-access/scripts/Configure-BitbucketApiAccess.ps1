# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ApiBaseUrl = ([System.UriBuilder]::new('https', 'api.bitbucket.org', -1, '/2.0')).Uri.AbsoluteUri.TrimEnd('/'),
    [Parameter(Mandatory = $true)]
    [string]$Email,
    [Parameter(Mandatory = $true)]
    [string]$Workspace,
    [ValidateSet('Process','User')]
    [string]$TargetScope = 'Process',
    [switch]$PersistTokenToUser,
    [switch]$TestConnection,
    [string]$RepositorySlug,
    [int]$PullRequestId,
    [scriptblock]$EnvironmentWriter,
    [scriptblock]$TokenReader,
    [scriptblock]$PlatformDetector,
    [scriptblock]$ValidatorInvoker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($null -eq $EnvironmentWriter) {
    $EnvironmentWriter = {
        param([string]$Name, [string]$Value, [string]$Scope)
        $target = switch ($Scope) {
            'Process' { [EnvironmentVariableTarget]::Process }
            'User' { [EnvironmentVariableTarget]::User }
            default { throw "Unsupported environment target scope: $Scope" }
        }
        [Environment]::SetEnvironmentVariable($Name, $Value, $target)
    }
}
if ($null -eq $TokenReader) {
    $TokenReader = { param([string]$Prompt) Read-Host $Prompt -AsSecureString }
}
if ($null -eq $PlatformDetector) {
    $PlatformDetector = { [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT }
}
if ($null -eq $ValidatorInvoker) {
    $ValidatorInvoker = { param([string]$Path, [hashtable]$Arguments) & $Path @Arguments }
}

function Test-BitbucketApiBase {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $expectedScheme = 'https'
    $expectedHost = 'api.bitbucket.org'
    $expectedPath = '/2.0'
    $canonicalBuilder = [System.UriBuilder]::new()
    $canonicalBuilder.Scheme = $expectedScheme
    $canonicalBuilder.Host = $expectedHost
    $canonicalBuilder.Port = -1
    $canonicalBuilder.Path = $expectedPath
    $canonical = $canonicalBuilder.Uri.AbsoluteUri.TrimEnd('/')
    $normalizedValue = $Value.TrimEnd('/')

    $uri = $null
    if (-not [Uri]::TryCreate($normalizedValue, [UriKind]::Absolute, [ref]$uri)) { return $false }
    if ($uri.Scheme -cne $expectedScheme) { return $false }
    if ($uri.Host -cne $expectedHost) { return $false }
    if ($uri.AbsolutePath -cne $expectedPath) { return $false }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) { return $false }
    if ($uri.Port -ne 443) { return $false }
    if (-not [string]::IsNullOrEmpty($uri.Query)) { return $false }
    if (-not [string]::IsNullOrEmpty($uri.Fragment)) { return $false }
    $authorityStart = $normalizedValue.IndexOf('://', [StringComparison]::Ordinal) + 3
    $authorityEnd = $normalizedValue.IndexOf('/', $authorityStart)
    if ($authorityStart -lt 3 -or $authorityEnd -lt $authorityStart) { return $false }
    if ($normalizedValue.Substring($authorityStart, $authorityEnd - $authorityStart) -cne $expectedHost) { return $false }
    return $normalizedValue -ceq $canonical
}

function Test-EmailShape {
    param([string]$Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[^@\s]+@[^@\s]+\.[^@\s]+$'
}

function Test-WorkspaceShape {
    param([string]$Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[A-Za-z0-9][A-Za-z0-9_-]*$'
}

$runningOnWindows = [bool](& $PlatformDetector)
if ($TargetScope -ceq 'User' -and -not $runningOnWindows) {
    throw 'User-scope persistence in this Fast Path is supported on Windows only. Use Process scope or an approved secret-store launcher on this host.'
}
if (-not (Test-BitbucketApiBase $ApiBaseUrl)) { throw 'BITBUCKET_API_BASE_URL must use scheme https, host api.bitbucket.org, and path /2.0, with no embedded credentials, explicit port, query, or fragment.' }
if (-not (Test-EmailShape $Email)) { throw 'BITBUCKET_EMAIL is not a valid email-shaped value.' }
if (-not (Test-WorkspaceShape $Workspace)) { throw 'BITBUCKET_WORKSPACE is not a valid workspace slug.' }
if ($PersistTokenToUser -and $TargetScope -cne 'User') { throw '-PersistTokenToUser requires -TargetScope User.' }
if (($PullRequestId -gt 0) -xor (-not [string]::IsNullOrWhiteSpace($RepositorySlug))) {
    throw '-RepositorySlug and -PullRequestId must be supplied together.'
}

$normalizedApiBase = $ApiBaseUrl.TrimEnd('/')
$nonSecretSettings = [ordered]@{
    BITBUCKET_API_BASE_URL = $normalizedApiBase
    BITBUCKET_EMAIL = $Email
    BITBUCKET_WORKSPACE = $Workspace
}
foreach ($setting in $nonSecretSettings.GetEnumerator()) {
    & $EnvironmentWriter $setting.Key $setting.Value 'Process'
    if ($TargetScope -ceq 'User') { & $EnvironmentWriter $setting.Key $setting.Value 'User' }
}

$secureToken = & $TokenReader 'Bitbucket API token'
if ($secureToken -isnot [Security.SecureString]) { throw 'The token reader must return a SecureString.' }
$tokenPointer = [IntPtr]::Zero
$plainToken = $null
try {
    $tokenPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPointer)
    if ([string]::IsNullOrWhiteSpace($plainToken)) { throw 'Bitbucket API token cannot be empty.' }

    & $EnvironmentWriter 'BITBUCKET_API_TOKEN' $plainToken 'Process'
    if ($TargetScope -ceq 'User' -and $PersistTokenToUser) {
        & $EnvironmentWriter 'BITBUCKET_API_TOKEN' $plainToken 'User'
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
$validationResult = & $ValidatorInvoker $validatorPath $validationArgs
$hostReloadRequired = $TargetScope -ceq 'User'
$hostReloadContract = [pscustomobject]@{
    ContractVersion = 1
    Required = $hostReloadRequired
    Reason = if ($hostReloadRequired) { 'user-scope-updated' } else { 'process-only-update' }
    RequiredAction = if ($hostReloadRequired) { 'recreate-host-process' } else { 'none' }
    ParentProcessMutationSupported = $false
    SecretInjectionRequired = $hostReloadRequired -and -not $PersistTokenToUser
    SecretSourceRequired = if ($hostReloadRequired -and -not $PersistTokenToUser) { 'approved-secret-store-or-hidden-input' } else { 'none' }
    VerificationAction = 'rerun-validator'
}

[pscustomobject]@{
    Product = 'Bitbucket Cloud'
    TargetScope = $TargetScope
    NonSecretSettingsPersisted = ($TargetScope -ceq 'User')
    TokenPersistedToUser = [bool]$PersistTokenToUser
    CurrentProcessConfigured = $true
    Validation = $validationResult
    HostReloadRequired = $hostReloadRequired
    HostReloadContract = $hostReloadContract
    SecretsRedacted = $true
}
