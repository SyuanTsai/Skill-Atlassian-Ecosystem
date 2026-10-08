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
$storage='<h2>SYP171-SCN-011</h2><p>New target</p>'

function New-CreatePublishFixture {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('syp171-create-publish-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    return $root
}
function Remove-CreatePublishFixture {
    param([string]$Root)
    $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if([IO.Path]::GetDirectoryName($resolved).TrimEnd('\','/') -cne $parent -or [IO.Path]::GetFileName($resolved) -cnotmatch '^syp171-create-publish-[a-f0-9]{32}$'){throw 'Unsafe create publish fixture delete'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
function New-CreatePublishValidation {
    return [pscustomobject]@{status='valid';siteOrigin=$site;cloudId=$cloud;docsCommit=('1'*40);specCommit=('2'*40);codeCommit=('3'*40);sourceDigest=('a'*64);mappingDigest=('b'*64);reviewDigest=('c'*64);validatorVersion='1.13.0';rendererVersion='1';scenarioIds=@('SYP171-SCN-011')}
}
function New-CreatePublishHttp {
    return {
        param($Request)
        $script:calls.Add([pscustomobject]@{method=$Request.Method;uri=[string]$Request.Uri})
        if($Request.Method -eq 'POST'){
            $payload=$Request.Body|ConvertFrom-Json -AsHashtable
            $script:created=$true;$script:createdStorage=[string]$payload.body.value
            if($script:timeout){throw 'Synthetic timeout after create'}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='777';spaceId='55';parentId='99';title='Synthetic new SDD';status='current'}}
        }
        if($Request.Uri -match '/spaces/55/pages'){
            # Title matches may be used only as a collision check, not for ownership.
            $items=@()
            if($script:created){$items=@(@{id='777';spaceId='55';parentId='99';title='Synthetic new SDD';status='current'})}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=$items;_links=@{}}}
        }
        if($Request.Uri -match '/pages/777'){
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='777';spaceId='55';parentId='99';title='Synthetic new SDD';status='current';version=@{number=1;message=''};body=@{storage=@{value=$script:createdStorage}}}}
        }
        return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='99';spaceId='55';parentId='10';title='Synthetic parent';status='current';version=@{number=7};body=@{storage=@{value='<p>Parent</p>'}}}}
    }
}
function New-CreatePublishPlan {
    Import-Module -Name $planModule -Force
    $payload=@([pscustomobject]@{projectionId='req-new';pageId=$null;spaceId='55';parentId='99';title='Synthetic new SDD';bodyStorage=$storage;assetChanges=@()})
    $preview=New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixture 'plan.json') -Validation (New-CreatePublishValidation) -Payloads $payload -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-CreatePublishHttp)
    if($preview.status -cne 'preview'){throw "Preview failed: $($preview.reasonCodes -join ',')"}
    $plan=Get-Content -LiteralPath $preview.planPath -Raw|ConvertFrom-Json
    $auth=@{schemaVersion=1;planSha256=$preview.planSha256;operationId=$plan.operationId;siteOrigin=$site;cloudId=$cloud;approvedActions=@('create:req-new');approvalEvidenceRef='synthetic-test-fixture-only'}
    $authPath=Join-Path $script:fixture 'authorization.json'
    [IO.File]::WriteAllText($authPath,($auth|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{plan=$preview.planPath;auth=$authPath;journal=(Join-Path $script:fixture 'journal.json');sync=(Join-Path $script:fixture 'sync.json')}
}
function Invoke-CreatePublish {
    param($Fixture)
    Import-Module -Name $publishModule -Force
    return Invoke-ConfluencePlan -PlanPath $Fixture.plan -CurrentValidation (New-CreatePublishValidation) -AuthorizationPath $Fixture.auth -JournalPath $Fixture.journal -SyncPath $Fixture.sync -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-CreatePublishHttp)
}
function New-DependentCreateHttp {
    return {
        param($Request)
        $script:calls.Add([pscustomobject]@{method=$Request.Method;uri=[string]$Request.Uri})
        if($Request.Method -eq 'POST'){
            $body=$Request.Body|ConvertFrom-Json -AsHashtable
            $id=if($body.title -ceq 'Synthetic parent page'){'777'}else{'778'}
            if($id -eq '778' -and $body.parentId -cne '777'){throw 'Child received an unconfirmed parent ID'}
            $script:dependentPages[$id]=@{id=$id;spaceId='55';parentId=[string]$body.parentId;title=[string]$body.title;storage=[string]$body.body.value}
            if($script:timeout -and $id -eq '777'){throw 'Synthetic parent response lost'}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id=$id;spaceId='55';parentId=[string]$body.parentId;title=[string]$body.title;status='current'}}
        }
        if($Request.Uri -match '/spaces/55/pages'){
            $items=@($script:dependentPages.Values|ForEach-Object {@{id=$_.id;spaceId=$_.spaceId;parentId=$_.parentId;title=$_.title;status='current'}})
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=$items;_links=@{}}}
        }
        $id=if($Request.Uri -match '/pages/([0-9]+)'){$Matches[1]}else{''}
        if($script:dependentPages.ContainsKey($id)){
            $page=$script:dependentPages[$id]
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id=$page.id;spaceId=$page.spaceId;parentId=$page.parentId;title=$page.title;status='current';version=@{number=1;message=''};body=@{storage=@{value=$page.storage}}}}
        }
        return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='99';spaceId='55';parentId='10';title='External synthetic parent';status='current';version=@{number=7};body=@{storage=@{value='<p>Parent</p>'}}}}
    }
}
function New-DependentCreatePlan {
    Import-Module -Name $planModule -Force
    $payloads=@(
        [pscustomobject]@{projectionId='req-child';pageId=$null;spaceId='55';parentId='';parentProjectionId='req-parent';title='Synthetic child page';bodyStorage='<p>Child body</p>';assetChanges=@()},
        [pscustomobject]@{projectionId='req-parent';pageId=$null;spaceId='55';parentId='99';title='Synthetic parent page';bodyStorage='<p>Parent body</p>';assetChanges=@()}
    )
    $preview=New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixture 'dependent-plan.json') -Validation (New-CreatePublishValidation) -Payloads $payloads -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-DependentCreateHttp)
    if($preview.status -cne 'preview'){throw "Dependent preview failed: $($preview.reasonCodes -join ',')"}
    $plan=Get-Content -LiteralPath $preview.planPath -Raw|ConvertFrom-Json
    $auth=@{schemaVersion=1;planSha256=$preview.planSha256;operationId=$plan.operationId;siteOrigin=$site;cloudId=$cloud;approvedActions=@('create:req-parent','create:req-child');approvalEvidenceRef='synthetic-test-fixture-only'}
    $authPath=Join-Path $script:fixture 'dependent-authorization.json'
    [IO.File]::WriteAllText($authPath,($auth|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{plan=$preview.planPath;auth=$authPath;journal=(Join-Path $script:fixture 'dependent-journal.json');sync=(Join-Path $script:fixture 'dependent-sync.json')}
}
function Invoke-DependentCreate {
    param($Fixture)
    Import-Module -Name $publishModule -Force
    return Invoke-ConfluencePlan -PlanPath $Fixture.plan -CurrentValidation (New-CreatePublishValidation) -AuthorizationPath $Fixture.auth -JournalPath $Fixture.journal -SyncPath $Fixture.sync -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-DependentCreateHttp)
}

}

