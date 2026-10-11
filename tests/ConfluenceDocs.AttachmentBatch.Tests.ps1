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

function New-AttachmentBatchFixture {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('syp171-asset-batch-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $root 'assets') -Force|Out-Null
    $inputs=@{}
    foreach($id in @('101','102')){
        if($id -eq '101'){$bytes=[byte[]]@(0,255,13,10,42,128)}
        else{$bytes=[byte[]]@(1,254,11,12,43,129)}
        [IO.File]::WriteAllBytes((Join-Path $root "assets/$id.png"),$bytes)
        $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $inputs[$id]=[pscustomobject]@{bytes=$bytes;sha=$sha;projection="req-$id";remote="syp171-req-$id-$sha.png";attachmentId=$(if($id -eq '101'){'901'}else{'902'})}
    }
    return [pscustomobject]@{root=$root;inputs=$inputs}
}
function Remove-AttachmentBatchFixture {
    param([string]$Root)
    if(-not(Test-Path -LiteralPath $Root)){return}
    $full=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if([IO.Path]::GetDirectoryName($full).TrimEnd('\','/') -cne $parent -or
        [IO.Path]::GetFileName($full) -cnotmatch '^syp171-asset-batch-[a-f0-9]{32}$'){throw 'Unsafe batch fixture delete'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
function New-AttachmentBatchValidation {
    return [pscustomobject]@{status='valid';siteOrigin=$site;cloudId=$cloud;docsCommit=('1'*40);specCommit=('2'*40);codeCommit=('3'*40);sourceDigest=('a'*64);mappingDigest=('b'*64);reviewDigest=('c'*64);validatorVersion='1.13.0';rendererVersion='1';scenarioIds=@('SYP171-SCN-011','SYP171-SCN-012')}
}
function New-AttachmentBatchHttp {
    return {
        param($Request)
        $script:calls.Add([pscustomobject]@{method=[string]$Request.Method;uri=[string]$Request.Uri})
        if([string]$Request.Uri -match '/spaces/55/pages'){
            $rows=@()
            if($script:plainCreated){$rows=@(@{id='777';spaceId='55';parentId='99';title='Synthetic plain new SDD';status='current'})}
            foreach($page in $script:dependentPlainPages.Values){$rows+=@{id=$page.id;spaceId='55';parentId=$page.parentId;title=$page.title;status='current'}}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=$rows;_links=@{}}}
        }
        if($Request.Method -eq 'POST' -and [string]$Request.Uri -ceq "$api/wiki/api/v2/pages"){
            $script:plainPagePostCount++
            $payload=$Request.Body|ConvertFrom-Json -AsHashtable
            if($payload.title -cin @('Synthetic dependent parent','Synthetic dependent child')){
                $id=if($payload.title -ceq 'Synthetic dependent parent'){'777'}else{'778'}
                $expectedParent=if($id -eq '777'){'99'}else{'777'}
                if([string]$payload.parentId -cne $expectedParent){throw 'Dependent plain create parent is not confirmed'}
                $script:dependentPlainPages[$id]=@{id=$id;parentId=$expectedParent;title=[string]$payload.title;storage=[string]$payload.body.value}
                if($id -eq '777' -and $script:plainCreateTimeout){throw 'Synthetic dependent parent response lost'}
                return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id=$id;spaceId='55';parentId=$expectedParent;title=[string]$payload.title;status='current'}}
            }
            if($payload.parentId -cne '99' -or $payload.title -cne 'Synthetic plain new SDD' -or
                [string]$payload.body.value -cne '<p>Plain new SDD</p>'){
                throw 'Unexpected mixed plain create payload'
            }
            $script:plainCreated=$true;$script:plainStorage=[string]$payload.body.value
            if($script:plainCreateTimeout){throw 'Synthetic mixed plain create response timeout'}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='777';spaceId='55';parentId='99';title='Synthetic plain new SDD';status='current'}}
        }
        if([string]$Request.Uri -match '/pages/(101|102)/attachments'){
            $id=$Matches[1];$asset=$script:fixture.inputs[$id];$rows=@()
            if($script:uploaded[$id]){$rows=@(@{id=$asset.attachmentId;pageId=$id;status='current';title=$asset.remote;mediaType='image/png';fileSize=$asset.bytes.Length;comment=$script:comments[$id];version=@{number=1};downloadLink="/wiki/rest/api/content/$id/child/attachment/$($asset.attachmentId)/download"})}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=$rows;_links=@{}}}
        }
        if([string]$Request.Uri -match '/child/attachment/(901|902)/download\?version=1$'){
            $id=if($Matches[1] -eq '901'){'101'}else{'102'}
            $bytes=$script:fixture.inputs[$id].bytes
            return [pscustomobject]@{StatusCode=200;Headers=@{};BodyBytes=$bytes;Body=$bytes}
        }
        if($Request.Method -eq 'POST' -and [string]$Request.Uri -match '/content/(101|102)/child/attachment$'){
            $id=$Matches[1];$asset=$script:fixture.inputs[$id]
            $script:postCount[$id]++
            $expected="SYP171:$($script:operationId):$($asset.projection):$($asset.sha)"
            if($Request.BodyBytes -isnot [byte[]] -or [string]$Request.Headers['X-Atlassian-Token'] -cne 'nocheck' -or
                -not([Text.Encoding]::UTF8.GetString($Request.BodyBytes)).Contains($expected,[StringComparison]::Ordinal)){
                throw 'Invalid batch binary request'
            }
            $script:uploaded[$id]=$true
            $script:comments[$id]=$(if($id -eq '102' -and $script:failSecondUploadNoMarker){''}else{$expected})
            if($id -eq '102' -and $script:failSecondUploadNoMarker){throw 'Synthetic second upload timeout without owner marker'}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=@(@{id=$asset.attachmentId})}}
        }
        if($Request.Method -eq 'PUT' -and [string]$Request.Uri -match '/pages/(101|102)$'){
            $id=$Matches[1];$script:putCount[$id]++
            if($id -eq '102' -and $script:failSecondPut){throw 'Synthetic second-page body PUT failed'}
            $payload=$Request.Body|ConvertFrom-Json -AsHashtable
            if($payload.version.number -ne 8 -or -not([string]$payload.body.value).Contains("ri:filename=`"$($script:fixture.inputs[$id].remote)`"",[StringComparison]::Ordinal)){
                throw 'Invalid final batch body'
            }
            $script:pageStorage[$id]=[string]$payload.body.value;$script:pageVersion[$id]=8;$script:pageMessage[$id]=[string]$payload.version.message
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id=$id;version=@{number=8}}}
        }
        if([string]$Request.Uri -match '/pages/(101|102)\?'){
            $id=$Matches[1]
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id=$id;spaceId='55';parentId='99';title="Synthetic SDD $id";status='current';version=@{number=$script:pageVersion[$id];message=$script:pageMessage[$id]};body=@{storage=@{value=$script:pageStorage[$id]}}}}
        }
        if([string]$Request.Uri -match '/pages/(777|778)\?' -and $script:dependentPlainPages.ContainsKey($Matches[1])){
            $page=$script:dependentPlainPages[$Matches[1]]
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id=$page.id;spaceId='55';parentId=$page.parentId;title=$page.title;status='current';version=@{number=1;message=''};body=@{storage=@{value=$page.storage}}}}
        }
        if([string]$Request.Uri -match '/pages/777\?'){
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='777';spaceId='55';parentId='99';title='Synthetic plain new SDD';status='current';version=@{number=1;message=''};body=@{storage=@{value=$script:plainStorage}}}}
        }
        if([string]$Request.Uri -match '/pages/99\?'){
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='99';spaceId='55';parentId='10';title='Synthetic parent';status='current';version=@{number=7};body=@{storage=@{value='<p>Parent</p>'}}}}
        }
        throw "Unexpected batch request: $($Request.Method) $($Request.Uri)"
    }
}
function New-AttachmentBatchPlan {
    param([switch]$NoOpFirst,[switch]$IncludePlainCreate,[switch]$IncludeDependentPlainCreates)
    Import-Module -Name $planModule -Force
    $payloads=@(foreach($id in @('101','102')){
        $asset=$script:fixture.inputs[$id]
        $storage="<p>Final $id</p><ac:image><ri:attachment ri:filename=`"$($asset.remote)`" /></ac:image>"
        if($NoOpFirst -and $id -eq '101'){
            $script:uploaded[$id]=$true;$script:comments[$id]='prior-managed-fixture';$script:pageStorage[$id]=$storage
        }
        [pscustomobject]@{projectionId=$asset.projection;pageId=$id;spaceId='55';parentId='99';title="Synthetic SDD $id"
            bodyStorage=$storage
            assetChanges=@([pscustomobject]@{localPath="assets/$id.png";displayFilename="$id.png";mediaType='image/png';sha256=$asset.sha})}
    })
    if($IncludePlainCreate){
        $payloads+= [pscustomobject]@{projectionId='req-plain';pageId=$null;spaceId='55';parentId='99';title='Synthetic plain new SDD'
            bodyStorage='<p>Plain new SDD</p>';assetChanges=@()}
    }
    if($IncludeDependentPlainCreates){
        $payloads+=@(
            [pscustomobject]@{projectionId='req-child';pageId=$null;spaceId='55';parentId='';parentProjectionId='req-parent';title='Synthetic dependent child';bodyStorage='<p>Dependent child</p>';assetChanges=@()},
            [pscustomobject]@{projectionId='req-parent';pageId=$null;spaceId='55';parentId='99';title='Synthetic dependent parent';bodyStorage='<p>Dependent parent</p>';assetChanges=@()}
        )
    }
    $preview=New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixture.root 'plan.json') -Validation (New-AttachmentBatchValidation) -Payloads $payloads -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-AttachmentBatchHttp) -ValidationInputs ([pscustomobject]@{root=$script:fixture.root})
    if($preview.status -cne 'preview'){throw "Batch preview failed: $($preview.reasonCodes -join ',')"}
    $plan=Get-Content -LiteralPath $preview.planPath -Raw|ConvertFrom-Json
    $script:operationId=$plan.operationId
    $approved=if($NoOpFirst){@('update:102')}else{@('update:101','update:102')}
    if($IncludePlainCreate){$approved=@($approved)+@('create:req-plain')}
    if($IncludeDependentPlainCreates){$approved=@($approved)+@('create:req-parent','create:req-child')}
    $auth=@{schemaVersion=1;planSha256=$preview.planSha256;operationId=$plan.operationId;siteOrigin=$site;cloudId=$cloud;approvedActions=@($approved);approvalEvidenceRef='synthetic-batch-fixture-only'}
    $authPath=Join-Path $script:fixture.root 'authorization.json'
    [IO.File]::WriteAllText($authPath,($auth|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{plan=$preview.planPath;auth=$authPath;journal=(Join-Path $script:fixture.root 'journal.json');sync=(Join-Path $script:fixture.root 'sync.json')}
}
function Invoke-AttachmentBatch {
    param($Fixture)
    Import-Module -Name $publishModule -Force
    return Invoke-ConfluencePlan -PlanPath $Fixture.plan -CurrentValidation (New-AttachmentBatchValidation) -AuthorizationPath $Fixture.auth -JournalPath $Fixture.journal -SyncPath $Fixture.sync -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-AttachmentBatchHttp)
}

}

