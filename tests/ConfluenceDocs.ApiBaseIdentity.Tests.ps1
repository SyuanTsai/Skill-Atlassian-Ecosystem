# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $transportModule = Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceTransport.psm1'
    $cloudId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $apiBase = "https://api.atlassian.com/ex/confluence/$cloudId"

    Import-Module -Name $transportModule -Force
}

Describe 'SYP-171 Confluence API base identity contract' {
    # Scenario: SYP171-SCN-002; plan and publish callers compare the configured API base as a raw string after trimming trailing slashes.
    # Purpose: Centralizing identity checks must preserve case-sensitive raw-string acceptance and rejection boundaries.
    It 'UnitT10_preserves_raw_trimmed_identity_comparison_boundaries' {
        $upperCloudId = $cloudId.ToUpperInvariant()
        $cases = @(
            [pscustomobject]@{ Name = 'canonical base'; ApiBase = $apiBase; CloudId = $cloudId; Expected = $true }
            [pscustomobject]@{ Name = 'one trailing slash'; ApiBase = "$apiBase/"; CloudId = $cloudId; Expected = $true }
            [pscustomobject]@{ Name = 'multiple trailing slashes'; ApiBase = "$apiBase///"; CloudId = $cloudId; Expected = $true }
            [pscustomobject]@{ Name = 'http scheme'; ApiBase = $apiBase.Replace('https://', 'http://'); CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'foreign host'; ApiBase = $apiBase.Replace('api.atlassian.com', 'api.example.net'); CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'empty API base'; ApiBase = ''; CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'invalid URI text'; ApiBase = 'not an absolute uri'; CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'upper-case scheme'; ApiBase = $apiBase.Replace('https://', 'HTTPS://'); CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'upper-case host'; ApiBase = $apiBase.Replace('api.atlassian.com', 'API.ATLASSIAN.COM'); CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'explicit default port'; ApiBase = $apiBase.Replace('api.atlassian.com', 'api.atlassian.com:443'); CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'non-default port'; ApiBase = $apiBase.Replace('api.atlassian.com', 'api.atlassian.com:444'); CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'userinfo'; ApiBase = $apiBase.Replace('https://', 'https://user@'); CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'query'; ApiBase = "${apiBase}?tenant=other"; CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'fragment'; ApiBase = "$apiBase#tenant=other"; CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'path case'; ApiBase = $apiBase.Replace('/ex/confluence/', '/ex/Confluence/'); CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'cloud id case mismatch'; ApiBase = $apiBase.Replace($cloudId, $upperCloudId); CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'matching upper-case cloud id'; ApiBase = $apiBase.Replace($cloudId, $upperCloudId); CloudId = $upperCloudId; Expected = $true }
            [pscustomobject]@{ Name = 'percent-encoded unreserved cloud id character'; ApiBase = $apiBase.Replace('aaaaaaaa-', '%61aaaaaaa-'); CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'different cloud id'; ApiBase = $apiBase; CloudId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'; Expected = $false }
        )

        foreach ($case in $cases) {
            $actual = Test-ConfluenceApiBaseIdentity -ApiBase $case.ApiBase -CloudId $case.CloudId -ComparisonMode RawTrimmed
            $actual | Should -Be $case.Expected -Because $case.Name
        }
        Test-ConfluenceApiBaseIdentity -ApiBase ($apiBase.Replace('api.atlassian.com', 'api.atlassian.com:443')) -CloudId $cloudId -ComparisonMode rawtrimmed | Should -BeFalse
    }

    # Scenario: SYP171-SCN-002; transport parses an absolute API base and compares its AbsoluteUri after trimming trailing slashes.
    # Purpose: The shared contract must retain System.Uri canonicalization while rejecting identity-changing authority and path variants.
    It 'UnitT20_preserves_absolute_uri_identity_comparison_boundaries' {
        $upperCloudId = $cloudId.ToUpperInvariant()
        $encodedUnreserved = $apiBase.Replace('aaaaaaaa-', '%61aaaaaaa-')
        $cases = @(
            [pscustomobject]@{ Name = 'canonical base'; ApiBase = $apiBase; CloudId = $cloudId; Expected = $true }
            [pscustomobject]@{ Name = 'one trailing slash'; ApiBase = "$apiBase/"; CloudId = $cloudId; Expected = $true }
            [pscustomobject]@{ Name = 'multiple trailing slashes'; ApiBase = "$apiBase///"; CloudId = $cloudId; Expected = $true }
            [pscustomobject]@{ Name = 'http scheme'; ApiBase = $apiBase.Replace('https://', 'http://'); CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'foreign host'; ApiBase = $apiBase.Replace('api.atlassian.com', 'api.example.net'); CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'empty API base'; ApiBase = ''; CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'invalid URI text'; ApiBase = 'not an absolute uri'; CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'upper-case scheme and host'; ApiBase = $apiBase.Replace('https://api.atlassian.com', 'HTTPS://API.ATLASSIAN.COM'); CloudId = $cloudId; Expected = $true }
            [pscustomobject]@{ Name = 'explicit default port'; ApiBase = $apiBase.Replace('api.atlassian.com', 'api.atlassian.com:443'); CloudId = $cloudId; Expected = $true }
            [pscustomobject]@{ Name = 'percent-encoded unreserved cloud id character'; ApiBase = $encodedUnreserved; CloudId = $cloudId; Expected = $true }
            [pscustomobject]@{ Name = 'non-default port'; ApiBase = $apiBase.Replace('api.atlassian.com', 'api.atlassian.com:444'); CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'userinfo'; ApiBase = $apiBase.Replace('https://', 'https://user@'); CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'query'; ApiBase = "${apiBase}?tenant=other"; CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'fragment'; ApiBase = "$apiBase#tenant=other"; CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'path case'; ApiBase = $apiBase.Replace('/ex/confluence/', '/ex/Confluence/'); CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'mismatched cloud id case'; ApiBase = $apiBase.Replace($cloudId, $upperCloudId); CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'matching upper-case cloud id'; ApiBase = $apiBase.Replace($cloudId, $upperCloudId); CloudId = $upperCloudId; Expected = $true }
            [pscustomobject]@{ Name = 'encoded path separator'; ApiBase = "$apiBase%2f"; CloudId = $cloudId; Expected = $false }
            [pscustomobject]@{ Name = 'different cloud id'; ApiBase = $apiBase; CloudId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'; Expected = $false }
        )

        foreach ($case in $cases) {
            $actual = Test-ConfluenceApiBaseIdentity -ApiBase $case.ApiBase -CloudId $case.CloudId -ComparisonMode AbsoluteUri
            $actual | Should -Be $case.Expected -Because $case.Name
        }
    }

    # Scenario: SYP171-SCN-002; tenant validation receives a syntactically parsed API base and a separately supplied Cloud ID.
    # Purpose: The transport call site must still reject invalid or nonmatching Cloud IDs with its existing result code.
    It 'UnitT30_keeps_transport_cloud_id_validation_and_reason_code' {
        $common = @{ ExpectedSiteOrigin = 'https://example.atlassian.net'; ConfiguredSiteOrigin = 'https://example.atlassian.net' }
        Test-ConfluenceTenant @common -ApiBase $apiBase -CloudId $cloudId | Should -BeNullOrEmpty
        Test-ConfluenceTenant @common -ApiBase ($apiBase.Replace('api.atlassian.com', 'API.ATLASSIAN.COM:443')) -CloudId $cloudId | Should -BeNullOrEmpty
        Test-ConfluenceTenant @common -ApiBase $apiBase -CloudId 'not-a-guid' | Should -Be 'ApiBaseMismatch'
        Test-ConfluenceTenant @common -ApiBase $apiBase -CloudId 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' | Should -Be 'ApiBaseMismatch'
        Test-ConfluenceTenant @common -ApiBase 'not an absolute uri' -CloudId $cloudId | Should -Be 'TenantMismatch'
    }
}
