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

function New-AssetCreateFixture {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('syp171-asset-create-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $root 'assets') -Force|Out-Null
    $bytes=[byte[]]@(0,255,13,10,42,128)
    [IO.File]::WriteAllBytes((Join-Path $root 'assets/diagram.png'),$bytes)
    $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    return [pscustomobject]@{root=$root;bytes=$bytes;sha=$sha;remote="syp171-req-new-$sha.png"}
}
function Remove-AssetCreateFixture {
    param([string]$Root)
    if(-not(Test-Path -LiteralPath $Root)){return}
    $full=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if([IO.Path]::GetDirectoryName($full).TrimEnd('\','/') -cne $parent -or
        [IO.Path]::GetFileName($full) -cnotmatch '^syp171-asset-create-[a-f0-9]{32}$'){throw 'Unsafe create fixture delete'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
function New-AssetCreateValidation {
    return [pscustomobject]@{status='valid';siteOrigin=$site;cloudId=$cloud;docsCommit=('1'*40);specCommit=('2'*40);codeCommit=('3'*40);sourceDigest=('a'*64);mappingDigest=('b'*64);reviewDigest=('c'*64);validatorVersion='1.13.0';rendererVersion='1';scenarioIds=@('SYP171-SCN-011','SYP171-SCN-012')}
}
function New-AssetCreateHttp {
    return {
        param($Request)
        $script:calls.Add([pscustomobject]@{method=[string]$Request.Method;uri=[string]$Request.Uri})
        if($Request.Uri -match '/spaces/55/pages'){
            $rows=@()
            if($script:created){$rows=@(@{id='777';spaceId='55';parentId='99';title='Synthetic new SDD';status='current'})}
            if($script:parentCreated){$rows+=@{id='700';spaceId='55';parentId='99';title='Synthetic new parent';status='current'}}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=$rows;_links=@{}}}
        }
        if($Request.Uri -match '/pages/777/attachments'){
            $rows=@()
            if($script:uploaded){$rows=@(@{id='900';pageId='777';status='current';title=$script:fixture.remote;mediaType='image/png';fileSize=$script:fixture.bytes.Length;comment=$script:assetComment;version=@{number=1};downloadLink='/wiki/rest/api/content/777/child/attachment/900/download'})}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=$rows;_links=@{}}}
        }
        if($Request.Uri -match '/child/attachment/900/download\?version=1$'){
            return [pscustomobject]@{StatusCode=200;Headers=@{};BodyBytes=$script:fixture.bytes;Body=$script:fixture.bytes}
        }
        if($Request.Method -eq 'POST' -and $Request.Uri -eq "$api/wiki/api/v2/pages"){
            $script:pagePostCount++
            $body=$Request.Body|ConvertFrom-Json -AsHashtable
            if($body.title -ceq 'Synthetic new parent'){
                if($body.parentId -cne '99' -or [string]$body.body.value -cne '<p>Parent body</p>'){throw 'Invalid dependent parent create'}
                $script:parentCreated=$true
                if($script:mode -eq 'parent-timeout'){throw 'Synthetic dependent parent response timeout'}
                return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='700';spaceId='55';parentId='99';title='Synthetic new parent';status='current'}}
            }
            $expectedParent=if($script:dependentParent){'700'}else{'99'}
            if($body.parentId -cne $expectedParent -or $body.title -cne 'Synthetic new SDD' -or
                [string]$body.body.value -notmatch 'SYP171.*staging' -or [string]$body.body.value -match 'ri:attachment'){
                throw 'Create must write an identifiable intermediate page without asset references'
            }
            $script:created=$true;$script:pageStorage=[string]$body.body.value;$script:pageVersion=1
            if($script:mode -eq 'page-timeout'){throw 'Synthetic create response timeout'}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='777';spaceId='55';parentId=$expectedParent;title='Synthetic new SDD';status='current'}}
        }
        if($Request.Method -eq 'POST' -and $Request.Uri -eq "$api/wiki/rest/api/content/777/child/attachment"){
            $script:assetPostCount++
            if($Request.BodyBytes -isnot [byte[]] -or [string]$Request.Headers['X-Atlassian-Token'] -cne 'nocheck' -or
                -not([Text.Encoding]::UTF8.GetString($Request.BodyBytes)).Contains($script:expectedAssetComment,[StringComparison]::Ordinal)){
                throw 'Invalid binary upload'
            }
            $script:uploaded=$true;$script:assetComment=$script:expectedAssetComment
            if($script:mode -eq 'asset-timeout'){throw 'Synthetic upload response timeout'}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=@(@{id='900'})}}
        }
        if($Request.Method -eq 'PUT' -and $Request.Uri -eq "$api/wiki/api/v2/pages/777"){
            $script:bodyPutCount++
            $body=$Request.Body|ConvertFrom-Json -AsHashtable
            if($body.version.number -ne 2 -or -not([string]$body.body.value).Contains("ri:filename=`"$($script:fixture.remote)`"",[StringComparison]::Ordinal)){
                throw 'Expected final version-2 body with attachment reference'
            }
            if($script:mode -eq 'body-fails'){throw 'Synthetic body PUT failure'}
            $script:pageStorage=[string]$body.body.value;$script:pageVersion=2;$script:pageMessage=[string]$body.version.message
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='777';version=@{number=2}}}
        }
        if($Request.Uri -match '/pages/700'){
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='700';spaceId='55';parentId='99';title='Synthetic new parent';status='current';version=@{number=1;message=''};body=@{storage=@{value='<p>Parent body</p>'}}}}
        }
        if($Request.Uri -match '/pages/777'){
            $parent=if($script:dependentParent){'700'}else{'99'}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='777';spaceId='55';parentId=$parent;title='Synthetic new SDD';status='current';version=@{number=$script:pageVersion;message=$script:pageMessage};body=@{storage=@{value=$script:pageStorage}}}}
        }
        return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='99';spaceId='55';parentId='10';title='Synthetic parent';status='current';version=@{number=7};body=@{storage=@{value='<p>Parent</p>'}}}}
    }
}
function New-AssetCreatePlan {
    param([switch]$DependentParent)
    Import-Module -Name $planModule -Force
    $storage="<p>Final SDD</p><ac:image><ri:attachment ri:filename=`"$($script:fixture.remote)`" /></ac:image>"
    $script:dependentParent=[bool]$DependentParent
    $child=[pscustomobject]@{projectionId='req-new';pageId=$null;spaceId='55';parentId=$(if($DependentParent){''}else{'99'});title='Synthetic new SDD';bodyStorage=$storage
        assetChanges=@([pscustomobject]@{localPath='assets/diagram.png';displayFilename='diagram.png';mediaType='image/png';sha256=$script:fixture.sha})}
    if($DependentParent){$child|Add-Member -NotePropertyName parentProjectionId -NotePropertyValue 'req-parent'}
    $payload=@($child)
    if($DependentParent){$payload+= [pscustomobject]@{projectionId='req-parent';pageId=$null;spaceId='55';parentId='99';title='Synthetic new parent';bodyStorage='<p>Parent body</p>';assetChanges=@()}}
    $preview=New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixture.root 'plan.json') -Validation (New-AssetCreateValidation) -Payloads $payload -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-AssetCreateHttp) -ValidationInputs ([pscustomobject]@{root=$script:fixture.root})
    if($preview.status -cne 'preview'){throw "Create preview failed: $($preview.reasonCodes -join ','); calls=$(@($script:calls|ForEach-Object uri)-join ',')"}
    $plan=Get-Content -LiteralPath $preview.planPath -Raw|ConvertFrom-Json
    $script:expectedAssetComment="SYP171:$($plan.operationId):req-new:$($script:fixture.sha)"
    $approved=if($DependentParent){@('create:req-parent','create:req-new')}else{@('create:req-new')}
    $auth=@{schemaVersion=1;planSha256=$preview.planSha256;operationId=$plan.operationId;siteOrigin=$site;cloudId=$cloud;approvedActions=@($approved);approvalEvidenceRef='synthetic-test-fixture-only'}
    $authPath=Join-Path $script:fixture.root 'authorization.json'
    [IO.File]::WriteAllText($authPath,($auth|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{plan=$preview.planPath;auth=$authPath;journal=(Join-Path $script:fixture.root 'journal.json');sync=(Join-Path $script:fixture.root 'sync.json');operationId=$plan.operationId}
}
function Invoke-AssetCreate {
    param($Fixture)
    Import-Module -Name $publishModule -Force
    return Invoke-ConfluencePlan -PlanPath $Fixture.plan -CurrentValidation (New-AssetCreateValidation) -AuthorizationPath $Fixture.auth -JournalPath $Fixture.journal -SyncPath $Fixture.sync -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-AssetCreateHttp)
}

}