Describe 'SYP-171 two-page attachment batch journal recovery' {
    BeforeEach{
        $script:fixture=New-AttachmentBatchFixture;$script:calls=[System.Collections.Generic.List[object]]::new()
        $script:uploaded=@{'101'=$false;'102'=$false};$script:comments=@{'101'='';'102'=''}
        $script:postCount=@{'101'=0;'102'=0};$script:putCount=@{'101'=0;'102'=0}
        $script:pageStorage=@{'101'='<p>Old 101</p>';'102'='<p>Old 102</p>'}
        $script:pageVersion=@{'101'=7;'102'=7};$script:pageMessage=@{'101'='';'102'=''}
        $script:failSecondPut=$false;$script:failSecondUploadNoMarker=$false;$script:operationId=''
        $script:plainCreated=$false;$script:plainStorage='';$script:plainPagePostCount=0;$script:plainCreateTimeout=$false;$script:dependentPlainPages=@{}
    }
    AfterEach{Remove-AttachmentBatchFixture -Root $script:fixture.root}

    # Scenario: SYP171-SCN-011/012; the second page body write fails after both attachments are confirmed.
    # Purpose: Per-page journal evidence permits resume without replaying page 101 or either attachment POST; sync waits for both full readbacks.
    It 'InterT10_resumes_partial_binary_batch_without_replaying_confirmed_page_or_assets' {
        $f=New-AttachmentBatchPlan;$script:failSecondPut=$true
        $first=Invoke-AttachmentBatch $f
        if($first.status -ne 'uncertain' -or $script:postCount['101'] -ne 1 -or $script:postCount['102'] -ne 1){
            throw "Batch first status=$($first.status) reason=$($first.reasonCodes -join ',') calls=$(@($script:calls|ForEach-Object {'{0}:{1}' -f $_.method,$_.uri}) -join ',')"
        }
        $first.status | Should -Be 'uncertain'
        (Test-Path -LiteralPath $f.sync) | Should -Be $false
        $script:postCount['101'] | Should -Be 1;$script:postCount['102'] | Should -Be 1
        $script:putCount['101'] | Should -Be 1;$script:putCount['102'] | Should -Be 1
        $journal=Get-Content -LiteralPath $f.journal -Raw|ConvertFrom-Json
        @($journal.pages).Count | Should -Be 2
        $journal.pages[0].stage | Should -Be 'readback-confirmed'
        $journal.pages[1].assets[0].remoteAttachmentId | Should -Be '902'
        $script:failSecondPut=$false;$script:calls.Clear()
        (Invoke-AttachmentBatch $f).status | Should -Be 'published'
        $script:postCount['101'] | Should -Be 1;$script:postCount['102'] | Should -Be 1
        $script:putCount['101'] | Should -Be 1;$script:putCount['102'] | Should -Be 2
        @($script:calls|Where-Object method -eq 'POST').Count | Should -Be 0
        $sync=Get-Content -LiteralPath $f.sync -Raw|ConvertFrom-Json
        @($sync.pages).Count | Should -Be 2
        $script:calls.Clear()
        (Invoke-AttachmentBatch $f).status | Should -Be 'no-op'
        @($script:calls|Where-Object method -ne 'GET').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-011/012; page 101 is confirmed, but page 102 upload times out without a unique marker.
    # Purpose: The first page remains journaled while the second stays uncertain and neither POST is replayed.
    It 'UnitT20_preserves_first_page_and_does_not_replay_unowned_second_upload' {
        $f=New-AttachmentBatchPlan;$script:failSecondUploadNoMarker=$true
        $first=Invoke-AttachmentBatch $f
        $first.status | Should -Be 'uncertain'
        (Test-Path -LiteralPath $f.sync) | Should -Be $false
        $journal=Get-Content -LiteralPath $f.journal -Raw|ConvertFrom-Json
        $journal.pages[0].stage | Should -Be 'readback-confirmed'
        $journal.pages[1].assets[0].stage | Should -Be 'write-sent'
        $script:postCount['101'] | Should -Be 1;$script:postCount['102'] | Should -Be 1
        $script:failSecondUploadNoMarker=$false;$script:calls.Clear()
        (Invoke-AttachmentBatch $f).status | Should -Be 'uncertain'
        $script:postCount['101'] | Should -Be 1;$script:postCount['102'] | Should -Be 1
        @($script:calls|Where-Object method -ne 'GET').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-012; page 101 body and binary are already exact while page 102 needs an update.
    # Purpose: Batch publishes only the changed page, preserves the exact no-op page, and verifies both during resume.
    It 'InterT30_keeps_exact_no_op_asset_page_unchanged_in_mixed_batch' {
        $f=New-AttachmentBatchPlan -NoOpFirst
        $plan=Get-Content -LiteralPath $f.plan -Raw|ConvertFrom-Json
        $plan.pages[0].action | Should -Be 'no-op'
        $plan.pages[1].action | Should -Be 'update'
        (Invoke-AttachmentBatch $f).status | Should -Be 'published'
        $script:postCount['101'] | Should -Be 0;$script:putCount['101'] | Should -Be 0
        $script:postCount['102'] | Should -Be 1;$script:putCount['102'] | Should -Be 1
        $sync=Get-Content -LiteralPath $f.sync -Raw|ConvertFrom-Json
        @($sync.pages).Count | Should -Be 1
        $sync.pages[0].pageId | Should -Be '102'
        $script:calls.Clear()
        (Invoke-AttachmentBatch $f).status | Should -Be 'no-op'
        @($script:calls|Where-Object method -ne 'GET').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-011/012; two attached page updates and one independent plain new page share an immutable plan.
    # Purpose: The plain page uses its direct final create/readback while attached pages retain their per-page stages and whole-batch no-op.
    It 'InterT40_handles_plain_new_page_in_attached_batch_without_extra_version' {
        $f=New-AttachmentBatchPlan -IncludePlainCreate
        $plan=Get-Content -LiteralPath $f.plan -Raw|ConvertFrom-Json
        @($plan.pages).Count | Should -Be 3
        $plan.pages[2].action | Should -Be 'create'
        (Invoke-AttachmentBatch $f).status | Should -Be 'published'
        $script:plainPagePostCount | Should -Be 1
        $script:postCount['101'] | Should -Be 1;$script:postCount['102'] | Should -Be 1
        $sync=Get-Content -LiteralPath $f.sync -Raw|ConvertFrom-Json
        @($sync.pages).Count | Should -Be 3
        $sync.pages[2].pageId | Should -Be '777'
        $sync.pages[2].version | Should -Be 1
        $script:calls.Clear()
        (Invoke-AttachmentBatch $f).status | Should -Be 'no-op'
        @($script:calls|Where-Object method -ne 'GET').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-011; mixed batch's plain create succeeds remotely but returns no page ID.
    # Purpose: Confirmed attached pages remain journaled, while title search cannot claim the new page and no second create POST occurs.
    It 'UnitT50_keeps_lost_mixed_plain_create_response_uncertain_without_repost' {
        $f=New-AttachmentBatchPlan -IncludePlainCreate;$script:plainCreateTimeout=$true
        (Invoke-AttachmentBatch $f).status | Should -Be 'uncertain'
        (Test-Path -LiteralPath $f.sync) | Should -Be $false
        $journal=Get-Content -LiteralPath $f.journal -Raw|ConvertFrom-Json
        $journal.pages[0].stage | Should -Be 'readback-confirmed'
        $journal.pages[1].stage | Should -Be 'readback-confirmed'
        $journal.pages[2].stage | Should -Be 'page-create-write-sent'
        $script:plainPagePostCount | Should -Be 1
        $script:plainCreateTimeout=$false;$script:calls.Clear()
        (Invoke-AttachmentBatch $f).status | Should -Be 'uncertain'
        $script:plainPagePostCount | Should -Be 1
        @($script:calls|Where-Object method -ne 'GET').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-011/012; an attached update and two dependent plain creates share a single operation.
    # Purpose: The attached dispatcher must use the confirmed parent server ID, then preserve whole-plan no-op.
    It 'InterT60_creates_dependent_plain_pages_after_attached_updates' {
        $f=New-AttachmentBatchPlan -IncludeDependentPlainCreates
        (Invoke-AttachmentBatch $f).status | Should -Be 'published'
        $script:dependentPlainPages['778'].parentId | Should -Be '777'
        $sync=Get-Content -LiteralPath $f.sync -Raw|ConvertFrom-Json
        @($sync.pages.pageId) | Should -Be @('101','102','777','778')
        $script:calls.Clear()
        (Invoke-AttachmentBatch $f).status | Should -Be 'no-op'
        @($script:calls|Where-Object method -ne 'GET').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-011; the dependent parent create result is uncertain inside an attached batch.
    # Purpose: The child is never created and neither page is rePOSTed on retry.
    It 'UnitT70_skips_dependent_child_after_uncertain_mixed_parent_create' {
        $f=New-AttachmentBatchPlan -IncludeDependentPlainCreates;$script:plainCreateTimeout=$true
        (Invoke-AttachmentBatch $f).status | Should -Be 'uncertain'
        $script:plainPagePostCount | Should -Be 1
        $script:plainCreateTimeout=$false;$script:calls.Clear()
        (Invoke-AttachmentBatch $f).status | Should -Be 'uncertain'
        @($script:calls|Where-Object method -ne 'GET').Count | Should -Be 0
    }
}
