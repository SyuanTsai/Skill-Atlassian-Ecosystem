Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$bitbucketValidator = Join-Path $repositoryRoot '.agents/skills/configure-bitbucket-api-access/scripts/Test-BitbucketApiAccess.ps1'
$confluenceValidator = Join-Path $repositoryRoot '.agents/skills/configure-confluence-api-access/scripts/Test-ConfluenceApiAccess.ps1'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool] $Condition,
        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param(
        [AllowNull()]
        [object] $Actual,
        [AllowNull()]
        [object] $Expected,
        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if ($Actual -cne $Expected) { throw "$Message Expected '$Expected', got '$Actual'." }
}

function Assert-SecretRedacted {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Result,
        [Parameter(Mandatory = $true)]
        [string] $Email,
        [Parameter(Mandatory = $true)]
        [string] $Token
    )

    $serialized = $Result | ConvertTo-Json -Depth 12 -Compress
    $encodedCredential = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${Email}:${Token}"))
    Assert-True (-not $serialized.Contains($Email, [StringComparison]::Ordinal)) 'Result exposed the account email canary.'
    Assert-True (-not $serialized.Contains($Token, [StringComparison]::Ordinal)) 'Result exposed the token canary.'
    Assert-True (-not $serialized.Contains($encodedCredential, [StringComparison]::Ordinal)) 'Result exposed the encoded credential canary.'
}

function New-EnvironmentReader {
    param([hashtable] $Values)

    $capturedValues = $Values.Clone()
    return {
        param([string] $Name, [string] $Scope)
        if ($Scope -cne 'Process') { return $null }
        return $capturedValues[$Name]
    }.GetNewClosure()
}

function New-StatusTransport {
    param(
        [int[]] $Statuses,
        [hashtable] $State
    )

    $capturedStatuses = @($Statuses)
    $capturedState = $State
    return {
        param([Uri] $Uri, [hashtable] $Headers)
        $index = [int] $capturedState.Calls
        if ($index -ge $capturedStatuses.Count) { throw 'Fixture transport received an unexpected request.' }
        $capturedState.Calls = $index + 1
        $capturedState.AuthorizationPresent = -not [string]::IsNullOrWhiteSpace([string] $Headers.Authorization)
        if ($capturedState.ContainsKey('Uris')) {
            $capturedState.Uris = @($capturedState.Uris) + $Uri.AbsoluteUri
        }
        return [pscustomobject]@{ StatusCode = $capturedStatuses[$index] }
    }.GetNewClosure()
}

function New-ThrowingTransport {
    param(
        [hashtable] $State,
        [string] $Canary
    )

    $capturedState = $State
    $capturedCanary = $Canary
    return {
        param([Uri] $Uri, [hashtable] $Headers)
        $capturedState.Calls = [int] $capturedState.Calls + 1
        throw "fixture network failure $capturedCanary"
    }.GetNewClosure()
}

# Scenario: The helpers inspect the host environment with their built-in readers and no connection request.
# Purpose: Platform scope handling must not turn an ordinary offline inventory into an inspection failure.
function UnitT05_Default_environment_readers_support_offline_inventory {
    $bitbucketResult = & $bitbucketValidator
    $confluenceResult = & $confluenceValidator

    Assert-Equal @($bitbucketResult.Inventory | Where-Object Validation -eq 'inspection-failed').Count 0 'Bitbucket default environment reader failed.'
    Assert-Equal @($confluenceResult.Inventory | Where-Object Validation -eq 'inspection-failed').Count 0 'Confluence default environment reader failed.'
    Assert-True (-not $bitbucketResult.RepositoryReadCheck.Attempted) 'Bitbucket offline inventory attempted a request.'
    Assert-True (-not $confluenceResult.SpaceReadCheck.Attempted) 'Confluence offline inventory attempted a request.'
}

