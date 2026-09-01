#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$TestConnection,
    [string]$IssueKey,
    [string]$Jql,
    [ValidateRange(1, 100)]
    [int]$MaxResults = 20,
    [scriptblock]$EnvironmentReader,
    [scriptblock]$HttpInvoker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requiredSettings = @(
    'JIRA_BASE_URL',
    'JIRA_EMAIL',
    'JIRA_API_TOKEN',
    'JIRA_CLOUD_ID',
    'JIRA_API_BASE_URL'
)

$classicRequiredScopes = @(
    'read:jira-user',
    'read:jira-work'
)

$granularIdentityScopes = @(
    'read:user:jira',
    'read:application-role:jira',
    'read:group:jira',
    'read:avatar:jira'
)

$granularQueryScopes = @(
    'read:issue-details:jira',
    'read:field.default-value:jira',
    'read:field.option:jira',
    'read:field:jira',
    'read:group:jira'
)

if (-not $EnvironmentReader) {
    $EnvironmentReader = {
        param([string]$Name, [string]$Scope)

        $runningOnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
        if (-not $runningOnWindows -and $Scope -cne 'Process') { return $null }
        $target = switch ($Scope) {
            'Process' { [EnvironmentVariableTarget]::Process }
            'User' { [EnvironmentVariableTarget]::User }
            'Machine' { [EnvironmentVariableTarget]::Machine }
            default { throw "Unsupported environment scope: $Scope" }
        }
        return [Environment]::GetEnvironmentVariable($Name, $target)
    }
}

if (-not $HttpInvoker) {
    $HttpInvoker = {
        param([string]$Uri, [hashtable]$Headers)

        $invokeParams = @{
            Uri         = $Uri
            Method      = 'GET'
            Headers     = $Headers
            ErrorAction = 'Stop'
            TimeoutSec  = 30
            UseBasicParsing = $true
        }

        if ($PSVersionTable.PSVersion.Major -ge 7) {
            $invokeParams.SkipHttpErrorCheck = $true
        }

        try {
            $response = Invoke-WebRequest @invokeParams
            return [pscustomobject]@{
                StatusCode = [int]$response.StatusCode
                Content    = [string]$response.Content
            }
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            if ($null -ne $statusCode) {
                return [pscustomobject]@{
                    StatusCode = $statusCode
                    Content    = ''
                }
            }

            throw
        }
    }
}

function Get-HttpCategory {
    param([Nullable[int]]$StatusCode)

    if ($null -eq $StatusCode) { return 'network-or-tls' }
    if ($StatusCode -eq 400) { return 'request-or-configuration' }
    if ($StatusCode -eq 401) { return 'authentication' }
    if ($StatusCode -eq 403) { return 'authorization-or-scope' }
    if ($StatusCode -eq 404) { return 'endpoint-or-resource-not-found' }
    if ($StatusCode -eq 429) { return 'rate-limited' }
    if ($StatusCode -ge 500) { return 'service-unavailable' }
    return 'unexpected-http-status'
}

function Invoke-ReadCheck {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [scriptblock]$Invoker
    )

    try {
        $response = & $Invoker $Uri $Headers
        $statusCode = [int]$response.StatusCode
        return [pscustomobject]@{
            StatusCode = $statusCode
            Success    = ($statusCode -eq 200)
            Category   = if ($statusCode -eq 200) { 'ok' } else { Get-HttpCategory -StatusCode $statusCode }
        }
    }
    catch {
        return [pscustomobject]@{
            StatusCode = $null
            Success    = $false
            Category   = 'network-or-tls'
        }
    }
}

function Test-CanonicalJiraSiteUrl {
    param([string]$Value)

    try {
        $uri = [Uri]$Value
        if (-not $uri.IsAbsoluteUri) { return $false }
        if ($uri.Scheme -ne 'https') { return $false }
        if (-not $uri.IsDefaultPort) { return $false }
        if ($uri.UserInfo -or $uri.Query -or $uri.Fragment) { return $false }
        if ($uri.AbsolutePath -ne '/') { return $false }
        if ($uri.Host -notmatch '^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.atlassian\.net$') { return $false }
        return $true
    }
    catch {
        return $false
    }
}

function Test-JiraEmail {
    param([string]$Value)
    return ($Value -match '^[^\s@]+@[^\s@]+\.[^\s@]+$')
}

function Test-CloudId {
    param([string]$Value)
    $parsed = [Guid]::Empty
    return [Guid]::TryParse($Value, [ref]$parsed) -and $parsed -ne [Guid]::Empty
}

