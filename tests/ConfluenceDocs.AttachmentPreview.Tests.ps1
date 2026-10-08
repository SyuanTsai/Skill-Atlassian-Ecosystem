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

function New-AttachmentPreviewFixture {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('syp171-attachment-preview-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $root 'assets') -Force | Out-Null
    $bytes=[byte[]]@(0,255,13,10,42,128)
    [IO.File]::WriteAllBytes((Join-Path $root 'assets/diagram.png'),$bytes)
    return [pscustomobject]@{root=$root;bytes=$bytes;sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()}
}

function New-AttachmentPublishFixture {
    $preview=Invoke-AttachmentPreview
    if($preview.status -ne 'preview'){throw "Attachment preview fixture failed: $($preview.reasonCodes -join ',')"}
    $plan=Get-Content -LiteralPath $preview.planPath -Raw|ConvertFrom-Json
    $script:expectedComment="SYP171:$($plan.operationId):req-001:$($script:fixture.sha)"
    $auth=@{schemaVersion=1;planSha256=$preview.planSha256;operationId=$plan.operationId;siteOrigin=$site;cloudId=$cloud;approvedActions=@('update:101');approvalEvidenceRef='synthetic-test-fixture-only'}
    $authPath=Join-Path $script:fixture.root 'authorization.json'
    [IO.File]::WriteAllText($authPath,($auth|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{plan=$preview.planPath;auth=$authPath;journal=(Join-Path $script:fixture.root 'journal.json');sync=(Join-Path $script:fixture.root 'sync.json');storage=$plan.pages[0].payloadPath;operationId=$plan.operationId}
}
function Test-BytesContain {
    param([byte[]]$Haystack,[byte[]]$Needle)
    for($i=0;$i -le $Haystack.Length-$Needle.Length;$i++){
        $match=$true
        for($j=0;$j -lt $Needle.Length;$j++){if($Haystack[$i+$j] -ne $Needle[$j]){$match=$false;break}}
        if($match){return $true}
    }
    return $false
}
function New-AttachmentPublishHttp {
    return {
        param($Request)
        $script:publishCalls.Add([pscustomobject]@{Method=$Request.Method;Uri=[string]$Request.Uri})
        if($Request.Uri -match '/pages/101/attachments'){
            $rows=@()
            if($script:uploaded){
                $rows=@(@{id='900';pageId='101';status='current';title="syp171-req-001-$($script:fixture.sha).png";mediaType='image/png';fileSize=$script:fixture.bytes.Length;comment=$script:remoteComment;version=@{number=1};downloadLink='/wiki/rest/api/content/101/child/attachment/900/download'})
            }
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=$rows;_links=@{}}}
        }
        if($Request.Uri -match '/child/attachment/900/download\?version=1$'){
            return [pscustomobject]@{StatusCode=200;Headers=@{};BodyBytes=$script:fixture.bytes;Body=$script:fixture.bytes}
        }
        if($Request.Method -eq 'POST'){
            $script:uploadCount++
            if($Request.Uri -cne "$api/wiki/rest/api/content/101/child/attachment" -or
                [string]$Request.Headers['X-Atlassian-Token'] -cne 'nocheck' -or
                [string]$Request.Headers['Content-Type'] -cnotmatch '^multipart/form-data; boundary=' -or
                $Request.BodyBytes -isnot [byte[]] -or
                -not(Test-BytesContain -Haystack $Request.BodyBytes -Needle $script:fixture.bytes) -or
                -not([Text.Encoding]::UTF8.GetString($Request.BodyBytes)).Contains($script:expectedComment,[StringComparison]::Ordinal)){
                throw 'Malformed synthetic binary upload request'
            }
            $script:uploaded=$true
            $script:remoteComment=$(if($script:publishMode -eq 'timeout-no-marker'){''}else{$script:expectedComment})
            if($script:publishMode -in @('timeout-after-upload','timeout-no-marker')){throw 'Synthetic upload response timeout'}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=@(@{id='900';title="syp171-req-001-$($script:fixture.sha).png"})}}
        }
        if($Request.Method -eq 'PUT'){
            $script:putCount++
            if($script:publishMode -eq 'put-fails'){throw 'Synthetic body update failure'}
            $body=$Request.Body|ConvertFrom-Json -AsHashtable
            $script:pageStorage=$body.body.value
            $script:pageVersion++
            $script:pageMessage=$body.version.message
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='101';version=@{number=$script:pageVersion}}}
        }
        if($script:tamperStagedAssetPath -ne '' -and -not $script:tamperedStagedAsset){
            [IO.File]::WriteAllBytes($script:tamperStagedAssetPath,[byte[]]@(3,2,1,0,255,128))
            $script:tamperedStagedAsset=$true
        }
        return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='101';spaceId='55';parentId='99';title='Synthetic SDD';status='current';version=@{number=$script:pageVersion;message=$script:pageMessage};body=@{storage=@{value=$script:pageStorage}}}}
    }
}
function Invoke-AttachmentPublish {
    param($PublishFixture)
    Import-Module -Name $publishModule -Force
    return Invoke-ConfluencePlan -PlanPath $PublishFixture.plan -CurrentValidation (New-AttachmentValidation) -AuthorizationPath $PublishFixture.auth -JournalPath $PublishFixture.journal -SyncPath $PublishFixture.sync -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-AttachmentPublishHttp)
}
function Remove-AttachmentPreviewFixture {
    param([string]$Root)
    if(-not(Test-Path -LiteralPath $Root)){return}
    $full=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if([IO.Path]::GetDirectoryName($full).TrimEnd('\','/') -cne $parent -or
        [IO.Path]::GetFileName($full) -cnotmatch '^syp171-attachment-preview-[a-f0-9]{32}$'){throw 'Unsafe attachment fixture delete'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
function New-AttachmentValidation {
    return [pscustomobject]@{status='valid';siteOrigin=$site;cloudId=$cloud;docsCommit=('1'*40);specCommit=('2'*40);codeCommit=('3'*40);sourceDigest=('a'*64);mappingDigest=('b'*64);reviewDigest=('c'*64);validatorVersion='1.13.0';rendererVersion='1';scenarioIds=@('SYP171-SCN-012')}
}
function New-AttachmentPayload {
    param([string]$LocalPath='assets/diagram.png')
    $remote="syp171-req-001-$($script:fixture.sha).png"
    return @([pscustomobject]@{
        projectionId='req-001';pageId='101';spaceId='55';parentId='99';title='Synthetic SDD'
        bodyStorage="<p>Expected once</p><ac:image><ri:attachment ri:filename=`"$remote`" /></ac:image>"
        assetChanges=@([pscustomobject]@{localPath=$LocalPath;displayFilename='diagram.png';mediaType='image/png';sha256=$script:fixture.sha})
    })
}
function New-AttachmentHttp {
    return {
        param($Request)
        $script:calls.Add([pscustomobject]@{Method=$Request.Method;Uri=[string]$Request.Uri})
        if($Request.Uri -match '/pages/101/attachments'){
            $rows=@()
            if($script:remoteMode -ne 'empty'){
                $rows=@(@{id='900';pageId='101';status='current';title="syp171-req-001-$($script:fixture.sha).png";mediaType='image/png';fileSize=$script:remoteBytes.Length;version=@{number=2};downloadLink='/wiki/rest/api/content/101/child/attachment/900/download'})
            }
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=$rows;_links=@{}}}
        }
        if($Request.Uri -match '/child/attachment/900/download\?version=2$'){
            return [pscustomobject]@{StatusCode=200;Headers=@{};BodyBytes=$script:remoteBytes;Body=$script:remoteBytes}
        }
        return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='101';spaceId='55';parentId='99';title='Synthetic SDD';status='current';version=@{number=7};body=@{storage=@{value=$script:pageStorage}}}}
    }
}
function Invoke-AttachmentPreview {
    param([string]$LocalPath='assets/diagram.png')
    Import-Module -Name $planModule -Force
    return New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixture.root 'plan.json') -Validation (New-AttachmentValidation) -Payloads (New-AttachmentPayload -LocalPath $LocalPath) -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-AttachmentHttp) -ValidationInputs ([pscustomobject]@{root=$script:fixture.root})
}

}

Describe 'SYP-171 immutable managed attachment preview' {
    BeforeEach{$script:fixture=New-AttachmentPreviewFixture;$script:calls=[System.Collections.Generic.List[object]]::new();$script:remoteMode='empty';$script:remoteBytes=$script:fixture.bytes;$script:pageStorage='<p>Previous</p>'}
    AfterEach{Remove-AttachmentPreviewFixture -Root $script:fixture.root}

    # Scenario: SYP171-SCN-012; an approved projection references an asset from the adopter root and the remote has none.
    # Purpose: Preview fixes binary bytes and the exact upload identity while making no write request.
    It 'UnitT10_stages_binary_asset_and_records_upload_in_immutable_plan' {
        $r=Invoke-AttachmentPreview
        $r.status | Should -Be 'preview'
        $plan=Get-Content -LiteralPath $r.planPath -Raw|ConvertFrom-Json
        $plan.pages[0].action | Should -Be 'update'
        @($plan.pages[0].assetChanges).Count | Should -Be 1
        $asset=$plan.pages[0].assetChanges[0]
        $asset.action | Should -Be 'upload'
        $asset.sha256 | Should -Be $script:fixture.sha
        $asset.remoteFilename | Should -Be "syp171-req-001-$($script:fixture.sha).png"
        $asset.displayFilename | Should -Be 'diagram.png'
        $asset.mediaType | Should -Be 'image/png'
        (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $script:fixture.root $asset.payloadPath)).Hash.ToLowerInvariant() | Should -Be $script:fixture.sha
        @($script:calls|Where-Object Method -ne 'GET').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-009; mapping points outside the adopter root.
    # Purpose: Unsafe asset path is rejected before remote reads or plan writes.
    It 'UnitT20_rejects_asset_path_escape_before_remote_IO' {
        $r=Invoke-AttachmentPreview -LocalPath '../other.bin'
        $r.status | Should -Be 'invalid'
        (Test-Path -LiteralPath (Join-Path $script:fixture.root 'plan.json')) | Should -Be $false
        $script:calls.Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-012; an exact managed attachment already exists with matching bytes.
    # Purpose: Preview reuses the same ID/version and makes no second upload.
    It 'UnitT30_reuses_exact_remote_asset_after_binary_readback' {
        $script:remoteMode='existing'
        $r=Invoke-AttachmentPreview
        if($r.status -ne 'preview'){throw "Expected reuse preview: $($r.reasonCodes -join ',')"}
        $r.status | Should -Be 'preview'
        $plan=Get-Content -LiteralPath $r.planPath -Raw|ConvertFrom-Json
        $asset=$plan.pages[0].assetChanges[0]
        $asset.action | Should -Be 'reuse'
        $asset.remoteAttachmentId | Should -Be '900'
        $asset.remoteVersion | Should -Be 2
        @($script:calls|Where-Object Method -ne 'GET').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-010; staged bytes change after the preview candidate was reviewed.
    # Purpose: Drift blocks before remote access or binary upload.
    It 'UnitT40_blocks_tampered_staged_binary_before_HTTP' {
        $r=Invoke-AttachmentPreview
        $plan=Get-Content -LiteralPath $r.planPath -Raw|ConvertFrom-Json
        [IO.File]::WriteAllBytes((Join-Path $script:fixture.root $plan.pages[0].assetChanges[0].payloadPath),[byte[]]@(1,2,3))
        $script:calls.Clear()
        $check=Test-ConfluencePlanDrift -PlanPath $r.planPath -CurrentValidation (New-AttachmentValidation) -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-AttachmentHttp)
        @($check.reasonCodes) | Should -Contain 'PayloadChanged'
        $script:calls.Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-012; a fresh immutable plan sees identical body and exact already-managed binary.
    # Purpose: A new no-op candidate needs no attachment upload, page version, or journal.
    It 'InterT50_accepts_fresh_exact_asset_and_body_no_op_without_write' {
        $script:remoteMode='existing';$script:pageStorage=(New-AttachmentPayload)[0].bodyStorage
        $preview=Invoke-AttachmentPreview
        $preview.status | Should -Be 'preview'
        $plan=Get-Content -LiteralPath $preview.planPath -Raw|ConvertFrom-Json
        $plan.pages[0].action | Should -Be 'no-op'
        @($plan.pages[0].intermediateWrites) | Should -Be @('no-op')
        $auth=@{schemaVersion=1;planSha256=$preview.planSha256;operationId=$plan.operationId;siteOrigin=$site;cloudId=$cloud;approvedActions=@();approvalEvidenceRef='synthetic-no-op-only'}
        $authPath=Join-Path $script:fixture.root 'authorization.json'
        [IO.File]::WriteAllText($authPath,($auth|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
        Import-Module -Name $publishModule -Force
        $script:calls.Clear()
        $r=Invoke-ConfluencePlan -PlanPath $preview.planPath -CurrentValidation (New-AttachmentValidation) -AuthorizationPath $authPath -JournalPath (Join-Path $script:fixture.root 'journal.json') -SyncPath (Join-Path $script:fixture.root 'sync.json') -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-AttachmentHttp)
        $r.status | Should -Be 'no-op'
        @($script:calls|Where-Object Method -ne 'GET').Count | Should -Be 0
        (Test-Path -LiteralPath (Join-Path $script:fixture.root 'journal.json')) | Should -Be $false
    }
}

Describe 'SYP-171 managed binary attachment publication and recovery' {
    BeforeEach{
        $script:fixture=New-AttachmentPreviewFixture
        $script:calls=[System.Collections.Generic.List[object]]::new();$script:remoteMode='empty';$script:remoteBytes=$script:fixture.bytes
        $script:publishCalls=[System.Collections.Generic.List[object]]::new();$script:uploaded=$false;$script:remoteComment=''
        $script:uploadCount=0;$script:putCount=0;$script:publishMode='normal'
        $script:tamperStagedAssetPath='';$script:tamperedStagedAsset=$false
        $script:pageStorage='<p>Previous</p>';$script:pageVersion=7;$script:pageMessage=''
    }
    AfterEach{Remove-AttachmentPreviewFixture -Root $script:fixture.root}

    # Scenario: SYP171-SCN-012; one exact managed attachment and page body are approved together.
    # Purpose: Binary upload is read back by ID/version/hash before sync, and a repeat does not upload or version the page.
    It 'InterT50_uploads_binary_then_reads_back_asset_and_body_before_no_op' {
        $f=New-AttachmentPublishFixture
        $r=Invoke-AttachmentPublish $f
        $r.status | Should -Be 'published'
        $script:uploadCount | Should -Be 1
        $script:putCount | Should -Be 1
        $script:pageVersion | Should -Be 8
        $sync=Get-Content -LiteralPath $f.sync -Raw|ConvertFrom-Json
        $sync.pages[0].assets[0].remoteAttachmentId | Should -Be '900'
        $sync.pages[0].assets[0].sha256 | Should -Be $script:fixture.sha
        $script:publishCalls.Clear()
        (Invoke-AttachmentPublish $f).status | Should -Be 'no-op'
        $script:uploadCount | Should -Be 1
        $script:putCount | Should -Be 1
        @($script:publishCalls|Where-Object Method -ne 'GET').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-012; attachment upload succeeds but page body update fails.
    # Purpose: Journal retains the verified asset and old body; resume under the same ID reuses it without a second POST.
    It 'InterT60_resumes_after_uploaded_asset_and_failed_body_without_reupload' {
        $f=New-AttachmentPublishFixture
        $script:publishMode='put-fails'
        $first=Invoke-AttachmentPublish $f
        $first.status | Should -Be 'uncertain'
        $script:uploaded | Should -Be $true
        $script:pageStorage | Should -Be '<p>Previous</p>'
        (Test-Path -LiteralPath $f.sync) | Should -Be $false
        $journal=Get-Content -LiteralPath $f.journal -Raw|ConvertFrom-Json
        $journal.operationId | Should -Be $f.operationId
        $journal.pages[0].assets[0].remoteAttachmentId | Should -Be '900'
        $script:publishMode='normal';$script:publishCalls.Clear()
        (Invoke-AttachmentPublish $f).status | Should -Be 'published'
        $script:uploadCount | Should -Be 1
        $script:putCount | Should -Be 2
        @($script:publishCalls|Where-Object Method -eq 'POST').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-011/012; upload reached the server but response timed out without a unique operation marker.
    # Purpose: Uncertain attachment identity prevents body write and blind re-upload on the same operation.
    It 'UnitT70_keeps_unmarked_upload_timeout_uncertain_without_second_post' {
        $f=New-AttachmentPublishFixture
        $script:publishMode='timeout-no-marker'
        $first=Invoke-AttachmentPublish $f
        $first.status | Should -Be 'uncertain'
        $script:uploaded | Should -Be $true
        $script:putCount | Should -Be 0
        (Test-Path -LiteralPath $f.sync) | Should -Be $false
        $script:publishMode='normal';$script:publishCalls.Clear()
        (Invoke-AttachmentPublish $f).status | Should -Be 'uncertain'
        $script:uploadCount | Should -Be 1
        @($script:publishCalls|Where-Object Method -eq 'POST').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-007/010/012; a staged binary changes after static validation and before the upload.
    # Purpose: This invocation uploads the frozen verified bytes; a later invocation rejects the changed stage.
    It 'UnitT80_freezes_verified_binary_before_remote_preflight_and_upload' {
        $f=New-AttachmentPublishFixture
        $plan=Get-Content -LiteralPath $f.plan -Raw|ConvertFrom-Json
        $script:tamperStagedAssetPath=Join-Path $script:fixture.root ([string]$plan.pages[0].assetChanges[0].payloadPath)
        (Invoke-AttachmentPublish $f).status | Should -Be 'published'
        $script:tamperedStagedAsset | Should -Be $true
        $script:uploadCount | Should -Be 1
        $script:publishCalls.Clear()
        $again=Invoke-AttachmentPublish $f
        $again.status | Should -Be 'blocked'
        @($again.reasonCodes) | Should -Contain 'PayloadChanged'
        @($script:publishCalls|Where-Object Method -eq 'POST').Count | Should -Be 0
    }
}
