# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
$module=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluencePlan.psm1'
$site='https://example.atlassian.net'
$cloud='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
$api="https://api.atlassian.com/ex/confluence/$cloud"

function New-CreateFixture {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('syp171-create-preview-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    return $root
}
function Remove-CreateFixture {
    param([string]$Root)
    $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if([IO.Path]::GetDirectoryName($resolved).TrimEnd('\','/') -cne $parent -or [IO.Path]::GetFileName($resolved) -cnotmatch '^syp171-create-preview-[a-f0-9]{32}$'){throw 'Unsafe create fixture delete'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
function New-CreateValidation {
    return [pscustomobject]@{status='valid';siteOrigin=$site;cloudId=$cloud;docsCommit=('1'*40);specCommit=('2'*40);codeCommit=('3'*40);sourceDigest=('a'*64);mappingDigest=('b'*64);reviewDigest=('c'*64);validatorVersion='1.13.0';rendererVersion='1';scenarioIds=@('SYP171-SCN-011')}
}
function New-CreateHttp {
    return {
        param($Request)
        $script:calls.Add([string]$Request.Uri)
        if($Request.Uri -match '/spaces/55/pages'){
            $items=@()
            if($script:collision){$items=@(@{id='777';spaceId='55';parentId='99';title='Synthetic new SDD';status='current'})}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=$items;_links=@{}}}
        }
        $version=if($script:parentDrift){8}else{7}
        return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='99';spaceId='55';parentId='10';title='Synthetic parent';status='current';version=@{number=$version};body=@{storage=@{value='<p>Parent</p>'}}}}
    }
}
function Invoke-CreatePreview {
    Import-Module -Name $module -Force
    $payload=@([pscustomobject]@{projectionId='req-new';pageId=$null;spaceId='55';parentId='99';title='Synthetic new SDD';bodyStorage='<h2>SYP171-SCN-011</h2>';assetChanges=@()})
    return New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixture 'plan.json') -Validation (New-CreateValidation) -Payloads $payload -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-CreateHttp)
}

}

