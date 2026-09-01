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
    [switch]$TestConnection
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-JiraSiteUrl {
    param([string]$Value)
    try {
        $uri = [Uri]$Value
        return $uri.IsAbsoluteUri -and $uri.Scheme -ceq 'https' -and $uri.IsDefaultPort `
            -and -not $uri.UserInfo -and -not $uri.Query -and -not $uri.Fragment `
            -and $uri.AbsolutePath -ceq '/' `
            -and $uri.Host -match '^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.atlassian\.net$'
    }
    catch { return $false }
}

function Test-EmailShape {
    param([string]$Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[^\s@]+@[^\s@]+\.[^\s@]+$'
}

if (-not (Test-JiraSiteUrl $BaseUrl)) { throw 'JIRA_BASE_URL must be a canonical https://<site>.atlassian.net root URL.' }
if (-not (Test-EmailShape $Email)) { throw 'JIRA_EMAIL is not a valid email-shaped value.' }
if ($PersistTokenToUser -and $TargetScope -cne 'User') { throw '-PersistTokenToUser requires -TargetScope User.' }

$normalizedBaseUrl = $BaseUrl.TrimEnd('/')
$tenantInfoUri = "${normalizedBaseUrl}/_edge/tenant_info"
$tenantResponse = Invoke-RestMethod -Method Get -Uri $tenantInfoUri -Headers @{ Accept = 'application/json' } -TimeoutSec 30
$cloudId = [string]$tenantResponse.cloudId
$parsedCloudId = [Guid]::Empty
if (-not [Guid]::TryParse($cloudId, [ref]$parsedCloudId) -or $parsedCloudId -eq [Guid]::Empty) {
    throw 'Jira tenant_info did not return a valid Cloud ID.'
}
$apiBaseUrl = "https://api.atlassian.com/ex/jira/$cloudId"

$target = if ($TargetScope -ceq 'User') { [EnvironmentVariableTarget]::User } else { [EnvironmentVariableTarget]::Process }
[Environment]::SetEnvironmentVariable('JIRA_BASE_URL', $normalizedBaseUrl, $target)
[Environment]::SetEnvironmentVariable('JIRA_EMAIL', $Email, $target)
[Environment]::SetEnvironmentVariable('JIRA_CLOUD_ID', $cloudId, $target)
[Environment]::SetEnvironmentVariable('JIRA_API_BASE_URL', $apiBaseUrl, $target)

$secureToken = Read-Host 'Jira API token' -AsSecureString
$tokenPointer = [IntPtr]::Zero
$plainToken = $null
try {
    $tokenPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPointer)
    if ([string]::IsNullOrWhiteSpace($plainToken)) { throw 'Jira API token cannot be empty.' }

    if ($TargetScope -ceq 'Process') {
        [Environment]::SetEnvironmentVariable('JIRA_API_TOKEN', $plainToken, [EnvironmentVariableTarget]::Process)
    }
    elseif ($PersistTokenToUser) {
        [Environment]::SetEnvironmentVariable('JIRA_API_TOKEN', $plainToken, [EnvironmentVariableTarget]::User)
    }
    else {
        [Environment]::SetEnvironmentVariable('JIRA_API_TOKEN', $plainToken, [EnvironmentVariableTarget]::Process)
    }
}
finally {
    if ($tokenPointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPointer) }
    $plainToken = $null
    if ($null -ne $secureToken) { $secureToken.Dispose() }
}

$validatorPath = Join-Path $PSScriptRoot 'Test-JiraApiAccess.ps1'
if (-not (Test-Path -LiteralPath $validatorPath -PathType Leaf)) { throw 'Test-JiraApiAccess.ps1 is missing from the Skill scripts directory.' }

$validationResult = if ($TestConnection) { & $validatorPath -TestConnection } else { & $validatorPath }

[pscustomobject]@{
    Product = 'Jira Cloud'
    TargetScope = $TargetScope
    NonSecretSettingsPersisted = ($TargetScope -ceq 'User')
    TokenPersistedToUser = [bool]$PersistTokenToUser
    CloudIdDiscovered = $true
    ApiBaseDerived = $true
    Validation = $validationResult
    HostReloadRequired = ($TargetScope -ceq 'User')
    SecretsRedacted = $true
}