Describe 'SYP-171 create response and uncertain recovery' {
    BeforeEach{$script:fixture=New-CreatePublishFixture;$script:calls=[System.Collections.Generic.List[object]]::new();$script:created=$false;$script:createdStorage='';$script:dependentPages=@{};$script:timeout=$false}
    AfterEach{Remove-CreatePublishFixture -Root $script:fixture}

    # Scenario: SYP171-SCN-011/012; explicit server ID and exact body readback establish created identity.
    # Purpose: Same plan rerun does not create another page.
    It 'InterT10_creates_reads_back_and_reruns_no_op' {
        $f=New-CreatePublishPlan
        $r=Invoke-CreatePublish $f
        $r.status | Should -Be 'published'
        $sync=Get-Content -LiteralPath $f.sync -Raw|ConvertFrom-Json
        $sync.pages[0].pageId | Should -Be '777'
        $script:calls.Clear()
        (Invoke-CreatePublish $f).status | Should -Be 'no-op'
        @($script:calls|Where-Object method -eq 'POST').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-011; create reached the server but response was lost.
    # Purpose: Title search cannot claim ownership and retry cannot send a second POST.
    It 'UnitT20_keeps_timeout_uncertain_under_original_operation_id' {
        $f=New-CreatePublishPlan
        $script:timeout=$true
        $first=Invoke-CreatePublish $f
        $first.status | Should -Be 'uncertain'
        (Test-Path -LiteralPath $f.sync) | Should -Be $false
        $script:timeout=$false;$script:calls.Clear()
        $r=Invoke-CreatePublish $f
        $r.status | Should -Be 'uncertain'
        @($script:calls|Where-Object method -eq 'POST').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-011/012; a child uses only the parent ID from its confirmed same-operation readback.
    # Purpose: Reverse input order still yields parent then child and an exact no-op rerun.
    It 'InterT30_creates_parent_then_child_with_confirmed_server_parent_id' {
        $f=New-DependentCreatePlan
        $r=Invoke-DependentCreate $f
        $r.status | Should -Be 'published'
        $sync=Get-Content -LiteralPath $f.sync -Raw|ConvertFrom-Json
        @($sync.pages.pageId) | Should -Be @('777','778')
        $script:dependentPages['778'].parentId | Should -Be '777'
        $script:calls.Clear()
        (Invoke-DependentCreate $f).status | Should -Be 'no-op'
        @($script:calls|Where-Object method -eq 'POST').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-011; an uncertain parent create may have reached the server.
    # Purpose: The child is skipped and a retry never resends either create request.
    It 'UnitT40_skips_child_when_parent_create_response_is_lost' {
        $f=New-DependentCreatePlan
        $script:timeout=$true
        (Invoke-DependentCreate $f).status | Should -Be 'uncertain'
        @($script:calls|Where-Object method -eq 'POST').Count | Should -Be 1
        $script:timeout=$false;$script:calls.Clear()
        (Invoke-DependentCreate $f).status | Should -Be 'uncertain'
        @($script:calls|Where-Object method -eq 'POST').Count | Should -Be 0
    }
}
