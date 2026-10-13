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
    $extraBytes=[byte[]]@(1,128,0,255,9,41,10)
    [IO.File]::WriteAllBytes((Join-Path $root 'assets/diagram.png'),$bytes)
    [IO.File]::WriteAllBytes((Join-Path $root 'assets/diagram-extra.png'),$extraBytes)
    $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    $extraSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($extraBytes)).ToLowerInvariant()
    return [pscustomobject]@{root=$root;bytes=$bytes;sha=$sha;remote="syp171-req-new-$sha.png";extraBytes=$extraBytes;extraSha=$extraSha;extraRemote="syp171-req-new-$extraSha.png"}
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
    return [pscustomobject]@{status='valid';siteOrigin=$site;cloudId=$cloud;docsCommit=('1'*40);codeCommit='';sourceMode='git-markdown';sourceDigest=('a'*64);mappingDigest=('b'*64);reviewDigest='';validatorVersion='powershell-markdown-v1';rendererVersion='powershell-markdown-v1'}
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
        if($Request.Uri -match '/pages/(777|999)/attachments'){
            $rows=@()
            if($Matches[1] -eq '777' -and $script:uploaded){$rows=@(@{id='900';pageId='777';status='current';title=$script:fixture.remote;mediaType='image/png';fileSize=$script:fixture.bytes.Length;comment=$script:assetComment;version=@{number=1};downloadLink='/wiki/rest/api/content/777/child/attachment/900/download'})}
            if($Matches[1] -eq '777' -and $script:uploadedExtra){$rows+=@(@{id='901';pageId='777';status='current';title=$script:fixture.extraRemote;mediaType='image/png';fileSize=$script:fixture.extraBytes.Length;comment=$script:extraAssetComment;version=@{number=1};downloadLink='/wiki/rest/api/content/777/child/attachment/901/download'})}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=$rows;_links=@{}}}
        }
        if($Request.Uri -match '/child/attachment/(900|901)/download\?version=1$'){
            [byte[]]$bytes=$null
            if($Matches[1] -eq '900'){$bytes=[byte[]]$script:fixture.bytes}else{$bytes=[byte[]]$script:fixture.extraBytes}
            return [pscustomobject]@{StatusCode=200;Headers=@{};BodyBytes=$bytes;Body=$bytes}
        }
        if($Request.Method -eq 'POST' -and $Request.Uri -eq "$api/wiki/api/v2/pages"){
            $script:pagePostCount++
            $body=$Request.Body|ConvertFrom-Json -AsHashtable
            if($body.title -ceq 'Synthetic new parent'){
                if($body.parentId -cne '99' -or [string]$body.body.value -notmatch 'SYP171.*staging'){
                    throw 'Dependent parent must be created with an identifiable intermediate body'
                }
                $script:parentCreated=$true;$script:parentStorage=[string]$body.body.value;$script:parentVersion=1;$script:parentMessage=''
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
            $uploadText=[Text.Encoding]::UTF8.GetString($Request.BodyBytes)
            if($Request.BodyBytes -isnot [byte[]] -or [string]$Request.Headers['X-Atlassian-Token'] -cne 'nocheck' -or
                (-not $uploadText.Contains($script:expectedAssetComment,[StringComparison]::Ordinal) -and
                    -not $uploadText.Contains($script:expectedExtraAssetComment,[StringComparison]::Ordinal))){
                throw 'Invalid binary upload'
            }
            if($uploadText.Contains($script:expectedExtraAssetComment,[StringComparison]::Ordinal)){
                $script:uploadedExtra=$true;$script:extraAssetComment=$script:expectedExtraAssetComment;$attachmentId='901'
            }else{$script:uploaded=$true;$script:assetComment=$script:expectedAssetComment;$attachmentId='900'}
            if($script:mode -eq 'asset-timeout'){throw 'Synthetic upload response timeout'}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=@(@{id=$attachmentId})}}
        }
        if($Request.Method -eq 'PUT' -and $Request.Uri -eq "$api/wiki/api/v2/pages/777"){
            $script:bodyPutCount++
            $body=$Request.Body|ConvertFrom-Json -AsHashtable
            if($body.version.number -ne 2 -or -not([string]$body.body.value).Contains("ri:filename=`"$($script:fixture.remote)`"",[StringComparison]::Ordinal) -or
                ($script:twoAssetPlan -and -not([string]$body.body.value).Contains("ri:filename=`"$($script:fixture.extraRemote)`"",[StringComparison]::Ordinal))){
                throw 'Expected final version-2 body with attachment reference'
            }
            if($script:mode -eq 'body-fails'){throw 'Synthetic body PUT failure'}
            $script:pageStorage=[string]$body.body.value;$script:pageVersion=2;$script:pageMessage=[string]$body.version.message
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='777';version=@{number=2}}}
        }
        if($Request.Method -eq 'PUT' -and $Request.Uri -eq "$api/wiki/api/v2/pages/700"){
            $body=$Request.Body|ConvertFrom-Json -AsHashtable
            if($body.version.number -ne 2 -or [string]$body.body.value -cne '<p>Parent body</p>'){
                throw 'Expected final version-2 dependent parent body'
            }
            $script:parentStorage=[string]$body.body.value;$script:parentVersion=2;$script:parentMessage=[string]$body.version.message
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='700';version=@{number=2}}}
        }
        if($Request.Uri -match '/pages/700'){
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='700';spaceId='55';parentId='99';title='Synthetic new parent';status='current';version=@{number=$script:parentVersion;message=$script:parentMessage};body=@{storage=@{value=$script:parentStorage}}}}
        }
        if($Request.Uri -match '/pages/777'){
            $parent=if($script:dependentParent){'700'}else{'99'}
            $remoteId='777';$spaceId='55';$title='Synthetic new SDD';$storage=$script:pageStorage
            switch($script:readbackMismatch){
                'id' {$remoteId='999'}
                'space' {$spaceId='56'}
                'parent' {$parent='98'}
                'title' {$title='Unexpected title'}
                'marker' {$storage='<p>Not the SYP171 staging marker</p>'}
            }
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id=$remoteId;spaceId=$spaceId;parentId=$parent;title=$title;status='current';version=@{number=$script:pageVersion;message=$script:pageMessage};body=@{storage=@{value=$storage}}}}
        }
        return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='99';spaceId='55';parentId='10';title='Synthetic parent';status='current';version=@{number=7};body=@{storage=@{value='<p>Parent</p>'}}}}
    }
}
function New-AssetCreatePlan {
    param([switch]$DependentParent,[switch]$TwoAssets)
    Import-Module -Name $planModule -Force
    $storage="<p>Final SDD</p><ac:image><ri:attachment ri:filename=`"$($script:fixture.remote)`" /></ac:image>"
    $assets=@([pscustomobject]@{localPath='assets/diagram.png';displayFilename='diagram.png';mediaType='image/png';sha256=$script:fixture.sha})
    if($TwoAssets){
        $assets+= [pscustomobject]@{localPath='assets/diagram-extra.png';displayFilename='diagram-extra.png';mediaType='image/png';sha256=$script:fixture.extraSha}
        $storage+="<ac:image><ri:attachment ri:filename=`"$($script:fixture.extraRemote)`" /></ac:image>"
    }
    $script:dependentParent=[bool]$DependentParent
    $script:twoAssetPlan=[bool]$TwoAssets
    $child=[pscustomobject]@{projectionId='req-new';pageId=$null;spaceId='55';parentId=$(if($DependentParent){''}else{'99'});title='Synthetic new SDD';bodyStorage=$storage
        assetChanges=$assets}
    if($DependentParent){$child|Add-Member -NotePropertyName parentProjectionId -NotePropertyValue 'req-parent'}
    $payload=@($child)
    if($DependentParent){$payload+= [pscustomobject]@{projectionId='req-parent';pageId=$null;spaceId='55';parentId='99';title='Synthetic new parent';bodyStorage='<p>Parent body</p>';assetChanges=@()}}
    $preview=New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixture.root 'plan.json') -Validation (New-AssetCreateValidation) -Payloads $payload -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-AssetCreateHttp) -ValidationInputs ([ordered]@{root=$script:fixture.root;mappingPath='.confluence/mapping.json';docsCommit=('1'*40)})
    if($preview.status -cne 'preview'){throw "Create preview failed: $($preview.reasonCodes -join ','); calls=$(@($script:calls|ForEach-Object uri)-join ',')"}
    $plan=Get-Content -LiteralPath $preview.planPath -Raw|ConvertFrom-Json
    $script:expectedAssetComment="SYP171:$($plan.operationId):req-new:$($script:fixture.sha)"
    $script:expectedExtraAssetComment="SYP171:$($plan.operationId):req-new:$($script:fixture.extraSha)"
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
        $script:uploadedExtra=$false;$script:extraAssetComment='';$script:twoAssetPlan=$false
        $script:parentStorage='';$script:parentVersion=0;$script:parentMessage=''
        $script:assetComment='';$script:pagePostCount=0;$script:assetPostCount=0;$script:bodyPutCount=0;$script:mode='normal'
        $script:readbackMismatch=''
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

    # Scenario: SYP171-SCN-012; a final body PUT has an ambiguous result after page and attachment confirmation.
    # Purpose: The journal preserves identity and asset evidence but never blindly repeats the final PUT.
    It 'InterT30_keeps_final_body_failure_uncertain_without_blind_retry' {
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
        (Invoke-AssetCreate $f).status | Should -Be 'uncertain'
        $script:pagePostCount | Should -Be 1;$script:assetPostCount | Should -Be 1;$script:bodyPutCount | Should -Be 1
        @($script:calls|Where-Object method -ne 'GET').Count | Should -Be 0
        (Test-Path -LiteralPath $f.sync) | Should -Be $false
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

    # Scenario: A resumed create journal names a different page and claims its asset is still planned after final-write was sent.
    # Purpose: Journal identity and impossible progress must stop a binary side effect before another attachment POST.
    # Given: The real create reached an uncertain final write, then its saved target ID and asset stage are altered.
    # When: The approved plan is resumed against the altered journal.
    # Then: Publish blocks and sends no attachment POST.
    It 'UnitT70_blocks_forged_create_identity_before_attachment_post' {
        $f=New-AssetCreatePlan;$script:mode='body-fails'
        (Invoke-AssetCreate $f).status | Should -Be 'uncertain'
        $journal=Get-Content -LiteralPath $f.journal -Raw|ConvertFrom-Json -AsHashtable
        $journal.pages[0].pageId='999'
        $journal.pages[0].assets[0].stage='planned'
        [IO.File]::WriteAllText($f.journal,($journal|ConvertTo-Json -Depth 18),[Text.UTF8Encoding]::new($false))

        $script:mode='normal';$script:calls.Clear()
        $resume=Invoke-AssetCreate $f
        @($script:calls|Where-Object {$_.method -eq 'POST' -and $_.uri -match '/child/attachment$'}).Count | Should -Be 0
        $resume.status | Should -Be 'blocked'
    }

    # Scenario: The intermediate create response has a server ID, but the subsequent page readback changes a trusted identity field.
    # Purpose: A create page must match ID, space, parent, title, and the exact operation marker before any binary upload.
    # Given: The create POST returned a valid page ID and the persisted journal is at identity-response.
    # When: Current-page readback differs in one target identity field.
    # Then: Publish remains uncertain and makes no attachment POST.
    It 'UnitT71_rejects_create_readback_identity_drift_before_attachment_post_<Field>' -TestCases @(
        @{Field='id'},@{Field='space'},@{Field='parent'},@{Field='title'},@{Field='marker'}
    ) {
        param($Field)
        $f=New-AssetCreatePlan;$script:readbackMismatch=$Field

        $result=Invoke-AssetCreate $f

        $script:pagePostCount | Should -Be 1
        $script:assetPostCount | Should -Be 0
        @($script:calls|Where-Object {$_.method -eq 'POST' -and $_.uri -match '/child/attachment$'}).Count | Should -Be 0
        $result.status | Should -Be 'uncertain'
    }

    # Scenario: An existing create has plan parent 99, but the remote target and journal are both changed to parent 98.
    # Purpose: Neither a mutable journal parent nor an impossible assets-confirmed/planned-asset stage can authorize writes.
    # Given: A valid plan for a create under parent 99 and a staging page under forged parent 98.
    # When: Resume sees assets-confirmed while its only attachment is still planned.
    # Then: Publish blocks before attachment POST and final body PUT.
    It 'UnitT72_rejects_forged_static_parent_and_impossible_assets_confirmed_stage' {
        $f=New-AssetCreatePlan
        $plan=Get-Content -LiteralPath $f.plan -Raw|ConvertFrom-Json -AsHashtable
        $page=$plan.pages[0];$asset=$page.assetChanges[0]
        $script:created=$true;$script:pageVersion=1
        $script:pageStorage="<p>SYP171 operation $($plan.operationId) staging req-new</p>"
        $script:readbackMismatch='parent'
        $journal=[ordered]@{schemaVersion=3;operationId=$plan.operationId;planSha256=(Get-Content -LiteralPath ($f.plan+'.sha256') -Raw).Trim();status='in-progress';pages=@(
            @{projectionId=$page.projectionId;pageId='777';parentId='98';stage='assets-confirmed';resolvedPayloadSha256='';version=0;
                assets=@(@{remoteFilename=$asset.remoteFilename;sha256=$asset.sha256;stage='planned';remoteAttachmentId='';remoteVersion=0})}
        )}
        [IO.File]::WriteAllText($f.journal,($journal|ConvertTo-Json -Depth 18),[Text.UTF8Encoding]::new($false))

        $result=Invoke-AssetCreate $f

        $script:assetPostCount | Should -Be 0;$script:bodyPutCount | Should -Be 0
        @($script:calls|Where-Object {$_.method -in @('POST','PUT')}).Count | Should -Be 0
        $result.status | Should -Be 'blocked'
    }

    # Scenario: A static create's confirmed attachment evidence resumes with its saved and remote parent changed.
    # Purpose: A valid journal stage cannot replace the immutable plan parent when authorizing final body writes.
    # Given: The plan requires parent 99, while the staging page and journal both report parent 98.
    # When: Publish resumes an otherwise valid assets-confirmed page.
    # Then: Publish blocks without another attachment POST or body PUT.
    It 'UnitT73_rechecks_static_create_parent_against_plan_before_body_write' {
        $f=New-AssetCreatePlan
        $plan=Get-Content -LiteralPath $f.plan -Raw|ConvertFrom-Json -AsHashtable
        $page=$plan.pages[0];$asset=$page.assetChanges[0]
        $script:created=$true;$script:pageVersion=1
        $script:pageStorage="<p>SYP171 operation $($plan.operationId) staging req-new</p>"
        $script:readbackMismatch='parent';$script:uploaded=$true;$script:assetComment=$script:expectedAssetComment
        $journal=[ordered]@{schemaVersion=3;operationId=$plan.operationId;planSha256=(Get-Content -LiteralPath ($f.plan+'.sha256') -Raw).Trim();status='in-progress';pages=@(
            @{projectionId=$page.projectionId;pageId='777';parentId='98';stage='assets-confirmed';resolvedPayloadSha256='';version=0;
                assets=@(@{remoteFilename=$asset.remoteFilename;sha256=$asset.sha256;stage='confirmed';remoteAttachmentId='900';remoteVersion=1})}
        )}
        [IO.File]::WriteAllText($f.journal,($journal|ConvertTo-Json -Depth 18),[Text.UTF8Encoding]::new($false))

        $result=Invoke-AssetCreate $f

        $script:assetPostCount | Should -Be 0;$script:bodyPutCount | Should -Be 0
        @($script:calls|Where-Object {$_.method -in @('POST','PUT')}).Count | Should -Be 0
        $result.status | Should -Be 'blocked'
    }

    # Scenario: A linked child and its journal/remote parentId are changed from the verified parent page to 98.
    # Purpose: Bind a resumed linked create to its approved parent projection and verified server identity.
    # Given: The parent page 700 is verified from the plan, while child page 777 reports parent 98.
    # When: Publish resumes the child's confirmed attachment and final body stages.
    # Then: Publish blocks before attaching or updating the child; the unchanged linked control remains covered above.
    It 'UnitT74_rejects_linked_child_parent_tampering_before_body_write' {
        $f=New-AssetCreatePlan -DependentParent
        $plan=Get-Content -LiteralPath $f.plan -Raw|ConvertFrom-Json -AsHashtable
        $parent=@($plan.pages|Where-Object projectionId -CEQ 'req-parent')[0]
        $child=@($plan.pages|Where-Object projectionId -CEQ 'req-new')[0]
        $asset=$child.assetChanges[0]
        $script:parentCreated=$true;$script:parentVersion=1
        $script:parentStorage="<p>SYP171 operation $($plan.operationId) staging req-parent</p>"
        $script:created=$true;$script:pageVersion=1
        $script:pageStorage="<p>SYP171 operation $($plan.operationId) staging req-new</p>"
        $script:readbackMismatch='parent';$script:uploaded=$true;$script:assetComment=$script:expectedAssetComment
        $journal=[ordered]@{schemaVersion=3;operationId=$plan.operationId;planSha256=(Get-Content -LiteralPath ($f.plan+'.sha256') -Raw).Trim();status='in-progress';pages=@(
            @{projectionId=$parent.projectionId;pageId='700';parentId='99';stage='identity-confirmed';resolvedPayloadSha256='';version=1;assets=@()},
            @{projectionId=$child.projectionId;pageId='777';parentId='98';stage='assets-confirmed';resolvedPayloadSha256='';version=1;
                assets=@(@{remoteFilename=$asset.remoteFilename;sha256=$asset.sha256;stage='confirmed';remoteAttachmentId='900';remoteVersion=1})}
        )}
        [IO.File]::WriteAllText($f.journal,($journal|ConvertTo-Json -Depth 18),[Text.UTF8Encoding]::new($false))

        $result=Invoke-AssetCreate $f

        $script:assetPostCount | Should -Be 0;$script:bodyPutCount | Should -Be 0
        @($script:calls|Where-Object {$_.method -in @('POST','PUT')}).Count | Should -Be 0
        $result.status | Should -Be 'blocked'
    }

    # Scenario: A schema-3 journal created by the baseline after its first asset confirmation has a mixed confirmed/planned list.
    # Purpose: Resume a legal legacy checkpoint, reuse the confirmed attachment, and finish only the remaining asset and page write.
    # Given: The approved static parent and remote page all remain parent 99, with asset 1 confirmed and asset 2 planned.
    # When: Publish resumes the two-asset create from its persisted assets-confirmed checkpoint.
    # Then: It uploads only asset 2, performs one final body PUT, and records both assets confirmed.
    It 'UnitT80_resumes_legacy_assets_confirmed_partial_create_without_replaying_confirmed_asset' {
        $f=New-AssetCreatePlan -TwoAssets
        $plan=Get-Content -LiteralPath $f.plan -Raw|ConvertFrom-Json -AsHashtable
        $page=$plan.pages[0];$assets=@($page.assetChanges)
        $script:created=$true;$script:pageVersion=1
        $script:pageStorage="<p>SYP171 operation $($plan.operationId) staging req-new</p>"
        $script:uploaded=$true;$script:assetComment=$script:expectedAssetComment
        $journal=[ordered]@{schemaVersion=3;operationId=$plan.operationId;planSha256=(Get-Content -LiteralPath ($f.plan+'.sha256') -Raw).Trim();status='in-progress';pages=@(
            @{projectionId=$page.projectionId;pageId='777';parentId='99';stage='assets-confirmed';resolvedPayloadSha256='';version=1;
                assets=@(
                    @{remoteFilename=$assets[0].remoteFilename;sha256=$assets[0].sha256;stage='confirmed';remoteAttachmentId='900';remoteVersion=1},
                    @{remoteFilename=$assets[1].remoteFilename;sha256=$assets[1].sha256;stage='planned';remoteAttachmentId='';remoteVersion=0}
                )}
        )}
        [IO.File]::WriteAllText($f.journal,($journal|ConvertTo-Json -Depth 18),[Text.UTF8Encoding]::new($false))

        $result=Invoke-AssetCreate $f

        $result.status | Should -Be 'published'
        $script:pagePostCount | Should -Be 0
        $script:assetPostCount | Should -Be 1
        $script:uploaded | Should -Be $true;$script:uploadedExtra | Should -Be $true
        $script:bodyPutCount | Should -Be 1;$script:pageVersion | Should -Be 2
        $saved=Get-Content -LiteralPath $f.journal -Raw|ConvertFrom-Json
        @($saved.pages[0].assets|Where-Object stage -ne 'confirmed').Count | Should -Be 0
        $saved.pages[0].assets[0].remoteAttachmentId | Should -Be '900'
        $saved.pages[0].assets[1].remoteAttachmentId | Should -Be '901'
    }

    # Scenario: The same legacy partial checkpoint now has a parent ID that differs from the immutable plan and readback.
    # Purpose: Partial-resume compatibility must retain the parent identity gate before any remaining binary or page write.
    # Given: One of two assets is confirmed, but both the remote page and journal were changed from planned parent 99 to 98.
    # When: Publish resumes this otherwise recoverable assets-confirmed checkpoint.
    # Then: It blocks specifically for linked-create drift and sends no attachment POST or body PUT.
    It 'UnitT81_blocks_partial_resume_when_static_parent_differs_from_plan' {
        $f=New-AssetCreatePlan -TwoAssets
        $plan=Get-Content -LiteralPath $f.plan -Raw|ConvertFrom-Json -AsHashtable
        $page=$plan.pages[0];$assets=@($page.assetChanges)
        $script:created=$true;$script:pageVersion=1;$script:readbackMismatch='parent'
        $script:pageStorage="<p>SYP171 operation $($plan.operationId) staging req-new</p>"
        $script:uploaded=$true;$script:assetComment=$script:expectedAssetComment
        $journal=[ordered]@{schemaVersion=3;operationId=$plan.operationId;planSha256=(Get-Content -LiteralPath ($f.plan+'.sha256') -Raw).Trim();status='in-progress';pages=@(
            @{projectionId=$page.projectionId;pageId='777';parentId='98';stage='assets-confirmed';resolvedPayloadSha256='';version=1;
                assets=@(
                    @{remoteFilename=$assets[0].remoteFilename;sha256=$assets[0].sha256;stage='confirmed';remoteAttachmentId='900';remoteVersion=1},
                    @{remoteFilename=$assets[1].remoteFilename;sha256=$assets[1].sha256;stage='planned';remoteAttachmentId='';remoteVersion=0}
                )}
        )}
        [IO.File]::WriteAllText($f.journal,($journal|ConvertTo-Json -Depth 18),[Text.UTF8Encoding]::new($false))

        $result=Invoke-AssetCreate $f

        $result.status | Should -Be 'blocked'
        $result.reasonCodes | Should -Contain 'LinkedCreateDrift'
        @($script:calls|Where-Object {$_.method -in @('POST','PUT')}).Count | Should -Be 0
        $script:assetPostCount | Should -Be 0;$script:bodyPutCount | Should -Be 0
    }
}
