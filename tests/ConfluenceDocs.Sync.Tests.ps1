# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
$modulePath=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluencePlan.psm1'
$site='https://example.atlassian.net'
$cloud='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
$api="https://api.atlassian.com/ex/confluence/$cloud"

function New-PlanFixture {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('syp171-plan-tests-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    return $root
}
function Remove-PlanFixture {
    param([string]$Root)
    if(-not(Test-Path -LiteralPath $Root)){return}
    $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if([IO.Path]::GetDirectoryName($resolved).TrimEnd('\','/') -cne $parent -or [IO.Path]::GetFileName($resolved) -cnotmatch '^syp171-plan-tests-[a-f0-9]{32}$'){throw 'Unsafe plan fixture delete.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

function New-ValidationFixture {
    return [pscustomobject]@{
        status='valid';siteOrigin=$site;cloudId=$cloud;docsCommit=('1'*40);specCommit=('2'*40)
        codeCommit=('3'*40);sourceDigest=('a'*64);mappingDigest=('b'*64);reviewDigest=('c'*64)
        validatorVersion='1.13.0';rendererVersion='1';scenarioIds=@('SYN-SCN-001')
    }
}
function New-PayloadFixture {
    return @([pscustomobject]@{
        projectionId='req-001';pageId='101';spaceId='55';parentId='99';title='Synthetic SDD'
        bodyStorage='<h2>SYN-SCN-001</h2><p>Expected once</p>';assetChanges=@()
    })
}
function New-PlanHttp {
    return {
        param($Request)
        $script:calls.Add([pscustomobject]@{Method=$Request.Method;Uri=[string]$Request.Uri})
        if($script:remoteMode -eq 'permission') { return [pscustomobject]@{StatusCode=403;Body=@{}} }
        $version=if($script:remoteMode -eq 'version-drift'){8}else{7}
        $body=if($script:remoteMode -eq 'body-drift'){'<p>Changed remotely</p>'}else{'<p>Previous</p>'}
        if($Request.Uri -match 'get-draft=true' -and $script:remoteMode -eq 'draft-drift'){$body='<p>Unpublished draft</p>'}
        $page=@{id='101';spaceId='55';parentId='99';title='Synthetic SDD';status='current';version=@{number=$version};body=@{storage=@{value=$body}}}
        return [pscustomobject]@{StatusCode=200;Body=$page;Headers=@{}}
    }
}
function Invoke-PlanFixture {
    param($Validation)
    if(-not(Test-Path -LiteralPath $modulePath)){throw 'Plan module missing.'}
    Import-Module -Name $modulePath -Force
    $path=Join-Path $script:fixtureRoot 'plan.json'
    return New-ConfluencePreviewPlan -PlanPath $path -Validation $Validation -Payloads (New-PayloadFixture) -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-PlanHttp)
}

}

Describe 'SYP-171 immutable preview and drift' {
    BeforeEach{$script:fixtureRoot=New-PlanFixture;$script:calls=[System.Collections.Generic.List[object]]::new();$script:remoteMode='normal'}
    AfterEach{Remove-PlanFixture -Root $script:fixtureRoot}

    # Scenario: SYP171-SCN-007; one exact mapped page and complete source validation.
    # Purpose: Preview persists the exact payload and remote baseline without writing.
    It 'UnitT10_builds_immutable_update_plan_with_all_payloads' {
        $r=Invoke-PlanFixture (New-ValidationFixture)
        $r.status | Should -Be 'preview'
        $r.planSha256 | Should -Match '^[a-f0-9]{64}$'
        $plan=Get-Content -LiteralPath $r.planPath -Raw | ConvertFrom-Json
        @($plan.pages).Count | Should -Be 1
        $plan.pages[0].action | Should -Be 'update'
        $plan.pages[0].expectedPublishedVersion | Should -Be 7
        $plan.pages[0].expectedDraftObservation | Should -Be 'same-as-published'
        (Test-Path -LiteralPath (Join-Path $script:fixtureRoot $plan.pages[0].payloadPath)) | Should -Be $true
        @($script:calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-010; source digest changed after preview.
    # Purpose: Old plan is rejected before any remote request or write.
    It 'UnitT20_blocks_changed_source_before_HTTP' {
        $r=Invoke-PlanFixture (New-ValidationFixture)
        $script:calls.Clear()
        $new=New-ValidationFixture;$new.sourceDigest='d'*64
        $check=Test-ConfluencePlanDrift -PlanPath $r.planPath -CurrentValidation $new -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-PlanHttp)
        @($check.reasonCodes) | Should -Contain 'SourceChanged'
        $script:calls.Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-010; page version or unpublished draft diverged after preview.
    # Purpose: Preflight stops before update instead of using the new version.
    It 'UnitT30_blocks_remote_version_and_draft_drift_with_zero_write' {
        $r=Invoke-PlanFixture (New-ValidationFixture)
        $script:calls.Clear();$script:remoteMode='version-drift'
        $check=Test-ConfluencePlanDrift -PlanPath $r.planPath -CurrentValidation (New-ValidationFixture) -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-PlanHttp)
        @($check.reasonCodes) | Should -Contain 'RemoteDrift'
        @($script:calls | Where-Object Method -ne 'GET').Count | Should -Be 0
        $script:calls.Clear();$script:remoteMode='draft-drift'
        $check=Test-ConfluencePlanDrift -PlanPath $r.planPath -CurrentValidation (New-ValidationFixture) -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-PlanHttp)
        @($check.reasonCodes) | Should -Contain 'DraftConflict'
        @($script:calls | Where-Object Method -ne 'GET').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-007; the plan bytes changed after review.
    # Purpose: Candidate hash mismatch blocks execution even if the remote remains stable.
    It 'UnitT40_rejects_tampered_plan_bytes_before_HTTP' {
        $r=Invoke-PlanFixture (New-ValidationFixture)
        [IO.File]::AppendAllText($r.planPath,"`n ",[Text.UTF8Encoding]::new($false))
        $script:calls.Clear()
        $check=Test-ConfluencePlanDrift -PlanPath $r.planPath -CurrentValidation (New-ValidationFixture) -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-PlanHttp)
        @($check.reasonCodes) | Should -Contain 'PlanDigestMismatch'
        $script:calls.Count | Should -Be 0
    }
}
