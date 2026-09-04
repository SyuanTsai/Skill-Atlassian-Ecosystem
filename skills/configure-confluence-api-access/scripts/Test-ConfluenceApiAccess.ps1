# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param(
    [switch] $TestConnection,
    [string] $OutOfScopeReadPath,
    [scriptblock] $EnvironmentReader,
    [scriptblock] $HttpInvoker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requiredSettings = @(
    'CONFLUENCE_BASE_URL',
    'CONFLUENCE_EMAIL',
    'CONFLUENCE_API_TOKEN',
    'CONFLUENCE_CLOUD_ID',
    'CONFLUENCE_API_BASE_URL'
)
$requiredScopes = @('read:space:confluence', 'read:page:confluence', 'write:page:confluence')

if ($null -eq $EnvironmentReader) {
    $EnvironmentReader = {
        param([string] $Name, [string] $Scope)
        $runningOnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
        if (-not $runningOnWindows -and $Scope -cne 'Process') { return $null }
        $target = switch ($Scope) {
            'Process' { [EnvironmentVariableTarget]::Process }
            'User' { [EnvironmentVariableTarget]::User }
            'Machine' { [EnvironmentVariableTarget]::Machine }
            default { throw "Unsupported environment scope: $Scope" }
        }
        [Environment]::GetEnvironmentVariable($Name, $target)
    }
}

if ($null -eq $HttpInvoker) {
    $HttpInvoker = {
        param([Uri] $Uri, [hashtable] $Headers)

        if ($PSVersionTable.PSVersion.Major -ge 7) {
            return Invoke-WebRequest -UseBasicParsing -SkipHttpErrorCheck -Method Get -Uri $Uri -Headers $Headers -TimeoutSec 30
        }

        try {
            return Invoke-WebRequest -UseBasicParsing -Method Get -Uri $Uri -Headers $Headers -TimeoutSec 30
        }
        catch {
            if ($null -ne $_.Exception.Response) {
                return [pscustomobject]@{ StatusCode = [int] $_.Exception.Response.StatusCode }
            }
            throw
        }
    }
}

