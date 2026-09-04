# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param(
    [switch] $TestConnection,
    [string] $RepositorySlug,
    [int] $PullRequestId,
    [scriptblock] $EnvironmentReader,
    [scriptblock] $HttpInvoker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requiredSettings = @(
    'BITBUCKET_API_BASE_URL',
    'BITBUCKET_EMAIL',
    'BITBUCKET_API_TOKEN',
    'BITBUCKET_WORKSPACE'
)
$requiredScopes = @('read:repository:bitbucket', 'read:pullrequest:bitbucket')

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

function Test-BitbucketApiBase {
    param([string] $Value)

    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref] $uri)) { return $false }
    return $uri.Scheme -ceq 'https' `
        -and $uri.DnsSafeHost -ceq 'api.bitbucket.org' `
        -and $uri.AbsolutePath.TrimEnd('/') -ceq '/2.0' `
        -and [string]::IsNullOrEmpty($uri.UserInfo) `
        -and [string]::IsNullOrEmpty($uri.Query) `
        -and [string]::IsNullOrEmpty($uri.Fragment)
}

function Test-EmailShape {
    param([string] $Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[^@\s]+@[^@\s]+\.[^@\s]+$'
}

function Test-WorkspaceShape {
    param([string] $Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[A-Za-z0-9][A-Za-z0-9_-]*$'
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

$states = @{}
foreach ($name in $requiredSettings) { $states[$name] = Get-SettingState $name }

$validation = @{
    BITBUCKET_API_BASE_URL = if (-not $states.BITBUCKET_API_BASE_URL.Present) { 'missing' } elseif (Test-BitbucketApiBase $states.BITBUCKET_API_BASE_URL.Value) { 'valid' } else { 'invalid' }
    BITBUCKET_EMAIL = if (-not $states.BITBUCKET_EMAIL.Present) { 'missing' } elseif (Test-EmailShape $states.BITBUCKET_EMAIL.Value) { 'valid' } else { 'invalid' }
    BITBUCKET_API_TOKEN = if ($states.BITBUCKET_API_TOKEN.Present) { 'presence-only' } else { 'missing' }
    BITBUCKET_WORKSPACE = if (-not $states.BITBUCKET_WORKSPACE.Present) { 'missing' } elseif (Test-WorkspaceShape $states.BITBUCKET_WORKSPACE.Value) { 'valid' } else { 'invalid' }
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
$persistedSecretAvailable = $states.BITBUCKET_API_TOKEN.Sources -contains 'User' -or $states.BITBUCKET_API_TOKEN.Sources -contains 'Machine'
$hostReloadContract = New-HostReloadContract $hostEnvironmentState (-not $persistedSecretAvailable)

$repositoryReadCheck = New-CheckResult $false $null 'not-requested'
$pullRequestReadCheck = New-CheckResult $false $null 'not-requested'
$targetState = 'not-provided'
$authorization = $null
$credentialBytes = $null

if ($configurationState -ceq 'valid' -and $TestConnection) {
    $credentialBytes = [Text.Encoding]::UTF8.GetBytes("$($states.BITBUCKET_EMAIL.Value):$($states.BITBUCKET_API_TOKEN.Value)")
    $authorization = 'Basic ' + [Convert]::ToBase64String($credentialBytes)
    try {
        $apiBase = $states.BITBUCKET_API_BASE_URL.Value.TrimEnd('/')
        $workspace = [Uri]::EscapeDataString($states.BITBUCKET_WORKSPACE.Value)
        $repositoryReadUri = [Uri] "${apiBase}/repositories/${workspace}?pagelen=1"
        $repositoryReadCheck = Invoke-RedactedRead $repositoryReadUri $authorization

        $hasRepositorySlug = -not [string]::IsNullOrWhiteSpace($RepositorySlug)
        $hasPullRequestId = $PullRequestId -gt 0
        if ($hasRepositorySlug -and $hasPullRequestId) {
            $targetState = 'valid'
            $repository = [Uri]::EscapeDataString($RepositorySlug)
            $pullRequestReadUri = [Uri] "${apiBase}/repositories/${workspace}/${repository}/pullrequests/${PullRequestId}"
            $pullRequestReadCheck = Invoke-RedactedRead $pullRequestReadUri $authorization
        }
        elseif ($hasRepositorySlug -or $hasPullRequestId) {
            $targetState = 'invalid'
            $pullRequestReadCheck = New-CheckResult $false $null 'incomplete-target'
        }
        else {
            $pullRequestReadCheck = New-CheckResult $false $null 'target-not-provided'
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

[pscustomobject]@{
    Product = 'Bitbucket Cloud'
    ConfigurationState = $configurationState
    HostEnvironmentState = $hostEnvironmentState
    HostReloadRequired = [bool]$hostReloadContract.Required
    HostReloadContract = $hostReloadContract
    MissingProcessSettings = @($missingProcessSettings)
    PersistedButNotInheritedSettings = @($persistedButNotInheritedSettings)
    ScopeConflictSettings = @($scopeConflictSettings)
    Inventory = @($inventory)
    RequiredScopes = @($requiredScopes)
    RepositoryReadCheck = $repositoryReadCheck
    PullRequestReadCheck = $pullRequestReadCheck
    TargetState = $targetState
    ReadyForReview = $configurationState -ceq 'valid' `
        -and $repositoryReadCheck.Category -ceq 'success' `
        -and $pullRequestReadCheck.Category -ceq 'success'
    SecretsRedacted = $true
}
