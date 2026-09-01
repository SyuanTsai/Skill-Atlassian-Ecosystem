#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BaseUrl,
    [Parameter(Mandatory = $true)]
    [string]$Email,
    [ValidateSet('Process','User')]
    [string]$TargetScope = 'Process',
    [switch]$PersistTokenToUser,
    [switch]$TestConnection,
    [string]$OutOfScopeReadPath,
    [scriptblock]$EnvironmentWriter,
    [scriptblock]$TokenReader,
    [scriptblock]$PlatformDetector,
    [scriptblock]$TenantInfoReader,
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
if ($null -eq $TenantInfoReader) {
    $TenantInfoReader = {
        param([Uri]$Uri)
        Invoke-RestMethod -Method Get -Uri $Uri -Headers @{ Accept = 'application/json' } -TimeoutSec 30
    }
}
if ($null -eq $ValidatorInvoker) {
    $ValidatorInvoker = { param([string]$Path, [hashtable]$Arguments) & $Path @Arguments }
}

function Test-ConfluenceSiteBase {
    param([string]$Value)

    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) { return $false }
    return $uri.Scheme -ceq 'https' `
        -and $uri.DnsSafeHost -like '*.atlassian.net' `
        -and $uri.IsDefaultPort `
        -and [string]::IsNullOrEmpty($uri.AbsolutePath.TrimEnd('/')) `
        -and [string]::IsNullOrEmpty($uri.UserInfo) `
        -and [string]::IsNullOrEmpty($uri.Query) `
        -and [string]::IsNullOrEmpty($uri.Fragment)
}

function Test-EmailShape {
    param([string]$Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[^@\s]+@[^@\s]+\.[^@\s]+$'
}

$runningOnWindows = [bool](& $PlatformDetector)
if ($TargetScope -ceq 'User' -and -not $runningOnWindows) {
    throw 'User-scope persistence in this Fast Path is supported on Windows only. Use Process scope or an approved secret-store launcher on this host.'
}
if (-not (Test-ConfluenceSiteBase $BaseUrl)) { throw 'CONFLUENCE_BASE_URL must be a canonical https://<site>.atlassian.net root URL.' }
if (-not (Test-EmailShape $Email)) { throw 'CONFLUENCE_EMAIL is not a valid email-shaped value.' }
if ($PersistTokenToUser -and $TargetScope -cne 'User') { throw '-PersistTokenToUser requires -TargetScope User.' }

$normalizedBaseUrl = $BaseUrl.TrimEnd('/')
$tenantInfoUri = "${normalizedBaseUrl}/_edge/tenant_info"
$tenantResponse = & $TenantInfoReader ([Uri]$tenantInfoUri)
$cloudId = [string]$tenantResponse.cloudId
$parsedCloudId = [Guid]::Empty
if (-not [Guid]::TryParse($cloudId, [ref]$parsedCloudId) -or $parsedCloudId -eq [Guid]::Empty) {
    throw 'Confluence tenant_info did not return a valid Cloud ID.'
}
$apiBaseUrl = "https://api.atlassian.com/ex/confluence/$cloudId"

$nonSecretSettings = [ordered]@{
    CONFLUENCE_BASE_URL = $normalizedBaseUrl
    CONFLUENCE_EMAIL = $Email
    CONFLUENCE_CLOUD_ID = $cloudId
    CONFLUENCE_API_BASE_URL = $apiBaseUrl
}
foreach ($setting in $nonSecretSettings.GetEnumerator()) {
    & $EnvironmentWriter $setting.Key $setting.Value 'Process'
    if ($TargetScope -ceq 'User') { & $EnvironmentWriter $setting.Key $setting.Value 'User' }
}

$secureToken = & $TokenReader 'Confluence API token'
if ($secureToken -isnot [Security.SecureString]) { throw 'The token reader must return a SecureString.' }
$tokenPointer = [IntPtr]::Zero
$plainToken = $null
try {
    $tokenPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPointer)
    if ([string]::IsNullOrWhiteSpace($plainToken)) { throw 'Confluence API token cannot be empty.' }

    & $EnvironmentWriter 'CONFLUENCE_API_TOKEN' $plainToken 'Process'
    if ($TargetScope -ceq 'User' -and $PersistTokenToUser) {
        & $EnvironmentWriter 'CONFLUENCE_API_TOKEN' $plainToken 'User'
    }
}
finally {
    if ($tokenPointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPointer) }
    $plainToken = $null
    if ($null -ne $secureToken) { $secureToken.Dispose() }
}

$validatorPath = Join-Path $PSScriptRoot 'Test-ConfluenceApiAccess.ps1'
if (-not (Test-Path -LiteralPath $validatorPath -PathType Leaf)) { throw 'Test-ConfluenceApiAccess.ps1 is missing from the Skill scripts directory.' }

$validationArgs = @{}
if ($TestConnection) { $validationArgs.TestConnection = $true }
if (-not [string]::IsNullOrWhiteSpace($OutOfScopeReadPath)) { $validationArgs.OutOfScopeReadPath = $OutOfScopeReadPath }
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
    Product = 'Confluence Cloud'
    TargetScope = $TargetScope
    NonSecretSettingsPersisted = ($TargetScope -ceq 'User')
    TokenPersistedToUser = [bool]$PersistTokenToUser
    CloudIdDiscovered = $true
    ApiBaseDerived = $true
    CurrentProcessConfigured = $true
    Validation = $validationResult
    HostReloadRequired = $hostReloadRequired
    HostReloadContract = $hostReloadContract
    SecretsRedacted = $true
}