Describe 'SYP-171 create candidate preflight' {
    BeforeEach{$script:fixture=New-CreateFixture;$script:calls=[System.Collections.Generic.List[string]]::new();$script:collision=$false;$script:parentDrift=$false}
    AfterEach{Remove-CreateFixture -Root $script:fixture}

    # Scenario: SYP171-SCN-011; only a new title under an exact parent can enter the immutable plan.
    # Purpose: The preview records parent version and does not claim ownership by title.
    It 'UnitT10_previews_create_with_parent_baseline_and_no_write' {
        $r=Invoke-CreatePreview
        $r.status | Should -Be 'preview'
        $plan=Get-Content -LiteralPath $r.planPath -Raw|ConvertFrom-Json
        $plan.pages[0].action | Should -Be 'create'
        $plan.pages[0].expectedParentVersion | Should -Be 7
        $plan.pages[0].pageId | Should -Be ''
        $plan.pages[0].intermediateWrites.GetType().IsArray | Should -Be $true
        @($plan.pages[0].intermediateWrites) | Should -Be @('create')
        $script:calls.Count | Should -BeGreaterThan 0
    }

    # Scenario: SYP171-SCN-010/011; collision or parent change blocks the old candidate.
    # Purpose: A title match cannot be silently repurposed as an existing mapped page.
    It 'UnitT20_blocks_collision_and_parent_drift_before_create' {
        $script:collision=$true
        (Invoke-CreatePreview).status | Should -Be 'blocked'
        $script:collision=$false
        $r=Invoke-CreatePreview
        $script:parentDrift=$true
        $check=Test-ConfluencePlanDrift -PlanPath $r.planPath -CurrentValidation (New-CreateValidation) -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-CreateHttp)
        @($check.reasonCodes) | Should -Contain 'CreateTargetDrift'
    }

    # Scenario: SYP171-SCN-011; a new child may refer to a new parent in the same immutable operation.
    # Purpose: The parent must appear first, while the child keeps a projection dependency until the server ID is confirmed.
    It 'UnitT30_orders_new_parent_before_child_without_inventing_child_parent_id' {
        Import-Module -Name $module -Force
        $payloads=@(
            [pscustomobject]@{projectionId='req-child';pageId=$null;spaceId='55';parentId='';parentProjectionId='req-parent';title='Synthetic child';bodyStorage='<p>Child</p>';assetChanges=@()},
            [pscustomobject]@{projectionId='req-parent';pageId=$null;spaceId='55';parentId='99';title='Synthetic parent page';bodyStorage='<p>Parent page</p>';assetChanges=@()}
        )
        $r=New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixture 'plan.json') -Validation (New-CreateValidation) -Payloads $payloads -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-CreateHttp)
        $r.status | Should -Be 'preview'
        $plan=Get-Content -LiteralPath $r.planPath -Raw|ConvertFrom-Json
        @($plan.pages.projectionId) | Should -Be @('req-parent','req-child')
        $plan.pages[1].parentProjectionId | Should -Be 'req-parent'
        $plan.pages[1].parentId | Should -Be ''
    }

    # Scenario: SYP171-SCN-011; missing/cyclic/cross-space parent dependencies are not publication candidates.
    # Purpose: Reject the entire operation before any remote read or write.
    It 'UnitT40_rejects_unresolvable_new_parent_graph_before_remote_io' {
        Import-Module -Name $module -Force
        $child=[pscustomobject]@{projectionId='req-child';pageId=$null;spaceId='55';parentId='';parentProjectionId='req-parent';title='Synthetic child';bodyStorage='<p>Child</p>';assetChanges=@()}
        $parent=[pscustomobject]@{projectionId='req-parent';pageId=$null;spaceId='55';parentId='';parentProjectionId='req-child';title='Synthetic parent page';bodyStorage='<p>Parent</p>';assetChanges=@()}
        $r=New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixture 'cycle.json') -Validation (New-CreateValidation) -Payloads @($child,$parent) -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-CreateHttp)
        $r.status | Should -Be 'invalid'
        $script:calls.Count | Should -Be 0
        $parent.parentProjectionId='req-missing'
        $r=New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixture 'missing.json') -Validation (New-CreateValidation) -Payloads @($child,$parent) -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-CreateHttp)
        $r.status | Should -Be 'invalid'
        $script:calls.Count | Should -Be 0
        $parent.parentProjectionId='';$parent.parentId='99';$parent.spaceId='66'
        $r=New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixture 'cross-space.json') -Validation (New-CreateValidation) -Payloads @($child,$parent) -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-CreateHttp)
        $r.status | Should -Be 'invalid'
        $script:calls.Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-004/011; two new pages use source-bound links to each other's future identity.
    # Purpose: Preview freezes exact templates and lists both intermediate creates before any final body write.
    It 'UnitT50_previews_linked_new_pages_as_explicit_identity_first_plan' {
        Import-Module -Name $module -Force
        $payloads=@(
            [pscustomobject]@{projectionId='req-a';pageId=$null;spaceId='55';parentId='99';title='Linked A';bodyStorage='<p><a href="https://example.atlassian.net/wiki/pages/viewpage.action?pageId=__SYP171_LINK_req-b__">B</a></p>';deferredTargets=@('req-b');assetChanges=@()},
            [pscustomobject]@{projectionId='req-b';pageId=$null;spaceId='55';parentId='99';title='Linked B';bodyStorage='<p><a href="https://example.atlassian.net/wiki/pages/viewpage.action?pageId=__SYP171_LINK_req-a__">A</a></p>';deferredTargets=@('req-a');assetChanges=@()}
        )
        $r=New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixture 'linked.json') -Validation (New-CreateValidation) -Payloads $payloads -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-CreateHttp)
        $r.status | Should -Be 'preview'
        $plan=Get-Content -LiteralPath $r.planPath -Raw|ConvertFrom-Json
        $plan.schemaVersion | Should -Be 2
        $plan.linkStrategy | Should -Be 'identity-first'
        @($plan.pages[0].deferredTargets) | Should -Contain 'req-b'
        @($plan.pages[0].intermediateWrites) | Should -Contain 'page-create-intermediate'
        @($plan.pages[0].intermediateWrites) | Should -Contain 'final-page-body-update'
        $script:calls.Count | Should -BeGreaterThan 0
    }

    # Scenario: SYP171-SCN-009/011; a deferred link target is absent or its template does not match the binding.
    # Purpose: An incomplete href never reaches Confluence as a normal version-one payload.
    It 'UnitT60_rejects_unbound_or_unmarked_deferred_link_before_remote_io' {
        Import-Module -Name $module -Force
        $a=[pscustomobject]@{projectionId='req-a';pageId=$null;spaceId='55';parentId='99';title='Linked A';bodyStorage='<p><a href="https://example.atlassian.net/wiki/pages/viewpage.action?pageId=__SYP171_LINK_req-b__">B</a></p>';deferredTargets=@('req-b');assetChanges=@()}
        $b=[pscustomobject]@{projectionId='req-b';pageId=$null;spaceId='55';parentId='99';title='Linked B';bodyStorage='<p>B</p>';deferredTargets=@();assetChanges=@()}
        $a.deferredTargets=@('req-missing')
        $r=New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixture 'missing-link.json') -Validation (New-CreateValidation) -Payloads @($a,$b) -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-CreateHttp)
        $r.status | Should -Be 'invalid'
        $script:calls.Count | Should -Be 0
        $a.deferredTargets=@('req-b');$a.bodyStorage='<p><a href="https://example.atlassian.net/wiki/pages/viewpage.action?pageId=999">B</a></p>'
        $r=New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixture 'unmarked-link.json') -Validation (New-CreateValidation) -Payloads @($a,$b) -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-CreateHttp)
        $r.status | Should -Be 'invalid'
        $script:calls.Count | Should -Be 0
        $a.bodyStorage='<p><a href="https://example.atlassian.net/wiki/pages/viewpage.action?pageId=__SYP171_LINK_req-b__">B</a></p>';$a.PSObject.Properties.Remove('deferredTargets')
        $r=New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixture 'unclaimed-token.json') -Validation (New-CreateValidation) -Payloads @($a,$b) -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-CreateHttp)
        $r.status | Should -Be 'invalid'
        $script:calls.Count | Should -Be 0
        $a|Add-Member -NotePropertyName deferredTargets -NotePropertyValue @('req-b')
        $a.bodyStorage='<p><a href="https://example.atlassian.net/wiki/pages/viewpage.action?pageId=__SYP171_LINK_req-b__">B</a> __SYP171_LINK_bad-token</p>'
        $r=New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixture 'extra-token.json') -Validation (New-CreateValidation) -Payloads @($a,$b) -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-CreateHttp)
        $r.status | Should -Be 'invalid'
        $script:calls.Count | Should -Be 0
    }
}