function Get-SettingState {
    param([string] $Name)

    $values = [ordered]@{}
    foreach ($scope in @('Process', 'User', 'Machine')) {
        try {
            $value = & $EnvironmentReader $Name $scope
            if (-not [string]::IsNullOrEmpty([string] $value)) { $values[$scope] = [string] $value }
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
    $selectedValue = if ($processPresent) { $values.Process } else { $null }
    $persistedButNotInherited = -not $processPresent -and ($values.Contains('User') -or $values.Contains('Machine'))
    $scopeConflict = $false
    if ($processPresent) {
        foreach ($scope in @('User', 'Machine')) {
            if ($values.Contains($scope) -and -not [string]::Equals($selectedValue, $values[$scope], [StringComparison]::Ordinal)) {
                $scopeConflict = $true
            }
        }
    }

    [pscustomobject]@{
        Name = $Name
        Value = $selectedValue
        Present = $processPresent
        Sources = @($values.Keys)
        InspectionFailed = $false
        PersistedButNotInherited = $persistedButNotInherited
        ScopeConflict = $scopeConflict
    }
}

function New-HostReloadContract {
    param(
        [string] $State,
        [bool] $SecretInjectionRequired
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

function Test-ConfluenceSiteBase {
    param([string] $Value)

    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref] $uri)) { return $false }
    return $uri.Scheme -ceq 'https' `
        -and $uri.DnsSafeHost -like '*.atlassian.net' `
        -and $uri.IsDefaultPort `
        -and [string]::IsNullOrEmpty($uri.AbsolutePath.TrimEnd('/')) `
        -and [string]::IsNullOrEmpty($uri.UserInfo) `
        -and [string]::IsNullOrEmpty($uri.Query) `
        -and [string]::IsNullOrEmpty($uri.Fragment)
}

function Test-EmailShape {
    param([string] $Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[^@\s]+@[^@\s]+\.[^@\s]+$'
}

function Test-CloudIdShape {
    param([string] $Value)
    $cloudId = [Guid]::Empty
    return [Guid]::TryParse($Value, [ref] $cloudId) -and $cloudId -ne [Guid]::Empty
}

function Test-ConfluenceApiBase {
    param(
        [string] $Value,
        [string] $CloudId
    )

    if (-not (Test-CloudIdShape $CloudId)) { return $false }
    return $Value.TrimEnd('/') -ceq "https://api.atlassian.com/ex/confluence/$CloudId"
}

function Test-SafeRelativeReadPath {
    param([string] $Value)
    return -not [string]::IsNullOrWhiteSpace($Value) `
        -and $Value.StartsWith('/wiki/api/', [StringComparison]::Ordinal) `
        -and $Value.IndexOf('://', [StringComparison]::Ordinal) -lt 0 `
        -and $Value.IndexOf('..', [StringComparison]::Ordinal) -lt 0 `
        -and $Value -notmatch '[\r\n]'
}

function Get-HttpCategory {
    param([int] $StatusCode)

    switch ($StatusCode) {
        200 { 'success' }
        400 { 'request-or-configuration' }
        401 { 'authentication' }
        403 { 'permission-or-scope' }
        404 { 'target-or-path' }
        429 { 'rate-limited' }
        default { 'unexpected-status' }
    }
}

function New-CheckResult {
    param(
        [bool] $Attempted,
        [AllowNull()]
        [Nullable[int]] $StatusCode,
        [string] $Category
    )

    [pscustomobject]@{
        Attempted = $Attempted
        StatusCode = $StatusCode
        Category = $Category
        ResponseBodySuppressed = $true
    }
}

function New-TenantIdentityResult {
    param(
        [bool] $Attempted,
        [AllowNull()]
        [Nullable[int]] $StatusCode,
        [string] $Category,
        [string] $State
    )

    [pscustomobject]@{
        Attempted = $Attempted
        StatusCode = $StatusCode
        Category = $Category
        State = $State
        ResponseBodySuppressed = $true
    }
}

function Invoke-RedactedRead {
    param(
        [Uri] $Uri,
        [string] $Authorization
    )

    $headers = @{ Accept = 'application/json'; Authorization = $Authorization }
    try {
        $response = & $HttpInvoker $Uri $headers
        $statusCode = [int] $response.StatusCode
        return New-CheckResult $true $statusCode (Get-HttpCategory $statusCode)
    }
    catch {
        return New-CheckResult $true $null 'network-or-tls'
    }
    finally {
        $headers.Authorization = $null
        $headers = $null
    }
}

function Invoke-TenantIdentityCheck {
    param(
        [Uri] $Uri,
        [Guid] $ExpectedCloudId
    )

    $headers = @{ Accept = 'application/json' }
    try {
        $response = & $HttpInvoker $Uri $headers
        $statusCode = [int] $response.StatusCode
        $category = Get-HttpCategory $statusCode
        if ($category -cne 'success') {
            return New-TenantIdentityResult $true $statusCode $category 'lookup-failed'
        }

        try {
            $tenantInfo = [string] $response.Content | ConvertFrom-Json
            $actualCloudId = [Guid]::Empty
            if (-not [Guid]::TryParse([string] $tenantInfo.cloudId, [ref] $actualCloudId) -or $actualCloudId -eq [Guid]::Empty) {
                return New-TenantIdentityResult $true $statusCode 'invalid-response' 'invalid-response'
            }
        }
        catch {
            return New-TenantIdentityResult $true $statusCode 'invalid-response' 'invalid-response'
        }

        $state = if ($actualCloudId -eq $ExpectedCloudId) { 'match' } else { 'mismatch' }
        return New-TenantIdentityResult $true $statusCode 'success' $state
    }
    catch {
        return New-TenantIdentityResult $true $null 'network-or-tls' 'lookup-failed'
    }
    finally {
        $headers = $null
    }
}

$states = @{}
foreach ($name in $requiredSettings) { $states[$name] = Get-SettingState $name }

$validation = @{
    CONFLUENCE_BASE_URL = if (-not $states.CONFLUENCE_BASE_URL.Present) { 'missing' } elseif (Test-ConfluenceSiteBase $states.CONFLUENCE_BASE_URL.Value) { 'valid' } else { 'invalid' }
    CONFLUENCE_EMAIL = if (-not $states.CONFLUENCE_EMAIL.Present) { 'missing' } elseif (Test-EmailShape $states.CONFLUENCE_EMAIL.Value) { 'valid' } else { 'invalid' }
    CONFLUENCE_API_TOKEN = if ($states.CONFLUENCE_API_TOKEN.Present) { 'presence-only' } else { 'missing' }
    CONFLUENCE_CLOUD_ID = if (-not $states.CONFLUENCE_CLOUD_ID.Present) { 'missing' } elseif (Test-CloudIdShape $states.CONFLUENCE_CLOUD_ID.Value) { 'valid' } else { 'invalid' }
    CONFLUENCE_API_BASE_URL = if (-not $states.CONFLUENCE_API_BASE_URL.Present) { 'missing' } elseif (Test-ConfluenceApiBase $states.CONFLUENCE_API_BASE_URL.Value $states.CONFLUENCE_CLOUD_ID.Value) { 'valid' } else { 'invalid' }
}

$inventory = foreach ($name in $requiredSettings) {
    [pscustomobject]@{
        Name = $name
        Present = [bool] $states[$name].Present
        Sources = @($states[$name].Sources)
        Validation = if ($states[$name].InspectionFailed) { 'inspection-failed' } else { $validation[$name] }
        PersistedButNotInherited = [bool]$states[$name].PersistedButNotInherited
        ScopeConflict = [bool]$states[$name].ScopeConflict
    }
}

$hasInspectionFailure = @($states.Values | Where-Object InspectionFailed).Count -gt 0
$hasMissing = @($validation.Values | Where-Object { $_ -ceq 'missing' }).Count -gt 0
$hasInvalid = @($validation.Values | Where-Object { $_ -ceq 'invalid' }).Count -gt 0
$configurationState = if ($hasInspectionFailure -or $hasInvalid) { 'invalid' } elseif ($hasMissing) { 'missing' } else { 'valid' }
$missingProcessSettings = @($states.Values | Where-Object { -not $_.Present } | ForEach-Object Name)
$persistedButNotInheritedSettings = @($states.Values | Where-Object PersistedButNotInherited | ForEach-Object Name)
$scopeConflictSettings = @($states.Values | Where-Object ScopeConflict | ForEach-Object Name)
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
$persistedSecretAvailable = $states.CONFLUENCE_API_TOKEN.Sources -contains 'User' -or $states.CONFLUENCE_API_TOKEN.Sources -contains 'Machine'
$hostReloadContract = New-HostReloadContract $hostEnvironmentState (-not $persistedSecretAvailable)

$spaceReadCheck = New-CheckResult $false $null 'not-requested'
$pageReadCheck = New-CheckResult $false $null 'not-requested'
$leastPrivilegeCheck = New-CheckResult $false $null 'not-requested'
$leastPrivilegeState = 'not-tested'
$tenantIdentityCheck = New-TenantIdentityResult $false $null 'not-requested' 'not-tested'
$authorization = $null
$credentialBytes = $null

if ($configurationState -ceq 'valid' -and $TestConnection) {
    $siteBase = $states.CONFLUENCE_BASE_URL.Value.TrimEnd('/')
    $tenantInfoUri = [Uri] "${siteBase}/_edge/tenant_info"
    $expectedCloudId = [Guid]::Parse($states.CONFLUENCE_CLOUD_ID.Value)
    $tenantIdentityCheck = Invoke-TenantIdentityCheck $tenantInfoUri $expectedCloudId

    if ($tenantIdentityCheck.State -ceq 'mismatch') {
        $configurationState = 'invalid'
    }
    elseif ($tenantIdentityCheck.State -ceq 'match') {
        $credentialBytes = [Text.Encoding]::UTF8.GetBytes("$($states.CONFLUENCE_EMAIL.Value):$($states.CONFLUENCE_API_TOKEN.Value)")
        $authorization = 'Basic ' + [Convert]::ToBase64String($credentialBytes)
        try {
            $apiBase = $states.CONFLUENCE_API_BASE_URL.Value.TrimEnd('/')
            $spaceReadUri = [Uri] "${apiBase}/wiki/api/v2/spaces?limit=1"
            $spaceReadCheck = Invoke-RedactedRead $spaceReadUri $authorization
            $pageReadUri = [Uri] "${apiBase}/wiki/api/v2/pages?limit=1"
            $pageReadCheck = Invoke-RedactedRead $pageReadUri $authorization

            if (-not [string]::IsNullOrWhiteSpace($OutOfScopeReadPath)) {
                if (-not (Test-SafeRelativeReadPath $OutOfScopeReadPath)) {
                    $leastPrivilegeState = 'invalid-test-path'
                    $leastPrivilegeCheck = New-CheckResult $false $null 'invalid-read-path'
                }
                elseif ($spaceReadCheck.Category -cne 'success' -or $pageReadCheck.Category -cne 'success') {
                    $leastPrivilegeState = 'inconclusive'
                    $leastPrivilegeCheck = New-CheckResult $false $null 'primary-read-failed'
                }
                else {
                    $leastPrivilegeUri = [Uri] "${apiBase}${OutOfScopeReadPath}"
                    $leastPrivilegeCheck = Invoke-RedactedRead $leastPrivilegeUri $authorization
                    $leastPrivilegeState = if ($leastPrivilegeCheck.StatusCode -in @(401, 403)) {
                        'expected-denial-observed'
                    }
                    elseif ($leastPrivilegeCheck.Category -ceq 'success') {
                        'over-scoped'
                    }
                    else {
                        'inconclusive'
                    }
                }
            }
        }
        finally {
            if ($null -ne $credentialBytes) {
                [Array]::Clear($credentialBytes, 0, $credentialBytes.Length)
            }
            $authorization = $null
            $credentialBytes = $null
        }
    }
}

[pscustomobject]@{
    Product = 'Confluence Cloud'
    ConfigurationState = $configurationState
    HostEnvironmentState = $hostEnvironmentState
    HostReloadRequired = [bool]$hostReloadContract.Required
    HostReloadContract = $hostReloadContract
    MissingProcessSettings = @($missingProcessSettings)
    PersistedButNotInheritedSettings = @($persistedButNotInheritedSettings)
    ScopeConflictSettings = @($scopeConflictSettings)
    Inventory = @($inventory)
    RequiredScopes = @($requiredScopes)
    TenantIdentityCheck = $tenantIdentityCheck
    TenantIdentityState = $tenantIdentityCheck.State
    SpaceReadCheck = $spaceReadCheck
    PageReadCheck = $pageReadCheck
    LeastPrivilegeCheck = $leastPrivilegeCheck
    LeastPrivilegeState = $leastPrivilegeState
    ReadyForRead = $configurationState -ceq 'valid' `
        -and $tenantIdentityCheck.State -ceq 'match' `
        -and $spaceReadCheck.Category -ceq 'success' `
        -and $pageReadCheck.Category -ceq 'success'
    ReadyForPublishing = $false
    PublishingState = 'not-proven-by-read-only-validation'
    SecretsRedacted = $true
}
