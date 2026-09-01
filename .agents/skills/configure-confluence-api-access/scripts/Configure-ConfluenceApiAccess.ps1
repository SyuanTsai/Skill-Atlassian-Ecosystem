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
    [string]$OutOfScopeReadPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

$runningOnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if ($TargetScope -ceq 'User' -and -not $runningOnWindows) {
    throw 'User-scope persistence in this Fast Path is supported on Windows only. Use Process scope or an approved secret-store launcher on this host.'
}
if (-not (Test-ConfluenceSiteBase $BaseUrl)) { throw 'CONFLUENCE_BASE_URL must be a canonical https://<site>.atlassian.net root URL.' }
if (-not (Test-EmailShape $Email)) { throw 'CONFLUENCE_EMAIL is not a valid email-shaped value.' }
if ($PersistTokenToUser -and $TargetScope -cne 'User') { throw '-PersistTokenToUser requires -TargetScope User.' }

$normalizedBaseUrl = $BaseUrl.TrimEnd('/')
$tenantInfoUri = "${normalizedBaseUrl}/_edge/tenant_info"
$tenantResponse = Invoke-RestMethod -Method Get -Uri $tenantInfoUri -Headers @{ Accept = 'application/json' } -TimeoutSec 30
$cloudId = [string]$tenantResponse.cloudId
$parsedCloudId = [Guid]::Empty
if (-not [Guid]::TryParse($cloudId, [ref]$parsedCloudId) -or $parsedCloudId -eq [Guid]::Empty) {
    throw 'Confluence tenant_info did not return a valid Cloud ID.'
}
$apiBaseUrl = "https://api.atlassian.com/ex/confluence/$cloudId"

$target = if ($TargetScope -ceq 'User') { [EnvironmentVariableTarget]::User } else { [EnvironmentVariableTarget]::Process }
[Environment]::SetEnvironmentVariable('CONFLUENCE_BASE_URL', $normalizedBaseUrl, $target)
[Environment]::SetEnvironmentVariable('CONFLUENCE_EMAIL', $Email, $target)
[Environment]::SetEnvironmentVariable('CONFLUENCE_CLOUD_ID', $cloudId, $target)
[Environment]::SetEnvironmentVariable('CONFLUENCE_API_BASE_URL', $apiBaseUrl, $target)

$secureToken = Read-Host 'Confluence API token' -AsSecureString
$tokenPointer = [IntPtr]::Zero
$plainToken = $null
try {
    $tokenPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPointer)
    if ([string]::IsNullOrWhiteSpace($plainToken)) { throw 'Confluence API token cannot be empty.' }

    if ($TargetScope -ceq 'Process') {
        [Environment]::SetEnvironmentVariable('CONFLUENCE_API_TOKEN', $plainToken, [EnvironmentVariableTarget]::Process)
    }
    elseif ($PersistTokenToUser) {
        [Environment]::SetEnvironmentVariable('CONFLUENCE_API_TOKEN', $plainToken, [EnvironmentVariableTarget]::User)
    }
    else {
        [Environment]::SetEnvironmentVariable('CONFLUENCE_API_TOKEN', $plainToken, [EnvironmentVariableTarget]::Process)
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
$validationResult = & $validatorPath @validationArgs

[pscustomobject]@{
    Product = 'Confluence Cloud'
    TargetScope = $TargetScope
    NonSecretSettingsPersisted = ($TargetScope -ceq 'User')
    TokenPersistedToUser = [bool]$PersistTokenToUser
    CloudIdDiscovered = $true
    ApiBaseDerived = $true
    Validation = $validationResult
    HostReloadRequired = ($TargetScope -ceq 'User')
    SecretsRedacted = $true
}