# Scenario: Every Bitbucket setting is absent and a connection test is requested.
# Purpose: Missing configuration must stop before network access and return only redacted state.
function UnitT10_Bitbucket_missing_configuration_stops_before_network {
    $state = @{ Calls = 0; AuthorizationPresent = $false; Uris = @() }
    $result = & $bitbucketValidator `
        -TestConnection `
        -EnvironmentReader (New-EnvironmentReader @{}) `
        -HttpInvoker (New-StatusTransport @(200) $state)

    Assert-Equal $result.ConfigurationState 'missing' 'Bitbucket missing-state classification failed.'
    Assert-Equal $state.Calls 0 'Bitbucket missing configuration attempted a network request.'
    Assert-True (-not $result.ReadyForReview) 'Bitbucket missing configuration was reported ready.'
}

# Scenario: Bitbucket values are present but the URL, email, and workspace shapes are invalid.
# Purpose: Invalid non-secret settings must be rejected without a request or token disclosure.
function UnitT20_Bitbucket_invalid_configuration_is_redacted_and_offline {
    $email = 'not-an-email'
    $token = 'SYP144_BITBUCKET_INVALID_CANARY'
    $values = @{
        BITBUCKET_API_BASE_URL = 'http://user:password@example.invalid/v1'
        BITBUCKET_EMAIL = $email
        BITBUCKET_API_TOKEN = $token
        BITBUCKET_WORKSPACE = 'invalid/workspace'
    }
    $state = @{ Calls = 0; AuthorizationPresent = $false }
    $result = & $bitbucketValidator `
        -TestConnection `
        -EnvironmentReader (New-EnvironmentReader $values) `
        -HttpInvoker (New-StatusTransport @(200) $state)

    Assert-Equal $result.ConfigurationState 'invalid' 'Bitbucket invalid-state classification failed.'
    Assert-Equal $state.Calls 0 'Bitbucket invalid configuration attempted a network request.'
    Assert-SecretRedacted $result $email $token
}

