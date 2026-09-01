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
    Assert-True ($serialized.IndexOf($Email, [StringComparison]::Ordinal) -lt 0) 'Result exposed the account email canary.'
    Assert-True ($serialized.IndexOf($Token, [StringComparison]::Ordinal) -lt 0) 'Result exposed the token canary.'
    Assert-True ($serialized.IndexOf($encodedCredential, [StringComparison]::Ordinal) -lt 0) 'Result exposed the encoded credential canary.'
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

function New-ConfluenceTransport {
    param(
        [string] $TenantCloudId,
        [int[]] $Statuses,
        [hashtable] $State,
        [int] $ThrowAtCall = -1,
        [string] $ThrowCanary = 'REDACTED_TRANSPORT_CANARY'
    )

    $capturedTenantCloudId = $TenantCloudId
    $capturedStatuses = @($Statuses)
    $capturedState = $State
    $capturedThrowAtCall = $ThrowAtCall
    $capturedThrowCanary = $ThrowCanary
    return {
        param([Uri] $Uri, [hashtable] $Headers)

        $index = [int] $capturedState.Calls
        $capturedState.Calls = $index + 1
        if ($capturedState.ContainsKey('Uris')) {
            $capturedState.Uris = @($capturedState.Uris) + $Uri.AbsoluteUri
        }
        if ($capturedState.ContainsKey('AuthorizationByCall')) {
            $authorizationPresent = $Headers.ContainsKey('Authorization') `
                -and -not [string]::IsNullOrWhiteSpace([string] $Headers.Authorization)
            $capturedState.AuthorizationByCall = @($capturedState.AuthorizationByCall) + $authorizationPresent
        }
        if ($index -eq $capturedThrowAtCall) {
            throw "fixture network failure $capturedThrowCanary"
        }
        if ($index -eq 0) {
            return [pscustomobject]@{
                StatusCode = 200
                Content = (@{ cloudId = $capturedTenantCloudId } | ConvertTo-Json -Compress)
            }
        }

        $statusIndex = $index - 1
        if ($statusIndex -ge $capturedStatuses.Count) {
            throw 'Fixture transport received an unexpected Confluence request.'
        }
        return [pscustomobject]@{ StatusCode = $capturedStatuses[$statusIndex] }
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

# Scenario: A Bitbucket review target supplies only the repository slug or only the pull-request ID.
# Purpose: Incomplete target pairs must be rejected without issuing a misleading pull-request read.
function UnitT35_Bitbucket_incomplete_review_target_is_rejected {
    $email = 'tester@example.invalid'
    $token = 'SYP144_BITBUCKET_INCOMPLETE_TARGET_CANARY'
    $values = @{
        BITBUCKET_API_BASE_URL = 'https://api.bitbucket.org/2.0'
        BITBUCKET_EMAIL = $email
        BITBUCKET_API_TOKEN = $token
        BITBUCKET_WORKSPACE = 'example-workspace'
    }
    $targetCases = @(
        @{ Name = 'repository slug only'; Arguments = @{ RepositorySlug = 'example-repository' } },
        @{ Name = 'pull-request ID only'; Arguments = @{ PullRequestId = 42 } }
    )

    foreach ($targetCase in $targetCases) {
        $state = @{ Calls = 0; AuthorizationPresent = $false; Uris = @() }
        $arguments = @{
            TestConnection = $true
            EnvironmentReader = New-EnvironmentReader $values
            HttpInvoker = New-StatusTransport @(200) $state
        }
        foreach ($name in $targetCase.Arguments.Keys) {
            $arguments[$name] = $targetCase.Arguments[$name]
        }

        $result = & $bitbucketValidator @arguments

        Assert-Equal $state.Calls 1 "Bitbucket $($targetCase.Name) issued a pull-request request."
        Assert-Equal $result.RepositoryReadCheck.Category 'success' "Bitbucket $($targetCase.Name) fixture did not validate repository access."
        Assert-Equal $result.TargetState 'invalid' "Bitbucket $($targetCase.Name) was not classified as an invalid target."
        Assert-True (-not $result.PullRequestReadCheck.Attempted) "Bitbucket $($targetCase.Name) marked the pull-request read as attempted."
        Assert-Equal $result.PullRequestReadCheck.Category 'incomplete-target' "Bitbucket $($targetCase.Name) did not report the incomplete target."
        Assert-True (-not $result.ReadyForReview) "Bitbucket $($targetCase.Name) was reported review-ready."
        Assert-SecretRedacted $result $email $token
    }
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

# Scenario: The browser-facing site URL contains a path or non-default port even though tenant discovery uses the canonical site root.
# Purpose: Reject site bases that could direct tenant lookup away from the canonical Atlassian endpoint.
function UnitT62_Confluence_noncanonical_site_bases_are_rejected {
    $cloudId = '11111111-2222-3333-4444-555555555555'
    foreach ($siteBase in @('https://example.atlassian.net/not-the-site-root', 'https://example.atlassian.net:8443')) {
        $values = @{
            CONFLUENCE_BASE_URL = $siteBase
            CONFLUENCE_EMAIL = 'tester@example.invalid'
            CONFLUENCE_API_TOKEN = 'SYP144_CONFLUENCE_SITE_BASE_CANARY'
            CONFLUENCE_CLOUD_ID = $cloudId
            CONFLUENCE_API_BASE_URL = "https://api.atlassian.com/ex/confluence/$cloudId"
        }

        $result = & $confluenceValidator -EnvironmentReader (New-EnvironmentReader $values)

        Assert-Equal $result.ConfigurationState 'invalid' "Confluence accepted noncanonical site base '$siteBase'."
        Assert-Equal ($result.Inventory | Where-Object Name -eq 'CONFLUENCE_BASE_URL').Validation 'invalid' 'Confluence site-base inventory did not expose the invalid shape.'
    }
}

# Scenario: The configured Cloud ID is the all-zero GUID sentinel rather than a tenant identity.
# Purpose: A parseable placeholder must not pass offline configuration validation.
function UnitT63_Confluence_empty_cloud_id_is_rejected {
    $cloudId = '00000000-0000-0000-0000-000000000000'
    $email = 'tester@example.invalid'
    $token = 'SYP144_CONFLUENCE_EMPTY_CLOUD_ID_CANARY'
    $values = @{
        CONFLUENCE_BASE_URL = 'https://example.atlassian.net'
        CONFLUENCE_EMAIL = $email
        CONFLUENCE_API_TOKEN = $token
        CONFLUENCE_CLOUD_ID = $cloudId
        CONFLUENCE_API_BASE_URL = "https://api.atlassian.com/ex/confluence/$cloudId"
    }

    $result = & $confluenceValidator -EnvironmentReader (New-EnvironmentReader $values)

    Assert-Equal $result.ConfigurationState 'invalid' 'Confluence accepted the all-zero Cloud ID.'
    Assert-Equal ($result.Inventory | Where-Object Name -eq 'CONFLUENCE_CLOUD_ID').Validation 'invalid' 'Confluence Cloud-ID inventory did not expose the invalid sentinel.'
    Assert-SecretRedacted $result $email $token
}

# Scenario: The configured site belongs to a different tenant than the supplied Cloud ID and scoped API base.
# Purpose: Prevent a syntactically valid but mismatched tenant from being marked ready or receiving credentials.
function UnitT65_Confluence_site_and_cloud_identity_must_match {
    $configuredCloudId = '11111111-2222-3333-4444-555555555555'
    $actualCloudId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    $email = 'tester@example.invalid'
    $token = 'SYP144_CONFLUENCE_TENANT_MISMATCH_CANARY'
    $values = @{
        CONFLUENCE_BASE_URL = 'https://example.atlassian.net'
        CONFLUENCE_EMAIL = $email
        CONFLUENCE_API_TOKEN = $token
        CONFLUENCE_CLOUD_ID = $configuredCloudId
        CONFLUENCE_API_BASE_URL = "https://api.atlassian.com/ex/confluence/$configuredCloudId"
    }
    $state = @{ Calls = 0; Uris = @(); AuthorizationByCall = @() }
    $result = & $confluenceValidator `
        -TestConnection `
        -EnvironmentReader (New-EnvironmentReader $values) `
        -HttpInvoker (New-ConfluenceTransport $actualCloudId @() $state)

    Assert-Equal $state.Calls 1 'Confluence tenant mismatch issued an authenticated API request.'
    Assert-Equal $state.Uris[0] 'https://example.atlassian.net/_edge/tenant_info' 'Confluence tenant lookup URI is incorrect.'
    Assert-True (-not $state.AuthorizationByCall[0]) 'Confluence tenant lookup included Authorization.'
    Assert-Equal $result.ConfigurationState 'invalid' 'Confluence tenant mismatch was not classified as invalid.'
    Assert-Equal $result.TenantIdentityState 'mismatch' 'Confluence tenant mismatch was not reported.'
    Assert-True (-not $result.ReadyForRead) 'Confluence tenant mismatch was reported read-ready.'
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
    $state = @{ Calls = 0; Uris = @(); AuthorizationByCall = @() }
    $result = & $confluenceValidator `
        -TestConnection `
        -OutOfScopeReadPath '/wiki/api/v2/attachments?limit=1' `
        -EnvironmentReader (New-EnvironmentReader $values) `
        -HttpInvoker (New-ConfluenceTransport $cloudId @(200, 200, 403) $state)

    Assert-Equal $result.ConfigurationState 'valid' 'Confluence valid-state classification failed.'
    Assert-Equal $result.TenantIdentityState 'match' 'Confluence tenant identity was not verified.'
    Assert-Equal $state.Calls 4 'Confluence validation did not test tenant, space, page, and denied reads.'
    Assert-Equal $state.Uris[0] 'https://example.atlassian.net/_edge/tenant_info' 'Confluence tenant lookup URI is incorrect.'
    Assert-Equal $state.Uris[1] "https://api.atlassian.com/ex/confluence/$cloudId/wiki/api/v2/spaces?limit=1" 'Confluence space-read URI is incorrect.'
    Assert-Equal $state.Uris[2] "https://api.atlassian.com/ex/confluence/$cloudId/wiki/api/v2/pages?limit=1" 'Confluence page-read URI is incorrect.'
    Assert-Equal $state.Uris[3] "https://api.atlassian.com/ex/confluence/$cloudId/wiki/api/v2/attachments?limit=1" 'Confluence outside-scope URI is incorrect.'
    Assert-True (-not $state.AuthorizationByCall[0]) 'Confluence tenant lookup included Authorization.'
    Assert-True ($state.AuthorizationByCall[1] -and $state.AuthorizationByCall[2] -and $state.AuthorizationByCall[3]) 'Confluence API reads omitted in-memory authentication.'
    Assert-True $result.ReadyForRead 'Confluence successful space read was not reported ready.'
    Assert-Equal $result.LeastPrivilegeState 'expected-denial-observed' 'Confluence expected outside-scope denial was not recorded.'
    Assert-True (-not $result.ReadyForPublishing) 'Read-only validation incorrectly proved write readiness.'
    Assert-SecretRedacted $result $email $token
}

# Scenario: Tenant and space validation succeed, but the token lacks Confluence page-read scope.
# Purpose: Read readiness must require every read path needed by the publishing workflow.
function UnitT75_Confluence_page_read_is_required_for_readiness {
    $email = 'tester@example.invalid'
    $token = 'SYP144_CONFLUENCE_PAGE_READ_CANARY'
    $cloudId = '11111111-2222-3333-4444-555555555555'
    $values = @{
        CONFLUENCE_BASE_URL = 'https://example.atlassian.net'
        CONFLUENCE_EMAIL = $email
        CONFLUENCE_API_TOKEN = $token
        CONFLUENCE_CLOUD_ID = $cloudId
        CONFLUENCE_API_BASE_URL = "https://api.atlassian.com/ex/confluence/$cloudId"
    }
    $state = @{ Calls = 0; Uris = @(); AuthorizationByCall = @() }
    $result = & $confluenceValidator `
        -TestConnection `
        -EnvironmentReader (New-EnvironmentReader $values) `
        -HttpInvoker (New-ConfluenceTransport $cloudId @(200, 403) $state)

    Assert-Equal $result.SpaceReadCheck.Category 'success' 'Confluence space-read fixture did not succeed.'
    Assert-Equal $result.PageReadCheck.Category 'permission-or-scope' 'Confluence page-read failure was not classified.'
    Assert-True (-not $result.ReadyForRead) 'Confluence missing page-read scope was reported read-ready.'
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
    $state = @{ Calls = 0; Uris = @(); AuthorizationByCall = @() }
    $result = & $confluenceValidator `
        -TestConnection `
        -OutOfScopeReadPath '/wiki/api/v2/attachments?limit=1' `
        -EnvironmentReader (New-EnvironmentReader $values) `
        -HttpInvoker (New-ConfluenceTransport $cloudId @(200, 200, 200) $state)

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
    $state = @{ Calls = 0; Uris = @(); AuthorizationByCall = @() }
    $result = & $confluenceValidator `
        -TestConnection `
        -OutOfScopeReadPath '/wiki/api/../unsafe' `
        -EnvironmentReader (New-EnvironmentReader $values) `
        -HttpInvoker (New-ConfluenceTransport $cloudId @(200, 200) $state)

    Assert-Equal $state.Calls 3 'Confluence unsafe outside-scope path issued a secondary request.'
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
        $state = @{ Calls = 0; Uris = @(); AuthorizationByCall = @() }
        $result = & $confluenceValidator -TestConnection -OutOfScopeReadPath '/wiki/api/v2/attachments?limit=1' -EnvironmentReader (New-EnvironmentReader $values) -HttpInvoker (New-ConfluenceTransport $cloudId @([int]$status, 200) $state)
        Assert-Equal $result.SpaceReadCheck.Category $expectedCategories[$status] "Confluence HTTP $status classification failed."
        Assert-Equal $state.Calls 3 "Confluence HTTP $status primary failure issued an outside-scope request."
        Assert-SecretRedacted $result $email $token
    }

    $networkState = @{ Calls = 0; Uris = @(); AuthorizationByCall = @() }
    $networkResult = & $confluenceValidator -TestConnection -EnvironmentReader (New-EnvironmentReader $values) -HttpInvoker (New-ConfluenceTransport $cloudId @(200) $networkState 1 $token)
    Assert-Equal $networkResult.SpaceReadCheck.Category 'network-or-tls' 'Confluence network classification failed.'
    Assert-SecretRedacted $networkResult $email $token
}

$tests = @(
    'UnitT05_Default_environment_readers_support_offline_inventory',
    'UnitT10_Bitbucket_missing_configuration_stops_before_network',
    'UnitT20_Bitbucket_invalid_configuration_is_redacted_and_offline',
    'UnitT30_Bitbucket_valid_configuration_checks_both_read_paths',
    'UnitT35_Bitbucket_incomplete_review_target_is_rejected',
    'UnitT40_Bitbucket_failures_are_classified_without_secret_output',
    'UnitT50_Confluence_missing_configuration_stops_before_network',
    'UnitT60_Confluence_invalid_configuration_is_redacted_and_offline',
    'UnitT62_Confluence_noncanonical_site_bases_are_rejected',
    'UnitT63_Confluence_empty_cloud_id_is_rejected',
    'UnitT65_Confluence_site_and_cloud_identity_must_match',
    'UnitT70_Confluence_valid_configuration_verifies_allowed_and_denied_reads',
    'UnitT75_Confluence_page_read_is_required_for_readiness',
    'UnitT80_Confluence_over_scoped_token_is_detected',
    'UnitT85_Confluence_unsafe_outside_scope_path_is_rejected',
    'UnitT90_Confluence_failures_are_classified_without_secret_output'
)

foreach ($test in $tests) {
    & $test
    Write-Host "PASS $test"
}

Write-Host 'API access validation tests passed.'
