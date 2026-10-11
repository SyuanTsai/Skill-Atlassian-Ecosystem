# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
$planModule=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluencePlan.psm1'
$publishModule=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluencePublish.psm1'
$site='https://example.atlassian.net'
$cloud='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
$api="https://api.atlassian.com/ex/confluence/$cloud"

function New-MultiFixture {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('syp171-multipage-tests-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    return $root
}
function Remove-MultiFixture {
    param([string]$Root)
    if(-not(Test-Path -LiteralPath $Root)){return}
    $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if([IO.Path]::GetDirectoryName($resolved).TrimEnd('\','/') -cne $parent -or [IO.Path]::GetFileName($resolved) -cnotmatch '^syp171-multipage-tests-[a-f0-9]{32}$'){throw 'Unsafe multi fixture delete.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
function New-MultiValidation {
    return [pscustomobject]@{status='valid';siteOrigin=$site;cloudId=$cloud;docsCommit=('1'*40);specCommit=('2'*40);codeCommit=('3'*40);sourceDigest=('a'*64);mappingDigest=('b'*64);reviewDigest=('c'*64);validatorVersion='1.13.0';rendererVersion='1';scenarioIds=@('SYN-SCN-001','SYN-SCN-002')}
}
function New-MultiHttp {
    return {
        param($Request)
        $uri=[Uri]$Request.Uri
        $id=if($uri.AbsolutePath -match '/pages/(101|102|103)$'){$Matches[1]}else{throw 'Unexpected path'}
        $script:calls.Add([pscustomobject]@{Method=$Request.Method;PageId=$id})
        $state=$script:pages[$id]
        if($Request.Method -eq 'PUT'){
            $body=$Request.Body|ConvertFrom-Json -AsHashtable
            $state.version++
            $state.storage=$body.body.value
            $state.draftVersion=$state.version
            $state.draftStorage=$state.storage
            $state.marker=$body.version.message
            if($id -eq '102' -and $script:mode -eq 'second-timeout'){$script:expectedSecondMarker=$state.marker;$state.marker='';throw 'Synthetic response timeout on page 102'}
            return [pscustomobject]@{StatusCode=200;Body=@{id=$id;version=@{number=$state.version}};Headers=@{}}
        }
        $draft=$uri.Query -match 'get-draft=true'
        $version=if($draft -and $state.ContainsKey('draftVersion')){$state.draftVersion}else{$state.version}
        $storage=if($draft -and $state.ContainsKey('draftStorage')){$state.draftStorage}else{$state.storage}
        $body=@{id=$id;spaceId='55';parentId='99';title="Synthetic $id";status='current';version=@{number=$version;message=$state.marker};body=@{storage=@{value=$storage}}}
        return [pscustomobject]@{StatusCode=200;Body=$body;Headers=@{}}
    }
}
function New-MultiPlan {
    param([switch]$IncludeNoOpPage)
    Import-Module -Name $planModule -Force
    $payloads=@(
        [pscustomobject]@{projectionId='req-001';pageId='101';spaceId='55';parentId='99';title='Synthetic 101';bodyStorage='<p>New one</p>';assetChanges=@()},
        [pscustomobject]@{projectionId='req-002';pageId='102';spaceId='55';parentId='99';title='Synthetic 102';bodyStorage='<p>New two</p>';assetChanges=@()}
    )
    if($IncludeNoOpPage){$payloads+=,[pscustomobject]@{projectionId='req-003';pageId='103';spaceId='55';parentId='99';title='Synthetic 103';bodyStorage='<p>Stable three</p>';assetChanges=@()}}
    $r=New-ConfluencePreviewPlan -PlanPath (Join-Path $script:root 'plan.json') -Validation (New-MultiValidation) -Payloads $payloads -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-MultiHttp)
    if($r.status -ne 'preview'){throw "Multi preview failed: $($r.reasonCodes -join ',')"}
    $plan=Get-Content -LiteralPath $r.planPath -Raw|ConvertFrom-Json
    $op=$plan.operationId
    $approvedActions=@($plan.pages|Where-Object action -ne 'no-op'|ForEach-Object {"$($_.action):$($_.pageId)"})
    $auth=@{schemaVersion=1;planSha256=$r.planSha256;operationId=$op;siteOrigin=$site;cloudId=$cloud;approvedActions=$approvedActions;approvalEvidenceRef='synthetic-test-fixture-only'}
    $path=Join-Path $script:root 'auth.json'
    [IO.File]::WriteAllText($path,($auth|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{plan=$r.planPath;auth=$path;journal=(Join-Path $script:root 'journal.json');sync=(Join-Path $script:root 'sync.json')}
}
function Invoke-MultiPublish {
    param($Fixture)
    Import-Module -Name $publishModule -Force
    return Invoke-ConfluencePlan -PlanPath $Fixture.plan -CurrentValidation (New-MultiValidation) -AuthorizationPath $Fixture.auth -JournalPath $Fixture.journal -SyncPath $Fixture.sync -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-MultiHttp)
}

}

Describe 'SYP-171 multi-page partial journal resume' {
    BeforeEach{
        $script:root=New-MultiFixture
        $script:pages=@{'101'=@{version=7;storage='<p>Old one</p>';marker=''};'102'=@{version=7;storage='<p>Old two</p>';marker=''};'103'=@{version=7;storage='<p>Stable three</p>';marker=''}}
        $script:calls=[System.Collections.Generic.List[object]]::new();$script:mode='normal';$script:expectedSecondMarker=''
    }
    AfterEach{Remove-MultiFixture -Root $script:root}

    # Scenario: SYP171-SCN-011; first page is verified, second page's response times out.
    # Purpose: Resume keeps page 101, investigates page 102 and never blindly resends either update.
    It 'InterT10_recovers_partial_batch_under_original_operation_id' {
        $f=New-MultiPlan
        $script:mode='second-timeout'
        $r=Invoke-MultiPublish $f
        $r.status | Should -Be 'uncertain'
        @($script:calls|Where-Object Method -eq 'PUT').Count | Should -Be 2
        (Test-Path -LiteralPath $f.sync) | Should -Be $false
        $script:calls.Clear();$script:mode='normal'
        $r=Invoke-MultiPublish $f
        $r.status | Should -Be 'uncertain'
        @($script:calls|Where-Object Method -eq 'PUT').Count | Should -Be 0
        $script:pages['102'].marker=$script:expectedSecondMarker
        $script:calls.Clear()
        $r=Invoke-MultiPublish $f
        $r.status | Should -Be 'published'
        (Test-Path -LiteralPath $f.sync) | Should -Be $true
        @($script:calls|Where-Object Method -eq 'PUT').Count | Should -Be 0
        $script:pages['101'].version | Should -Be 8
        $script:pages['102'].version | Should -Be 8
    }

    # Scenario: SYP171-SCN-011; one page is updated while a second page is already a no-op, then its current body drifts.
    # Purpose: A confirmed journal must recheck every no-op baseline and leave journal/sync unchanged on refusal.
    It 'InterT20_blocks_confirmed_mixed_batch_after_no_op_current_drift' {
        $script:pages['102'].storage='<p>New two</p>'
        $script:pages['102'].draftStorage='<p>New two</p>'
        $f=New-MultiPlan
        $r=Invoke-MultiPublish $f
        $r.status | Should -Be 'published'
        $r=Invoke-MultiPublish $f
        $r.status | Should -Be 'no-op'
        $plan=Get-Content -LiteralPath $f.plan -Raw|ConvertFrom-Json
        @($plan.pages|Where-Object action -eq 'no-op').Count | Should -Be 1
        $journalBefore=[IO.File]::ReadAllBytes($f.journal)
        $syncBefore=[IO.File]::ReadAllBytes($f.sync)
        $script:calls.Clear()
        $script:pages['102'].version=8
        $script:pages['102'].draftVersion=8
        $script:pages['102'].storage='<p>External current change</p>'
        $script:pages['102'].draftStorage=$script:pages['102'].storage

        $r=Invoke-MultiPublish $f
        $r.status | Should -Be 'blocked'
        @($r.reasonCodes) | Should -Contain 'RemoteDrift'
        @($script:calls|Where-Object Method -in @('PUT','POST')).Count | Should -Be 0
        [Convert]::ToBase64String($journalBefore) | Should -Be ([Convert]::ToBase64String([IO.File]::ReadAllBytes($f.journal)))
        [Convert]::ToBase64String($syncBefore) | Should -Be ([Convert]::ToBase64String([IO.File]::ReadAllBytes($f.sync)))
    }

    # Scenario: SYP171-SCN-011; one page is updated while a second page is already a no-op, then its draft body drifts.
    # Purpose: Draft divergence on a no-op page must block replay before remote writes or sync advancement.
    It 'InterT25_blocks_confirmed_mixed_batch_after_no_op_draft_drift' {
        $script:pages['102'].storage='<p>New two</p>'
        $script:pages['102'].draftStorage='<p>New two</p>'
        $script:pages['102'].draftVersion=7
        $f=New-MultiPlan
        $r=Invoke-MultiPublish $f
        $r.status | Should -Be 'published'
        $journalBefore=[IO.File]::ReadAllBytes($f.journal)
        $syncBefore=[IO.File]::ReadAllBytes($f.sync)
        $script:calls.Clear()
        $script:pages['102'].draftStorage='<p>External draft change</p>'

        $r=Invoke-MultiPublish $f
        $r.status | Should -Be 'blocked'
        @($r.reasonCodes) | Should -Contain 'DraftConflict'
        @($script:calls|Where-Object Method -in @('PUT','POST')).Count | Should -Be 0
        [Convert]::ToBase64String($journalBefore) | Should -Be ([Convert]::ToBase64String([IO.File]::ReadAllBytes($f.journal)))
        [Convert]::ToBase64String($syncBefore) | Should -Be ([Convert]::ToBase64String([IO.File]::ReadAllBytes($f.sync)))
    }

    # Scenario: SYP171-SCN-011; a page write is uncertain and a separate no-op page drifts before journal resume.
    # Purpose: Resume must reject no-op drift before it can confirm active pages or advance the sync record.
    It 'InterT30_blocks_partial_resume_after_no_op_current_drift' {
        $f=New-MultiPlan -IncludeNoOpPage
        $script:mode='second-timeout'
        $r=Invoke-MultiPublish $f
        $r.status | Should -Be 'uncertain'
        (Test-Path -LiteralPath $f.sync) | Should -Be $false
        $journalBefore=[IO.File]::ReadAllBytes($f.journal)
        $script:calls.Clear()
        $script:mode='normal'
        $script:pages['103'].version=8
        $script:pages['103'].draftVersion=8
        $script:pages['103'].storage='<p>External current change</p>'
        $script:pages['103'].draftStorage=$script:pages['103'].storage

        $r=Invoke-MultiPublish $f
        $r.status | Should -Be 'blocked'
        @($r.reasonCodes) | Should -Contain 'RemoteDrift'
        @($script:calls|Where-Object Method -in @('PUT','POST')).Count | Should -Be 0
        (Test-Path -LiteralPath $f.sync) | Should -Be $false
        [Convert]::ToBase64String($journalBefore) | Should -Be ([Convert]::ToBase64String([IO.File]::ReadAllBytes($f.journal)))
    }
}