function Test-CanonicalJiraApiBaseUrl {
    param([string]$Value, [string]$CloudId)

    if (-not (Test-CloudId -Value $CloudId)) { return $false }
    $expected = "https://api.atlassian.com/ex/jira/$CloudId"
    return $Value.TrimEnd('/') -ceq $expected
}

function New-BasicAuthorizationHeader {
    param([string]$Email, [string]$Token)

    $credentialBytes = [Text.Encoding]::UTF8.GetBytes("${Email}:${Token}")
    try {
        $encodedCredential = [Convert]::ToBase64String($credentialBytes)
        return "Basic $encodedCredential"
    }
    finally {
        [Array]::Clear($credentialBytes, 0, $credentialBytes.Length)
    }
}

function Get-SettingState {
    param([string]$Name)

    $values = [ordered]@{}
    foreach ($scope in @('Process', 'User', 'Machine')) {
        try {
            $value = & $EnvironmentReader $Name $scope
            if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                $values[$scope] = [string]$value
            }
        }
        catch {
            return [pscustomobject]@{
                Name = $Name
                Value = $null
                Present = $false
                Sources = @('unknown')
                InspectionFailed = $true
                PersistedButNotInherited = $false
                ScopeConflict = $false
            }
        }
    }

    $processPresent = $values.Contains('Process')
    $processValue = if ($processPresent) { $values.Process } else { $null }
    $persistedButNotInherited = -not $processPresent -and ($values.Contains('User') -or $values.Contains('Machine'))
    $scopeConflict = $false
    if ($processPresent) {
        foreach ($scope in @('User', 'Machine')) {
            if ($values.Contains($scope) -and -not [string]::Equals($processValue, $values[$scope], [StringComparison]::Ordinal)) {
                $scopeConflict = $true
            }
        }
    }

    [pscustomobject]@{
        Name = $Name
        Value = $processValue
        Present = $processPresent
        Sources = @($values.Keys)
        InspectionFailed = $false
        PersistedButNotInherited = $persistedButNotInherited
        ScopeConflict = $scopeConflict
    }
}

function New-HostReloadContract {
    param(
        [string]$State,
        [bool]$SecretInjectionRequired
    )

    $required = $State -in @('reload-required', 'process-user-mismatch')
    [pscustomobject]@{
        ContractVersion = 1
        Required = $required
        Reason = $State
        RequiredAction = if ($required) { 'recreate-host-process' } else { 'none' }
        ParentProcessMutationSupported = $false
        SecretInjectionRequired = $required -and $SecretInjectionRequired
        SecretSourceRequired = if ($required -and $SecretInjectionRequired) { 'approved-secret-store-or-hidden-input' } else { 'none' }
        VerificationAction = 'rerun-validator'
    }
}

$inventory = [ordered]@{}
$resolvedValues = @{}
$settingStates = @{}
$configurationValid = $true

foreach ($setting in $requiredSettings) {
    $state = Get-SettingState $setting
    $settingStates[$setting] = $state
    if ($state.Present) { $resolvedValues[$setting] = $state.Value } else { $configurationValid = $false }
    if ($state.InspectionFailed) { $configurationValid = $false }

    $inventory[$setting] = [pscustomobject][ordered]@{
        Process = if ($state.Sources -contains 'Process') { 'configured' } else { 'missing' }
        User = if ($state.Sources -contains 'User') { 'configured' } else { 'missing' }
        Machine = if ($state.Sources -contains 'Machine') { 'configured' } else { 'missing' }
        InspectionFailed = [bool]$state.InspectionFailed
        PersistedButNotInherited = [bool]$state.PersistedButNotInherited
        ScopeConflict = [bool]$state.ScopeConflict
    }
}

$validation = [ordered]@{
    JiraBaseUrl    = 'missing'
    JiraEmail      = 'missing'
    JiraApiToken   = 'missing'
    JiraCloudId    = 'missing'
    JiraApiBaseUrl = 'missing'
}