Describe 'SYP-171 attachment create intermediate page and recovery' {
    BeforeEach{
        $script:fixture=New-AssetCreateFixture;$script:calls=[System.Collections.Generic.List[object]]::new()
        $script:created=$false;$script:parentCreated=$false;$script:dependentParent=$false;$script:uploaded=$false;$script:pageStorage='';$script:pageVersion=0;$script:pageMessage=''
        $script:assetComment='';$script:pagePostCount=0;$script:assetPostCount=0;$script:bodyPutCount=0;$script:mode='normal'
    }
    AfterEach{Remove-AssetCreateFixture -Root $script:fixture.root}

    # Scenario: SYP171-SCN-011/012; a new synthetic target includes one binary attachment.
    # Purpose: An intermediate page with server-returned ID precedes upload; final body and asset are read back before sync/no-op.
    It 'InterT10_creates_intermediate_uploads_binary_finalizes_and_reruns_no_op' {
        $f=New-AssetCreatePlan
        $r=Invoke-AssetCreate $f
        if($r.status -ne 'published'){throw "Create status=$($r.status) reason=$($r.reasonCodes -join ',') calls=$(@($script:calls|ForEach-Object {'{0}:{1}' -f $_.method,$_.uri}) -join ',')"}
        $r.status | Should -Be 'published'
        $plan=Get-Content -LiteralPath $f.plan -Raw|ConvertFrom-Json
        (@($plan.pages[0].intermediateWrites) -join ',') | Should -Be 'page-create-intermediate,page-create-readback,attachment-upload,final-page-body-update,attachment-and-page-readback'
        $script:pagePostCount | Should -Be 1;$script:assetPostCount | Should -Be 1;$script:bodyPutCount | Should -Be 1
        $script:pageVersion | Should -Be 2
        $sync=Get-Content -LiteralPath $f.sync -Raw|ConvertFrom-Json
        $sync.pages[0].pageId | Should -Be '777'
        $sync.pages[0].assets[0].remoteAttachmentId | Should -Be '900'
        $script:calls.Clear()
        (Invoke-AssetCreate $f).status | Should -Be 'no-op'
        @($script:calls|Where-Object method -ne 'GET').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-011; server created the intermediate page but its response was lost.
    # Purpose: A title collision alone never proves ownership, and the operation never sends another create POST.
    It 'UnitT20_keeps_lost_create_response_uncertain_without_second_page_post' {
        $f=New-AssetCreatePlan;$script:mode='page-timeout'
        (Invoke-AssetCreate $f).status | Should -Be 'uncertain'
        $script:created | Should -Be $true
        (Test-Path -LiteralPath $f.sync) | Should -Be $false
        $script:mode='normal';$script:calls.Clear()
        (Invoke-AssetCreate $f).status | Should -Be 'uncertain'
        $script:pagePostCount | Should -Be 1
        $script:assetPostCount | Should -Be 0
        @($script:calls|Where-Object method -eq 'POST').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-012; a confirmed intermediate page and attachment survive a failed final body update.
    # Purpose: Resume uses the same page/attachment IDs without replaying either POST.
    It 'InterT30_resumes_after_final_body_failure_without_recreating_page_or_asset' {
        $f=New-AssetCreatePlan;$script:mode='body-fails'
        $first=Invoke-AssetCreate $f
        if($first.status -ne 'uncertain' -or -not $script:uploaded){throw "Body failure status=$($first.status) reason=$($first.reasonCodes -join ',') calls=$(@($script:calls|ForEach-Object {'{0}:{1}' -f $_.method,$_.uri}) -join ',')"}
        $first.status | Should -Be 'uncertain'
        $script:created | Should -Be $true;$script:uploaded | Should -Be $true
        (Test-Path -LiteralPath $f.sync) | Should -Be $false
        $journal=Get-Content -LiteralPath $f.journal -Raw|ConvertFrom-Json
        $journal.pages[0].pageId | Should -Be '777'
        $journal.pages[0].assets[0].remoteAttachmentId | Should -Be '900'
        $script:mode='normal';$script:calls.Clear()
        (Invoke-AssetCreate $f).status | Should -Be 'published'
        $script:pagePostCount | Should -Be 1;$script:assetPostCount | Should -Be 1;$script:bodyPutCount | Should -Be 2
        @($script:calls|Where-Object method -eq 'POST').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-011/012; upload response is lost after server stored the exact marked binary.
    # Purpose: A confirmed marker, ID, version and binary hash permit finalization without a second page or attachment POST.
    It 'InterT40_reconciles_marked_attachment_timeout_without_reupload' {
        $f=New-AssetCreatePlan;$script:mode='asset-timeout'
        (Invoke-AssetCreate $f).status | Should -Be 'published'
        $script:pagePostCount | Should -Be 1;$script:assetPostCount | Should -Be 1;$script:bodyPutCount | Should -Be 1
        $script:calls.Clear()
        (Invoke-AssetCreate $f).status | Should -Be 'no-op'
        @($script:calls|Where-Object method -ne 'GET').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-011/012; an attached new child waits for a confirmed new plain parent.
    # Purpose: Intermediate child create, binary upload, final body and no-op retain the server parent ID.
    It 'InterT50_creates_attached_child_under_confirmed_new_parent' {
        $f=New-AssetCreatePlan -DependentParent
        (Invoke-AssetCreate $f).status | Should -Be 'published'
        $script:pagePostCount | Should -Be 2
        $script:assetPostCount | Should -Be 1
        $sync=Get-Content -LiteralPath $f.sync -Raw|ConvertFrom-Json
        @($sync.pages.pageId) | Should -Be @('700','777')
        $script:calls.Clear()
        (Invoke-AssetCreate $f).status | Should -Be 'no-op'
        @($script:calls|Where-Object method -ne 'GET').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-011; a lost parent create response blocks attached child upload and create.
    # Purpose: Retry stays uncertain and never makes a second POST for either page.
    It 'UnitT60_skips_attached_child_when_new_parent_result_is_uncertain' {
        $f=New-AssetCreatePlan -DependentParent;$script:mode='parent-timeout'
        (Invoke-AssetCreate $f).status | Should -Be 'uncertain'
        $script:pagePostCount | Should -Be 1;$script:assetPostCount | Should -Be 0
        $script:mode='normal';$script:calls.Clear()
        (Invoke-AssetCreate $f).status | Should -Be 'uncertain'
        @($script:calls|Where-Object method -eq 'POST').Count | Should -Be 0
    }
}
