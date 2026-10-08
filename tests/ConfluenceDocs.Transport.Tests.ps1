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
}