if ($resolvedValues.ContainsKey('JIRA_BASE_URL')) {
    $validation.JiraBaseUrl = if (Test-CanonicalJiraSiteUrl -Value $resolvedValues.JIRA_BASE_URL) { 'valid' } else { 'invalid' }
}
if ($resolvedValues.ContainsKey('JIRA_EMAIL')) {
    $validation.JiraEmail = if (Test-JiraEmail -Value $resolvedValues.JIRA_EMAIL) { 'valid' } else { 'invalid' }
}
if ($resolvedValues.ContainsKey('JIRA_API_TOKEN')) {
    $validation.JiraApiToken = if ([string]::IsNullOrWhiteSpace($resolvedValues.JIRA_API_TOKEN)) { 'missing' } else { 'configured' }
}
if ($resolvedValues.ContainsKey('JIRA_CLOUD_ID')) {
    $validation.JiraCloudId = if (Test-CloudId -Value $resolvedValues.JIRA_CLOUD_ID) { 'valid' } else { 'invalid' }
}
if ($resolvedValues.ContainsKey('JIRA_API_BASE_URL')) {
    $validation.JiraApiBaseUrl = if (
        $resolvedValues.ContainsKey('JIRA_CLOUD_ID') -and
        (Test-CanonicalJiraApiBaseUrl -Value $resolvedValues.JIRA_API_BASE_URL -CloudId $resolvedValues.JIRA_CLOUD_ID)
    ) { 'valid' } else { 'invalid' }
}

if ($validation.Values -contains 'invalid') {
    $configurationValid = $false
}

$hasInspectionFailure = @($settingStates.Values | Where-Object InspectionFailed).Count -gt 0
$missingProcessSettings = @($settingStates.Values | Where-Object { -not $_.Present } | ForEach-Object Name)
$persistedButNotInheritedSettings = @($settingStates.Values | Where-Object PersistedButNotInherited | ForEach-Object Name)
$scopeConflictSettings = @($settingStates.Values | Where-Object ScopeConflict | ForEach-Object Name)
$hostEnvironmentState = if ($hasInspectionFailure) {
    'unknown'
}
elseif ($missingProcessSettings.Count -gt 0) {
    if ($missingProcessSettings.Count -eq $persistedButNotInheritedSettings.Count) { 'reload-required' } else { 'incomplete' }
}
elseif ($scopeConflictSettings.Count -gt 0) {
    'process-user-mismatch'
}
else {
    'process-ready'
}
$persistedSecretAvailable = $settingStates.JIRA_API_TOKEN.Sources -contains 'User' -or $settingStates.JIRA_API_TOKEN.Sources -contains 'Machine'
$hostReloadContract = New-HostReloadContract $hostEnvironmentState (-not $persistedSecretAvailable)

$hasIssueTarget = -not [string]::IsNullOrWhiteSpace($IssueKey)
$hasJqlTarget = -not [string]::IsNullOrWhiteSpace($Jql)
$queryTargetState = 'not-provided'

if ($hasIssueTarget -or $hasJqlTarget) {
    $queryTargetState = 'valid'
    if ($hasIssueTarget -and $IssueKey -notmatch '^[A-Z][A-Z0-9_]*-[1-9][0-9]*$') {
        $queryTargetState = 'invalid'
    }
    if ($hasJqlTarget -and ($Jql.Length -gt 4000 -or $Jql -match '[\r\n]')) {
        $queryTargetState = 'invalid'
    }
}

$shouldTestConnection = [bool]$TestConnection -or $hasIssueTarget -or $hasJqlTarget
$tenantIdentityCheck = [pscustomobject]@{ StatusCode = $null; Success = $null; Match = $null; Category = 'not-run' }
$identityReadCheck = [pscustomobject]@{ StatusCode = $null; Success = $null; Category = 'not-run' }
$issueReadCheck = [pscustomobject]@{ StatusCode = $null; Success = $null; Category = 'not-requested' }
$jqlReadCheck = [pscustomobject]@{ StatusCode = $null; Success = $null; Category = 'not-requested' }

if ($hasIssueTarget) {
    $issueReadCheck = [pscustomobject]@{ StatusCode = $null; Success = $null; Category = 'not-run' }
}
if ($hasJqlTarget) {
    $jqlReadCheck = [pscustomobject]@{ StatusCode = $null; Success = $null; Category = 'not-run' }
}