# Scenario: Bitbucket configuration is valid and both repository and pull-request reads succeed.
# Purpose: Readiness for PR review requires evidence for both independent read scopes.
function UnitT30_Bitbucket_valid_configuration_checks_both_read_paths {
    $email = 'tester@example.invalid'
    $token = 'SYP144_BITBUCKET_VALID_CANARY'
    $values = @{
        BITBUCKET_API_BASE_URL = 'https://api.bitbucket.org/2.0'
        BITBUCKET_EMAIL = $email
        BITBUCKET_API_TOKEN = $token
        BITBUCKET_WORKSPACE = 'example-workspace'
    }
    $state = @{ Calls = 0; AuthorizationPresent = $false; Uris = @() }
    $result = & $bitbucketValidator `
        -TestConnection `
        -RepositorySlug 'example-repository' `
        -PullRequestId 42 `
        -EnvironmentReader (New-EnvironmentReader $values) `
        -HttpInvoker (New-StatusTransport @(200, 200) $state)

    Assert-Equal $result.ConfigurationState 'valid' 'Bitbucket valid-state classification failed.'
    Assert-Equal $state.Calls 2 'Bitbucket validation did not test both read paths.'
    Assert-Equal $state.Uris[0] 'https://api.bitbucket.org/2.0/repositories/example-workspace?pagelen=1' 'Bitbucket repository validation URI is incorrect.'
    Assert-Equal $state.Uris[1] 'https://api.bitbucket.org/2.0/repositories/example-workspace/example-repository/pullrequests/42' 'Bitbucket PR validation URI is incorrect.'
    Assert-True $state.AuthorizationPresent 'Bitbucket validation did not construct in-memory authentication.'
    Assert-True $result.ReadyForReview 'Bitbucket successful read paths were not reported ready.'
    Assert-Equal (($result.RequiredScopes | Sort-Object) -join ',') 'read:pullrequest:bitbucket,read:repository:bitbucket' 'Bitbucket required scopes are inconsistent.'
    Assert-SecretRedacted $result $email $token
}

# Scenario: The Bitbucket repository read returns each documented non-success status or a transport error.
# Purpose: Diagnostics must preserve safe category-level classification without response bodies or exception text.
function UnitT40_Bitbucket_failures_are_classified_without_secret_output {
    $email = 'tester@example.invalid'
    $token = 'SYP144_BITBUCKET_FAILURE_CANARY'
    $values = @{
        BITBUCKET_API_BASE_URL = 'https://api.bitbucket.org/2.0'
        BITBUCKET_EMAIL = $email
        BITBUCKET_API_TOKEN = $token
        BITBUCKET_WORKSPACE = 'example-workspace'
    }
    $expectedCategories = [ordered]@{
        '400' = 'request-or-configuration'
        '401' = 'authentication'
        '403' = 'permission-or-scope'
        '404' = 'target-or-path'
        '429' = 'rate-limited'
    }

    foreach ($status in $expectedCategories.Keys) {
        $state = @{ Calls = 0; AuthorizationPresent = $false }
        $result = & $bitbucketValidator -TestConnection -EnvironmentReader (New-EnvironmentReader $values) -HttpInvoker (New-StatusTransport @([int]$status) $state)
        Assert-Equal $result.RepositoryReadCheck.Category $expectedCategories[$status] "Bitbucket HTTP $status classification failed."
        Assert-SecretRedacted $result $email $token
    }

    $networkState = @{ Calls = 0 }
    $networkResult = & $bitbucketValidator -TestConnection -EnvironmentReader (New-EnvironmentReader $values) -HttpInvoker (New-ThrowingTransport $networkState $token)
    Assert-Equal $networkResult.RepositoryReadCheck.Category 'network-or-tls' 'Bitbucket network classification failed.'
    Assert-SecretRedacted $networkResult $email $token

    $pullRequestState = @{ Calls = 0; AuthorizationPresent = $false }
    $pullRequestResult = & $bitbucketValidator -TestConnection -RepositorySlug 'example-repository' -PullRequestId 42 -EnvironmentReader (New-EnvironmentReader $values) -HttpInvoker (New-StatusTransport @(200, 403) $pullRequestState)
    Assert-Equal $pullRequestResult.PullRequestReadCheck.Category 'permission-or-scope' 'Bitbucket PR-read failure classification failed.'
    Assert-True (-not $pullRequestResult.ReadyForReview) 'Bitbucket PR-read failure was reported ready.'
    Assert-SecretRedacted $pullRequestResult $email $token
}

# Scenario: Every Confluence setting is absent and a connection test is requested.
# Purpose: Missing configuration must stop before tenant or content access.
function UnitT50_Confluence_missing_configuration_stops_before_network {
    $state = @{ Calls = 0; AuthorizationPresent = $false; Uris = @() }
    $result = & $confluenceValidator `
        -TestConnection `
        -EnvironmentReader (New-EnvironmentReader @{}) `
        -HttpInvoker (New-StatusTransport @(200) $state)

    Assert-Equal $result.ConfigurationState 'missing' 'Confluence missing-state classification failed.'
    Assert-Equal $state.Calls 0 'Confluence missing configuration attempted a network request.'
    Assert-True (-not $result.ReadyForRead) 'Confluence missing configuration was reported ready.'
}

