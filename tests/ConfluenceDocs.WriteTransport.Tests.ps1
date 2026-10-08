# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
$modulePath=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceTransport.psm1'
$assetModulePath=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceAssets.psm1'
$site='https://example.atlassian.net'
$cloud='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
$api="https://api.atlassian.com/ex/confluence/$cloud"

}

Describe 'SYP-171 exact authenticated write transport' {
    BeforeEach{$script:wire=[System.Collections.Generic.List[object]]::new()}

    # Scenario: SYP171-SCN-007; exact mapped update is authorized upstream.
    # Purpose: Only the selected API page path receives a bounded authenticated PUT.
    It 'UnitT10_sends_one_exact_page_put_with_bounded_body' {
        Import-Module -Name $modulePath -Force
        $fake={param($Request)$script:wire.Add($Request);return [pscustomobject]@{StatusCode=200;Headers=@{};BodyBytes=[Text.Encoding]::UTF8.GetBytes('{"id":"101"}')}}
        $invoker=New-ConfluenceOperationInvoker -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $api -CloudId $cloud -Email 'synthetic@example.invalid' -Token 'synthetic-token' -WireInvoker $fake
        $request=[pscustomobject]@{Method='PUT';Uri="$api/wiki/api/v2/pages/101";Headers=@{Accept='application/json';'Content-Type'='application/json'};Body='{"id":"101"}';AuthAllowed=$true;TimeoutSec=30;ResponseLimitBytes=4MB}
        $result=& $invoker $request
        $result.StatusCode | Should -Be 200
        $script:wire.Count | Should -Be 1
        $script:wire[0].Authorization | Should -Match '^Basic '
        $script:wire[0].Method | Should -Be 'PUT'
        $script:wire[0].Body | Should -Be '{"id":"101"}'
    }

    # Scenario: SYP171-SCN-007; the path or tenant differs from the plan.
    # Purpose: Credentials and body are not forwarded to any other endpoint.
    It 'UnitT20_rejects_wrong_host_and_unrelated_write_path_before_wire' {
        Import-Module -Name $modulePath -Force
        $fake={param($Request)$script:wire.Add($Request);throw 'Should not run'}
        $invoker=New-ConfluenceOperationInvoker -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $api -CloudId $cloud -Email 'synthetic@example.invalid' -Token 'synthetic-token' -WireInvoker $fake
        {& $invoker ([pscustomobject]@{Method='PUT';Uri='https://other.atlassian.net/wiki/api/v2/pages/101';Headers=@{};Body='{}';AuthAllowed=$true;TimeoutSec=30;ResponseLimitBytes=4MB})}|Should -Throw
        {& $invoker ([pscustomobject]@{Method='PUT';Uri="$api/wiki/api/v2/spaces/55";Headers=@{};Body='{}';AuthAllowed=$true;TimeoutSec=30;ResponseLimitBytes=4MB})}|Should -Throw
        $script:wire.Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-011; the PUT response is uncertain.
    # Purpose: Transport makes one attempt and leaves reconciliation to the operation journal.
    It 'UnitT30_never_retries_uncertain_write' {
        Import-Module -Name $modulePath -Force
        $fake={param($Request)$script:wire.Add($Request);throw 'Synthetic timeout'}
        $invoker=New-ConfluenceOperationInvoker -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $api -CloudId $cloud -Email 'synthetic@example.invalid' -Token 'synthetic-token' -WireInvoker $fake
        {& $invoker ([pscustomobject]@{Method='PUT';Uri="$api/wiki/api/v2/pages/101";Headers=@{};Body='{}';AuthAllowed=$true;TimeoutSec=30;ResponseLimitBytes=4MB})}|Should -Throw
        $script:wire.Count | Should -Be 1
    }

    # Scenario: SYP171-SCN-011; a write endpoint returns a redirect.
    # Purpose: Redirects are not followed with Authorization or an uncertain POST/PUT.
    It 'UnitT40_rejects_redirected_write_without_followup' {
        Import-Module -Name $modulePath -Force
        $fake={param($Request)$script:wire.Add($Request);return [pscustomobject]@{StatusCode=302;Headers=@{Location='https://elsewhere.invalid/opaque'};BodyBytes=[byte[]]@()}}
        $invoker=New-ConfluenceOperationInvoker -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $api -CloudId $cloud -Email 'synthetic@example.invalid' -Token 'synthetic-token' -WireInvoker $fake
        {& $invoker ([pscustomobject]@{Method='PUT';Uri="$api/wiki/api/v2/pages/101";Headers=@{};Body='{}';AuthAllowed=$true;TimeoutSec=30;ResponseLimitBytes=4MB})}|Should -Throw
        $script:wire.Count | Should -Be 1
    }

    # Scenario: SYP171-SCN-012; a fixed binary attachment upload is approved upstream.
    # Purpose: Operation transport forwards exact multipart bytes and mandatory Atlassian token to only the selected page attachment path.
    It 'UnitT50_forwards_exact_binary_attachment_multipart_to_selected_page' {
        Import-Module -Name $assetModulePath -Force
        Import-Module -Name $modulePath -Force
        $bytes=[byte[]]@(0,255,13,10,42,128)
        $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $asset=[pscustomobject]@{remoteFilename="syp171-req-001-$sha.png";mediaType='image/png';sha256=$sha;byteLength=$bytes.Length}
        $request=New-ManagedAttachmentUploadRequest -ApiBase $api -PageId '101' -Asset $asset -ProjectionId 'req-001' -OperationId ('a'*32) -Bytes $bytes
        $fake={param($Request)$script:wire.Add($Request);return [pscustomobject]@{StatusCode=200;Headers=@{};BodyBytes=[Text.Encoding]::UTF8.GetBytes('{}')}}
        $invoker=New-ConfluenceOperationInvoker -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $api -CloudId $cloud -Email 'synthetic@example.invalid' -Token 'synthetic-token' -WireInvoker $fake
        (& $invoker $request).StatusCode | Should -Be 200
        $script:wire.Count | Should -Be 1
        $script:wire[0].Uri | Should -Be "$api/wiki/rest/api/content/101/child/attachment"
        $script:wire[0].Headers['X-Atlassian-Token'] | Should -Be 'nocheck'
        $script:wire[0].Authorization | Should -Match '^Basic '
        $script:wire[0].BodyBytes -is [byte[]] | Should -Be $true
        $script:wire[0].BodyBytes.Length | Should -Be $request.BodyBytes.Length
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($script:wire[0].BodyBytes)) | Should -Be ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($request.BodyBytes)))
    }

    # Scenario: SYP171-SCN-007/012; an upload is redirected to another page or misses the required CSRF header.
    # Purpose: Credentials and binary bytes never reach a second tenant, unrelated endpoint, or malformed upload envelope.
    It 'UnitT60_rejects_wrong_attachment_endpoint_or_missing_token_before_wire' {
        Import-Module -Name $modulePath -Force
        $fake={param($Request)$script:wire.Add($Request);throw 'Should not run'}
        $invoker=New-ConfluenceOperationInvoker -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $site -ApiBase $api -CloudId $cloud -Email 'synthetic@example.invalid' -Token 'synthetic-token' -WireInvoker $fake
        $headers=@{Accept='application/json';'Content-Type'='multipart/form-data; boundary=test-boundary';'X-Atlassian-Token'='nocheck'}
        $base=[pscustomobject]@{Method='POST';Uri="$api/wiki/rest/api/content/101/child/attachment";Headers=$headers;BodyBytes=[byte[]]@(1,2,3);Body=$null;AuthAllowed=$true;TimeoutSec=30;ResponseLimitBytes=4MB}
        $base.Uri='https://other.atlassian.net/wiki/rest/api/content/101/child/attachment'
        {& $invoker $base}|Should -Throw
        $base.Uri="$api/wiki/rest/api/content/101/child/attachment/900"
        {& $invoker $base}|Should -Throw
        $base.Uri="$api/wiki/rest/api/content/101/child/attachment";$base.Headers['X-Atlassian-Token']=''
        {& $invoker $base}|Should -Throw
        $script:wire.Count | Should -Be 0
    }
}
