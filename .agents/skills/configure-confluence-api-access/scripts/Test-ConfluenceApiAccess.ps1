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
            }
        }
    }

    $selectedValue = $null
    foreach ($scope in @('Process', 'User', 'Machine')) {
        if ($values.Contains($scope)) {
            $selectedValue = $values[$scope]
            break
        }
    }

    [pscustomobject]@{
        Name = $Name
        Value = $selectedValue
        Present = $null -ne $selectedValue
        Sources = @($values.Keys)
        InspectionFailed = $false
    }
}

function Test-ConfluenceSiteBase {
    param([string] $Value)

    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref] $uri)) { return $false }
    return $uri.Scheme -ceq 'https' `
        -and $uri.DnsSafeHost -like '*.atlassian.net' `
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
    return [Guid]::TryParse($Value, [ref] $cloudId)
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
        -and -not $Value.Contains('://', [StringComparison]::Ordinal) `
        -and -not $Value.Contains('..', [StringComparison]::Ordinal) `
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
    }
}

$hasInspectionFailure = @($states.Values | Where-Object InspectionFailed).Count -gt 0
$hasMissing = @($validation.Values | Where-Object { $_ -ceq 'missing' }).Count -gt 0
$hasInvalid = @($validation.Values | Where-Object { $_ -ceq 'invalid' }).Count -gt 0
$configurationState = if ($hasInspectionFailure -or $hasInvalid) { 'invalid' } elseif ($hasMissing) { 'missing' } else { 'valid' }

$spaceReadCheck = New-CheckResult $false $null 'not-requested'
$leastPrivilegeCheck = New-CheckResult $false $null 'not-requested'
$leastPrivilegeState = 'not-tested'
$authorization = $null
$credentialBytes = $null

if ($configurationState -ceq 'valid' -and $TestConnection) {
    $credentialBytes = [Text.Encoding]::UTF8.GetBytes("$($states.CONFLUENCE_EMAIL.Value):$($states.CONFLUENCE_API_TOKEN.Value)")
    $authorization = 'Basic ' + [Convert]::ToBase64String($credentialBytes)
    try {
        $apiBase = $states.CONFLUENCE_API_BASE_URL.Value.TrimEnd('/')
        $spaceReadUri = [Uri] "${apiBase}/wiki/api/v2/spaces?limit=1"
        $spaceReadCheck = Invoke-RedactedRead $spaceReadUri $authorization

        if (-not [string]::IsNullOrWhiteSpace($OutOfScopeReadPath)) {
            if (-not (Test-SafeRelativeReadPath $OutOfScopeReadPath)) {
                $leastPrivilegeState = 'invalid-test-path'
                $leastPrivilegeCheck = New-CheckResult $false $null 'invalid-read-path'
            }
            elseif ($spaceReadCheck.Category -cne 'success') {
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

[pscustomobject]@{
    Product = 'Confluence Cloud'
    ConfigurationState = $configurationState
    Inventory = @($inventory)
    RequiredScopes = @($requiredScopes)
    SpaceReadCheck = $spaceReadCheck
    LeastPrivilegeCheck = $leastPrivilegeCheck
    LeastPrivilegeState = $leastPrivilegeState
    ReadyForRead = $configurationState -ceq 'valid' -and $spaceReadCheck.Category -ceq 'success'
    ReadyForPublishing = $false
    PublishingState = 'not-proven-by-read-only-validation'
    SecretsRedacted = $true
}