# Scenario: Confluence values are present but site, email, Cloud ID, and API-base shapes are invalid.
# Purpose: Invalid non-secret settings must be rejected without a request or token disclosure.
function UnitT60_Confluence_invalid_configuration_is_redacted_and_offline {
    $email = 'not-an-email'
    $token = 'SYP144_CONFLUENCE_INVALID_CANARY'
    $values = @{
        CONFLUENCE_BASE_URL = 'ftp://user:password@example.invalid'
        CONFLUENCE_EMAIL = $email
        CONFLUENCE_API_TOKEN = $token
        CONFLUENCE_CLOUD_ID = 'not-a-uuid'
        CONFLUENCE_API_BASE_URL = 'https://api.atlassian.com/ex/confluence/wrong'
    }
    $state = @{ Calls = 0; AuthorizationPresent = $false }
    $result = & $confluenceValidator `
        -TestConnection `
        -EnvironmentReader (New-EnvironmentReader $values) `
        -HttpInvoker (New-StatusTransport @(200) $state)

    Assert-Equal $result.ConfigurationState 'invalid' 'Confluence invalid-state classification failed.'
    Assert-Equal $state.Calls 0 'Confluence invalid configuration attempted a network request.'
    Assert-SecretRedacted $result $email $token
}

# Scenario: Confluence space read succeeds and a documented read outside the selected scopes is denied.
# Purpose: Record both allowed access and an expected denial without overstating why the denial occurred.
function UnitT70_Confluence_valid_configuration_verifies_allowed_and_denied_reads {
    $email = 'tester@example.invalid'
    $token = 'SYP144_CONFLUENCE_VALID_CANARY'
    $cloudId = '11111111-2222-3333-4444-555555555555'
    $values = @{
        CONFLUENCE_BASE_URL = 'https://example.atlassian.net'
        CONFLUENCE_EMAIL = $email
        CONFLUENCE_API_TOKEN = $token
        CONFLUENCE_CLOUD_ID = $cloudId
        CONFLUENCE_API_BASE_URL = "https://api.atlassian.com/ex/confluence/$cloudId"
    }
    $state = @{ Calls = 0; AuthorizationPresent = $false; Uris = @() }
    $result = & $confluenceValidator `
        -TestConnection `
        -OutOfScopeReadPath '/wiki/api/v2/attachments?limit=1' `
        -EnvironmentReader (New-EnvironmentReader $values) `
        -HttpInvoker (New-StatusTransport @(200, 403) $state)

    Assert-Equal $result.ConfigurationState 'valid' 'Confluence valid-state classification failed.'
    Assert-Equal $state.Calls 2 'Confluence validation did not test both allowed and denied reads.'
    Assert-Equal $state.Uris[0] "https://api.atlassian.com/ex/confluence/$cloudId/wiki/api/v2/spaces?limit=1" 'Confluence allowed-read URI is incorrect.'
    Assert-Equal $state.Uris[1] "https://api.atlassian.com/ex/confluence/$cloudId/wiki/api/v2/attachments?limit=1" 'Confluence outside-scope URI is incorrect.'
    Assert-True $result.ReadyForRead 'Confluence successful space read was not reported ready.'
    Assert-Equal $result.LeastPrivilegeState 'expected-denial-observed' 'Confluence expected outside-scope denial was not recorded.'
    Assert-True (-not $result.ReadyForPublishing) 'Read-only validation incorrectly proved write readiness.'
    Assert-SecretRedacted $result $email $token
}

# Scenario: The read chosen to be outside Confluence token scopes unexpectedly succeeds.
# Purpose: Over-scoped tokens must not be reported as least-privilege validated.
function UnitT80_Confluence_over_scoped_token_is_detected {
    $email = 'tester@example.invalid'
    $token = 'SYP144_CONFLUENCE_OVERSCOPED_CANARY'
    $cloudId = '11111111-2222-3333-4444-555555555555'
    $values = @{
        CONFLUENCE_BASE_URL = 'https://example.atlassian.net'
        CONFLUENCE_EMAIL = $email
        CONFLUENCE_API_TOKEN = $token
        CONFLUENCE_CLOUD_ID = $cloudId
        CONFLUENCE_API_BASE_URL = "https://api.atlassian.com/ex/confluence/$cloudId"
    }
    $state = @{ Calls = 0; AuthorizationPresent = $false }
    $result = & $confluenceValidator `
        -TestConnection `
        -OutOfScopeReadPath '/wiki/api/v2/attachments?limit=1' `
        -EnvironmentReader (New-EnvironmentReader $values) `
        -HttpInvoker (New-StatusTransport @(200, 200) $state)

    Assert-Equal $result.LeastPrivilegeState 'over-scoped' 'Confluence over-scoped token was not detected.'
    Assert-SecretRedacted $result $email $token
}

# Scenario: The caller supplies an absolute or traversal path for the Confluence outside-scope read.
# Purpose: The helper must reject unsafe target expansion before issuing the secondary request.
function UnitT85_Confluence_unsafe_outside_scope_path_is_rejected {
    $email = 'tester@example.invalid'
    $token = 'SYP144_CONFLUENCE_UNSAFE_PATH_CANARY'
    $cloudId = '11111111-2222-3333-4444-555555555555'
    $values = @{
        CONFLUENCE_BASE_URL = 'https://example.atlassian.net'
        CONFLUENCE_EMAIL = $email
        CONFLUENCE_API_TOKEN = $token
        CONFLUENCE_CLOUD_ID = $cloudId
        CONFLUENCE_API_BASE_URL = "https://api.atlassian.com/ex/confluence/$cloudId"
    }
    $state = @{ Calls = 0; AuthorizationPresent = $false }
    $result = & $confluenceValidator `
        -TestConnection `
        -OutOfScopeReadPath '/wiki/api/../unsafe' `
        -EnvironmentReader (New-EnvironmentReader $values) `
        -HttpInvoker (New-StatusTransport @(200) $state)

    Assert-Equal $state.Calls 1 'Confluence unsafe outside-scope path issued a secondary request.'
    Assert-Equal $result.LeastPrivilegeState 'invalid-test-path' 'Confluence unsafe path was not rejected.'
    Assert-SecretRedacted $result $email $token
}

# Scenario: The Confluence space read returns each documented non-success status or a transport error.
# Purpose: Diagnostics must preserve safe category-level classification without response bodies or exception text.
function UnitT90_Confluence_failures_are_classified_without_secret_output {
    $email = 'tester@example.invalid'
    $token = 'SYP144_CONFLUENCE_FAILURE_CANARY'
    $cloudId = '11111111-2222-3333-4444-555555555555'
    $values = @{
        CONFLUENCE_BASE_URL = 'https://example.atlassian.net'
        CONFLUENCE_EMAIL = $email
        CONFLUENCE_API_TOKEN = $token
        CONFLUENCE_CLOUD_ID = $cloudId
        CONFLUENCE_API_BASE_URL = "https://api.atlassian.com/ex/confluence/$cloudId"
    }
    $expectedCategories = [ordered]@{
        '400' = 'request-or-configuration'
        '401' = 'authentication'
        '403' = 'permission-or-scope'
        '404' = 'target-or-path'
        '429' = 'rate-limited'
    }

    foreach ($status in $expectedCategories.Keys) {
        $state = @{ Calls = 0; AuthorizationPresent = $false }
        $result = & $confluenceValidator -TestConnection -OutOfScopeReadPath '/wiki/api/v2/attachments?limit=1' -EnvironmentReader (New-EnvironmentReader $values) -HttpInvoker (New-StatusTransport @([int]$status) $state)
        Assert-Equal $result.SpaceReadCheck.Category $expectedCategories[$status] "Confluence HTTP $status classification failed."
        Assert-Equal $state.Calls 1 "Confluence HTTP $status primary failure issued an outside-scope request."
        Assert-SecretRedacted $result $email $token
    }

    $networkState = @{ Calls = 0 }
    $networkResult = & $confluenceValidator -TestConnection -EnvironmentReader (New-EnvironmentReader $values) -HttpInvoker (New-ThrowingTransport $networkState $token)
    Assert-Equal $networkResult.SpaceReadCheck.Category 'network-or-tls' 'Confluence network classification failed.'
    Assert-SecretRedacted $networkResult $email $token
}

$tests = @(
    'UnitT05_Default_environment_readers_support_offline_inventory',
    'UnitT10_Bitbucket_missing_configuration_stops_before_network',
    'UnitT20_Bitbucket_invalid_configuration_is_redacted_and_offline',
    'UnitT30_Bitbucket_valid_configuration_checks_both_read_paths',
    'UnitT40_Bitbucket_failures_are_classified_without_secret_output',
    'UnitT50_Confluence_missing_configuration_stops_before_network',
    'UnitT60_Confluence_invalid_configuration_is_redacted_and_offline',
    'UnitT70_Confluence_valid_configuration_verifies_allowed_and_denied_reads',
    'UnitT80_Confluence_over_scoped_token_is_detected',
    'UnitT85_Confluence_unsafe_outside_scope_path_is_rejected',
    'UnitT90_Confluence_failures_are_classified_without_secret_output'
)

foreach ($test in $tests) {
    & $test
    Write-Host "PASS $test"
}

Write-Host 'API access validation tests passed.'
