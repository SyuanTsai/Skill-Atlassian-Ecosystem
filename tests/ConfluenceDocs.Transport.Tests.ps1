# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceTransport.psm1'
$cloudId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
$apiBase = "https://api.atlassian.com/ex/confluence/$cloudId"
$site = 'https://example.atlassian.net'
$listing = '/wiki/api/v2/spaces/55/pages?limit=50'

function Invoke-Listing {
    param([Parameter(Mandatory)][scriptblock] $HttpInvoker, [string] $ConfiguredSite = $site)
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw 'ConfluenceTransport production module is missing.' }
    Import-Module -Name $modulePath -Force
    return Get-ConfluenceCollection -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $ConfiguredSite -ApiBase $apiBase -CloudId $cloudId -RelativePath $listing -HttpInvoker $HttpInvoker
}

}

Describe 'SYP-171 Confluence transport completeness' {
    BeforeEach { $script:requestedUris = [System.Collections.Generic.List[string]]::new() }

    # Scenario: SYP171-SCN-001; the selected site and a two-page v2 listing are complete.
    # Purpose: Every read item keeps one identity, with the next cursor fetched before success.
    It 'UnitT10_reads_all_pages_before_claiming_complete_capture' {
        $http = {
            param($Request)
            $script:requestedUris.Add([string] $Request.Uri)
            if ($script:requestedUris.Count -eq 1) {
                return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = @{ results = @(@{ id = '101' }); _links = @{ next = '/wiki/api/v2/spaces/55/pages?cursor=two' } } }
            }
            return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = @{ results = @(@{ id = '102' }); _links = @{} } }
        }
        $result = Invoke-Listing -HttpInvoker $http
        $result.status | Should -Be 'complete'
        @($result.items).Count | Should -Be 2
        $script:requestedUris.Count | Should -Be 2
        $script:requestedUris[1] | Should -Match 'cursor=two'
    }

    # Scenario: SYP171-SCN-002; a next link repeats the already-read cursor.
    # Purpose: A pagination loop must retain the first candidate without a complete PASS.
    It 'UnitT20_reports_partial_on_repeated_cursor' {
        $http = {
            param($Request)
            $script:requestedUris.Add([string] $Request.Uri)
            return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = @{ results = @(@{ id = '101' }); _links = @{ next = $listing } } }
        }
        $result = Invoke-Listing -HttpInvoker $http
        $result.status | Should -Be 'partial'
        @($result.reasonCodes) | Should -Contain 'PaginationLoop'
        @($result.items).Count | Should -Be 1
        $script:requestedUris.Count | Should -Be 1
    }

    # Scenario: SYP171-SCN-002; page two repeats a page ID from page one.
    # Purpose: Title or cursor variation cannot create two source identities for one page.
    It 'UnitT30_reports_partial_on_duplicate_remote_ID' {
        $http = {
            param($Request)
            $script:requestedUris.Add([string] $Request.Uri)
            if ($script:requestedUris.Count -eq 1) {
                return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = @{ results = @(@{ id = '101' }); _links = @{ next = '/wiki/api/v2/spaces/55/pages?cursor=two' } } }
            }
            return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = @{ results = @(@{ id = '101' }); _links = @{} } }
        }
        $result = Invoke-Listing -HttpInvoker $http
        $result.status | Should -Be 'partial'
        @($result.reasonCodes) | Should -Contain 'DuplicateRemoteId'
        @($result.items).Count | Should -Be 1
    }

    # Scenario: SYP171-SCN-002; the selected account loses page-list access mid-pagination.
    # Purpose: Previously read candidates survive, while a 403 cannot become full success.
    It 'UnitT40_reports_partial_on_second_page_permission_failure' {
        $http = {
            param($Request)
            $script:requestedUris.Add([string] $Request.Uri)
            if ($script:requestedUris.Count -eq 1) {
                return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = @{ results = @(@{ id = '101' }); _links = @{ next = '/wiki/api/v2/spaces/55/pages?cursor=two' } } }
            }
            return [pscustomobject]@{ StatusCode = 403; Headers = @{}; Body = @{} }
        }
        $result = Invoke-Listing -HttpInvoker $http
        $result.status | Should -Be 'partial'
        @($result.reasonCodes) | Should -Contain 'RemoteReadDenied'
        @($result.items).Count | Should -Be 1
    }

    # Scenario: SYP171-SCN-002; the server points a pagination link to another host.
    # Purpose: The selected tenant's Authorization must never follow an external next URL.
    It 'UnitT50_rejects_cross_host_pagination_without_following_it' {
        $http = {
            param($Request)
            $script:requestedUris.Add([string] $Request.Uri)
            return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Body = @{ results = @(@{ id = '101' }); _links = @{ next = 'https://other.example/wiki/api/v2/spaces/55/pages?cursor=two' } } }
        }
        $result = Invoke-Listing -HttpInvoker $http
        $result.status | Should -Be 'partial'
        @($result.reasonCodes) | Should -Contain 'UnsafePaginationTarget'
        $script:requestedUris.Count | Should -Be 1
    }

    # Scenario: SYP171-SCN-002; the configured site differs from the site selected for this task.
    # Purpose: An available connector or token for another tenant must not be used as fallback.
    It 'UnitT60_blocks_tenant_mismatch_before_HTTP' {
        $http = { param($Request) $script:requestedUris.Add([string] $Request.Uri); throw 'HTTP must not run' }
        $result = Invoke-Listing -HttpInvoker $http -ConfiguredSite 'https://another.atlassian.net'
        $result.status | Should -Be 'blocked'
        @($result.reasonCodes) | Should -Contain 'TenantMismatch'
        $script:requestedUris.Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-002; transport receives URI spellings that may or may not identify the configured tenant endpoint.
    # Purpose: Preserve AbsoluteUri normalization for scheme, host, default port and unreserved escapes while rejecting authority or query changes.
    It 'UnitT70_preserves_absolute_uri_tenant_identity_variants' {
        $upperCloudId=$cloudId.ToUpperInvariant()
        Import-Module -Name $modulePath -Force
        Test-ConfluenceTenant -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase ($apiBase.Replace('https://api.atlassian.com', 'HTTPS://API.ATLASSIAN.COM:443')) -CloudId $cloudId | Should -BeNullOrEmpty
        Test-ConfluenceTenant -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase ($apiBase.Replace('aaaaaaaa-', '%61aaaaaaa-')) -CloudId $cloudId | Should -BeNullOrEmpty
        Test-ConfluenceTenant -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase ($apiBase + '?tenant=other') -CloudId $cloudId | Should -Be 'ApiBaseMismatch'
        Test-ConfluenceTenant -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $apiBase -CloudId $upperCloudId | Should -BeNullOrEmpty
        Test-ConfluenceTenant -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $apiBase -CloudId 'not-a-guid' | Should -Be 'ApiBaseMismatch'
    }

    # Scenario: Admission accepts an API base whose scheme and host casing differ and whose default HTTPS port is explicit.
    # Purpose: Both the initial reader request and its next link use the admitted canonical URI rather than the raw API-base spelling.
    It 'UnitT75_reads_initial_and_next_pages_with_admitted_canonical_api_base' {
        $admittedApiBase = $apiBase.Replace('https://api.atlassian.com', 'HTTPS://API.ATLASSIAN.COM:443')
        $script:requestedUris = [System.Collections.Generic.List[string]]::new()
        $http = {
            param($Request)
            $script:requestedUris.Add([string]$Request.Uri)
            if($script:requestedUris.Count -eq 1){
                return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=@(@{id='101'});_links=@{next='/wiki/api/v2/spaces/55/pages?cursor=two'}}}
            }
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=@(@{id='102'});_links=@{}}}
        }

        Import-Module -Name $modulePath -Force
        $result = Get-ConfluenceCollection -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $admittedApiBase `
            -CloudId $cloudId -RelativePath $listing -HttpInvoker $http

        $result.status | Should -BeExactly 'complete'
        @($result.items).Count | Should -Be 2
        $script:requestedUris | Should -Be @(
            "$apiBase/wiki/api/v2/spaces/55/pages?limit=50",
            "$apiBase/wiki/api/v2/spaces/55/pages?cursor=two"
        )
    }

    # Scenario: Public Pull and Push entry points accept only safe URI representation differences.
    # Purpose: Trailing slashes are canonicalized while blank values and tenant/API changes fail before authenticated I/O.
    It 'UnitT80_preflights_optional_tenant_settings_without_binding_exceptions' {
        Import-Module -Name $modulePath -Force
        Test-ConfluenceTenantConfiguration -ExpectedSiteOrigin $site -ConfiguredSiteOrigin ($site + '/') -ApiBase ($apiBase + '/') -CloudId $cloudId | Should -BeNullOrEmpty
        Test-ConfluenceTenantConfiguration -ExpectedSiteOrigin $site -ConfiguredSiteOrigin '' -ApiBase $apiBase -CloudId $cloudId | Should -Be 'TenantMismatch'
        Test-ConfluenceTenantConfiguration -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase '' -CloudId $cloudId | Should -Be 'ApiBaseMismatch'
        Test-ConfluenceTenantConfiguration -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $apiBase -CloudId '' | Should -Be 'ApiBaseMismatch'
        Test-ConfluenceTenantConfiguration -ExpectedSiteOrigin $site -ConfiguredSiteOrigin 'https://user:secret@example.atlassian.net' -ApiBase $apiBase -CloudId $cloudId | Should -Be 'TenantMismatch'
        Test-ConfluenceTenantConfiguration -ExpectedSiteOrigin $site -ConfiguredSiteOrigin ($site + '/path') -ApiBase $apiBase -CloudId $cloudId | Should -Be 'TenantMismatch'
        Test-ConfluenceTenantConfiguration -ExpectedSiteOrigin $site -ConfiguredSiteOrigin ($site + '?tenant=other') -ApiBase $apiBase -CloudId $cloudId | Should -Be 'TenantMismatch'
        Test-ConfluenceTenantConfiguration -ExpectedSiteOrigin $site -ConfiguredSiteOrigin ($site + '#other') -ApiBase $apiBase -CloudId $cloudId | Should -Be 'TenantMismatch'
        Test-ConfluenceTenantConfiguration -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase ($apiBase + '?tenant=other') -CloudId $cloudId | Should -Be 'ApiBaseMismatch'
        Test-ConfluenceTenantConfiguration -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $apiBase -CloudId 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' | Should -Be 'ApiBaseMismatch'
    }

    # Scenario: A selected capture scope supplies its own Cloud ID and API base while process configuration can point at another valid tenant.
    # Purpose: Preflight binds configured identity to the selected scope and rejects missing, invalid, or mismatched selected values.
    It 'UnitT85_binds_configured_api_identity_to_selected_scope' {
        Import-Module -Name $modulePath -Force
        $otherCloudId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        $otherApiBase="https://api.atlassian.com/ex/confluence/$otherCloudId"

        Test-ConfluenceTenantConfiguration -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $apiBase -CloudId $cloudId -ExpectedApiBase ($apiBase + '/') -ExpectedCloudId $cloudId | Should -BeNullOrEmpty
        Test-ConfluenceTenantConfiguration -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $otherApiBase -CloudId $otherCloudId -ExpectedApiBase $apiBase -ExpectedCloudId $cloudId | Should -Be 'ApiBaseMismatch'
        Test-ConfluenceTenantConfiguration -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $apiBase -CloudId $cloudId -ExpectedApiBase '' -ExpectedCloudId '' | Should -Be 'ApiBaseMismatch'
        Test-ConfluenceTenantConfiguration -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $apiBase -CloudId $cloudId -ExpectedApiBase ($apiBase + '/not-a-cloud-id') -ExpectedCloudId 'not-a-guid' | Should -Be 'ApiBaseMismatch'
    }

    # Scenario: The configured tenant and selected capture scope use opposite casing for the same GUID in their own valid API routes.
    # Purpose: Cross-scope and own-route validation accept valid D-format GUID hex case differences while preserving route boundaries.
    It 'UnitT90_accepts_GUID_casing_variants_only_across_identity_checks' {
        Import-Module -Name $modulePath -Force
        $upperCloudId=$cloudId.ToUpperInvariant()
        $upperApiBase="https://api.atlassian.com/ex/confluence/$upperCloudId"
        $cases=@(
            @{configuredCloud=$cloudId;configuredApi=$apiBase;selectedCloud=$upperCloudId;selectedApi=$upperApiBase},
            @{configuredCloud=$upperCloudId;configuredApi=$upperApiBase;selectedCloud=$cloudId;selectedApi=$apiBase}
        )
        foreach($case in $cases){
            Test-ConfluenceTenantConfiguration -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $case.configuredApi -CloudId $case.configuredCloud -ExpectedApiBase $case.selectedApi -ExpectedCloudId $case.selectedCloud | Should -BeNullOrEmpty
        }

        Test-ConfluenceTenant -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $apiBase -CloudId $upperCloudId | Should -BeNullOrEmpty
        Test-ConfluenceTenant -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $upperApiBase -CloudId $cloudId | Should -BeNullOrEmpty
    }

    # Scenario: A selected read request uses the same Cloud ID as process configuration with different GUID hex casing.
    # Purpose: The read invoker accepts that tenant spelling while keeping the host, fixed route, wiki prefix, and GET boundary strict.
    It 'UnitT95_read_invoker_allows_only_same_guid_case_segment' {
        Import-Module -Name $modulePath -Force
        $upperCloudId=$cloudId.ToUpperInvariant()
        $upperApiBase="https://api.atlassian.com/ex/confluence/$upperCloudId"
        $script:wireCalls=[System.Collections.Generic.List[string]]::new()
        $wire={
            param($Request)
            $script:wireCalls.Add([string]$Request.Uri)
            return [pscustomobject]@{StatusCode=200;Headers=@{};BodyBytes=[byte[]]@()}
        }
        $invoker=New-ConfluenceReadInvoker -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site `
            -ApiBase $apiBase -CloudId $cloudId -Email 'fixture@example.invalid' -Token 'fixture-token-only' -WireInvoker $wire
        $validUri="$upperApiBase/wiki/api/v2/pages/101?body-format=storage"
        $request=[pscustomobject]@{
            Method='GET';Uri=$validUri;Headers=@{Accept='application/json'};TimeoutSec=30;ResponseLimitBytes=4194304
        }
        $response=& $invoker $request
        $response.StatusCode | Should -Be 200
        $script:wireCalls.Count | Should -Be 1
        $script:wireCalls[0] | Should -BeExactly $validUri

        $compactCloudId=$cloudId.Replace('-', '')
        $bracedCloudId='{' + $cloudId + '}'
        $invalidUris=@(
            'https://api.atlassian.com/ex/confluence/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb/wiki/api/v2/pages/101',
            "https://other.example/ex/confluence/$upperCloudId/wiki/api/v2/pages/101",
            "https://api.atlassian.com/ex/Confluence/$upperCloudId/wiki/api/v2/pages/101",
            "https://user@api.atlassian.com/ex/confluence/$upperCloudId/wiki/api/v2/pages/101",
            "https://api.atlassian.com:444/ex/confluence/$upperCloudId/wiki/api/v2/pages/101",
            "https://api.atlassian.com/ex/confluence/$compactCloudId/wiki/api/v2/pages/101",
            "https://api.atlassian.com/ex/confluence/$bracedCloudId/wiki/api/v2/pages/101",
            "$upperApiBase/other/wiki/api/v2/pages/101",
            "$upperApiBase/Wiki/api/v2/pages/101",
            "$upperApiBase/wiki/api/v2/pages/101#fragment"
        )
        foreach($uri in $invalidUris){
            $request.Uri=$uri
            $errorText=''
            try { & $invoker $request | Out-Null } catch { $errorText=$_.Exception.Message }
            $errorText | Should -Be 'UnsafeReadRequest' -Because $uri
            $script:wireCalls.Count | Should -Be 1 -Because $uri
        }
        $request.Uri=$validUri
        $request.Method='PUT'
        $errorText=''
        try { & $invoker $request | Out-Null } catch { $errorText=$_.Exception.Message }
        $errorText | Should -Be 'UnsafeReadRequest'
        $script:wireCalls.Count | Should -Be 1
    }

    # Scenario: Equivalent compact or braced GUID spellings are supplied instead of canonical D-format route segments.
    # Purpose: The narrow case-only exception must not expand the accepted Cloud ID syntax or alter opaque suffix rules.
    It 'UnitT96_rejects_compact_and_braced_guid_route_expansion' {
        Import-Module -Name $modulePath -Force
        $compactCloudId=$cloudId.Replace('-', '')
        $bracedCloudId='{' + $cloudId + '}'
        $compactApiBase="https://api.atlassian.com/ex/confluence/$compactCloudId"
        $bracedApiBase="https://api.atlassian.com/ex/confluence/$bracedCloudId"

        Test-ConfluenceApiBaseIdentity -ApiBase $compactApiBase -CloudId $cloudId -ComparisonMode RawTrimmed | Should -BeFalse
        Test-ConfluenceApiBaseIdentity -ApiBase $bracedApiBase -CloudId $cloudId -ComparisonMode RawTrimmed | Should -BeFalse
        Test-ConfluenceApiBaseIdentity -ApiBase $apiBase -CloudId $compactCloudId -ComparisonMode RawTrimmed | Should -BeFalse
        Test-ConfluenceApiBaseIdentity -ApiBase $apiBase -CloudId $bracedCloudId -ComparisonMode RawTrimmed | Should -BeFalse
        Test-ConfluenceApiBaseIdentity -ApiBase $compactApiBase -CloudId $cloudId -ComparisonMode AbsoluteUri | Should -BeFalse
        Test-ConfluenceApiBaseIdentity -ApiBase $bracedApiBase -CloudId $cloudId -ComparisonMode AbsoluteUri | Should -BeFalse
        Test-ConfluenceApiBaseIdentity -ApiBase $apiBase -CloudId $compactCloudId -ComparisonMode AbsoluteUri | Should -BeFalse
        Test-ConfluenceApiBaseIdentity -ApiBase $apiBase -CloudId $bracedCloudId -ComparisonMode AbsoluteUri | Should -BeFalse
    }

    # Scenario: Process configuration and a selected scope use compact N and dashed D spellings of the same Cloud ID.
    # Purpose: Reject both mixed representations in Pull-style and Push-style preflights while preserving exact compact matches.
    It 'UnitT100_rejects_mixed_D_N_representation_in_both_preflight_shapes' {
        Import-Module -Name $modulePath -Force
        $compactCloudId=$cloudId.Replace('-', '')
        $compactApiBase="https://api.atlassian.com/ex/confluence/$compactCloudId"
        $cases=@(
            @{configuredCloud=$compactCloudId;configuredApi=$compactApiBase;selectedCloud=$cloudId;selectedApi=$apiBase},
            @{configuredCloud=$cloudId;configuredApi=$apiBase;selectedCloud=$compactCloudId;selectedApi=$compactApiBase}
        )
        $observations=@(foreach($case in $cases){
            [pscustomobject]@{
                configuredCloud=$case.configuredCloud
                selectedCloud=$case.selectedCloud
                withExpectedApiAndCloud=(Test-ConfluenceTenantConfiguration -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $case.configuredApi -CloudId $case.configuredCloud -ExpectedApiBase $case.selectedApi -ExpectedCloudId $case.selectedCloud)
                cloudOnly=(Test-ConfluenceTenantConfiguration -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $case.configuredApi -CloudId $case.configuredCloud -ExpectedCloudId $case.selectedCloud)
            }
        })
        $observationJson=ConvertTo-Json -InputObject $observations -Compress -Depth 8
        @($observations | Where-Object { $_.withExpectedApiAndCloud -cne 'ApiBaseMismatch' }).Count | Should -Be 0 -Because $observationJson
        @($observations | Where-Object { $_.cloudOnly -cne 'ApiBaseMismatch' }).Count | Should -Be 0 -Because $observationJson

        Test-ConfluenceTenantConfiguration -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $compactApiBase -CloudId $compactCloudId -ExpectedApiBase $compactApiBase -ExpectedCloudId $compactCloudId | Should -BeNullOrEmpty
        Test-ConfluenceTenantConfiguration -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $compactApiBase -CloudId $compactCloudId -ExpectedCloudId $compactCloudId | Should -BeNullOrEmpty
    }
}