if ($shouldTestConnection -and $configurationValid -and $queryTargetState -ne 'invalid') {
    $tenantInfoUri = $resolvedValues.JIRA_BASE_URL.TrimEnd('/') + '/_edge/tenant_info'
    try {
        $tenantResponse = & $HttpInvoker $tenantInfoUri @{}
        $tenantStatus = [int]$tenantResponse.StatusCode
        if ($tenantStatus -eq 200) {
            try {
                $tenantInfo = [string]$tenantResponse.Content | ConvertFrom-Json
                $tenantMatches = ([string]$tenantInfo.cloudId -eq $resolvedValues.JIRA_CLOUD_ID)
                $tenantIdentityCheck = [pscustomobject]@{
                    StatusCode = 200
                    Success    = $tenantMatches
                    Match      = $tenantMatches
                    Category   = if ($tenantMatches) { 'ok' } else { 'tenant-mismatch' }
                }
            }
            catch {
                $tenantIdentityCheck = [pscustomobject]@{
                    StatusCode = 200
                    Success    = $false
                    Match      = $false
                    Category   = 'invalid-tenant-response'
                }
            }
        }
        else {
            $tenantIdentityCheck = [pscustomobject]@{
                StatusCode = $tenantStatus
                Success    = $false
                Match      = $null
                Category   = (Get-HttpCategory -StatusCode $tenantStatus)
            }
        }
    }
    catch {
        $tenantIdentityCheck = [pscustomobject]@{
            StatusCode = $null
            Success    = $false
            Match      = $null
            Category   = 'network-or-tls'
        }
    }

    if ($tenantIdentityCheck.Success) {
        $headers = @{
            Accept        = 'application/json'
            Authorization = New-BasicAuthorizationHeader -Email $resolvedValues.JIRA_EMAIL -Token $resolvedValues.JIRA_API_TOKEN
        }

        try {
            $identityUri = $resolvedValues.JIRA_API_BASE_URL.TrimEnd('/') + '/rest/api/3/myself'
            $identityReadCheck = Invoke-ReadCheck -Uri $identityUri -Headers $headers -Invoker $HttpInvoker

            if ($identityReadCheck.Success -and $hasIssueTarget) {
                $escapedIssueKey = [Uri]::EscapeDataString($IssueKey)
                $issueUri = $resolvedValues.JIRA_API_BASE_URL.TrimEnd('/') + "/rest/api/3/issue/${escapedIssueKey}?fields=summary,status,issuetype,assignee"
                $issueReadCheck = Invoke-ReadCheck -Uri $issueUri -Headers $headers -Invoker $HttpInvoker
            }

            if ($identityReadCheck.Success -and $hasJqlTarget) {
                $escapedJql = [Uri]::EscapeDataString($Jql)
                $jqlUri = $resolvedValues.JIRA_API_BASE_URL.TrimEnd('/') + "/rest/api/3/search/jql?jql=${escapedJql}&maxResults=${MaxResults}&fields=summary,status,issuetype,assignee"
                $jqlReadCheck = Invoke-ReadCheck -Uri $jqlUri -Headers $headers -Invoker $HttpInvoker
            }
        }
        finally {
            if ($headers.ContainsKey('Authorization')) {
                $headers.Authorization = $null
            }
        }
    }
}

$readyForRead = [bool](
    $configurationValid -and
    $tenantIdentityCheck.Success -and
    $identityReadCheck.Success
)

$readyForRequestedQuery = $readyForRead -and $queryTargetState -ne 'invalid'
if ($hasIssueTarget) {
    $readyForRequestedQuery = $readyForRequestedQuery -and [bool]$issueReadCheck.Success
}
if ($hasJqlTarget) {
    $readyForRequestedQuery = $readyForRequestedQuery -and [bool]$jqlReadCheck.Success
}

[pscustomobject]@{
    Product                   = 'Jira Cloud'
    ConfigurationState        = if ($configurationValid) { 'configured' } else { 'incomplete-or-invalid' }
    HostEnvironmentState      = $hostEnvironmentState
    HostReloadRequired        = [bool]$hostReloadContract.Required
    HostReloadContract        = $hostReloadContract
    MissingProcessSettings    = @($missingProcessSettings)
    PersistedButNotInheritedSettings = @($persistedButNotInheritedSettings)
    ScopeConflictSettings     = @($scopeConflictSettings)
    Inventory                 = [pscustomobject]$inventory
    Validation                = [pscustomobject]$validation
    ClassicRequiredScopes     = $classicRequiredScopes
    GranularIdentityScopes    = $granularIdentityScopes
    GranularQueryScopes       = $granularQueryScopes
    QueryTargetState          = $queryTargetState
    TenantIdentityCheck       = $tenantIdentityCheck
    IdentityReadCheck         = $identityReadCheck
    IssueReadCheck            = $issueReadCheck
    JqlReadCheck              = $jqlReadCheck
    ReadyForRead              = $readyForRead
    ReadyForRequestedQuery    = [bool]$readyForRequestedQuery
    SecretsRedacted           = $true
    ResponseBodiesSuppressed  = $true
}
