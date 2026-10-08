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

function New-LinkedFixtureRoot {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('syp171-linked-publish-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force|Out-Null
    return $root
}
function Remove-LinkedFixtureRoot {
    param([string]$Root)
    if(-not(Test-Path -LiteralPath $Root)){return}
    $full=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if([IO.Path]::GetDirectoryName($full).TrimEnd('\','/') -cne $parent -or
        [IO.Path]::GetFileName($full) -cnotmatch '^syp171-linked-publish-[a-f0-9]{32}$'){throw 'Unsafe linked fixture delete'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
function New-LinkedValidation {
    return [pscustomobject]@{status='valid';siteOrigin=$site;cloudId=$cloud;docsCommit=('1'*40);specCommit=('2'*40);codeCommit=('3'*40);sourceDigest=('a'*64);mappingDigest=$script:mappingDigest;reviewDigest=('c'*64);validatorVersion='1.13.0';rendererVersion='1';scenarioIds=@('SYP171-SCN-009','SYP171-SCN-011','SYP171-SCN-012')}
}
function New-LinkedHttp {
    return {
        param($Request)
        $script:calls.Add([pscustomobject]@{method=[string]$Request.Method;uri=[string]$Request.Uri;body=[string]$Request.Body})
        if($Request.Uri -match '/pages/201/attachments'){
            $rows=@()
            if($script:uploaded){$rows=@(@{id='900';pageId='201';status='current';title=$script:remoteAssetName;mediaType='image/png';fileSize=$script:assetBytes.Length;comment=$script:uploadedComment;version=@{number=1};downloadLink='/wiki/rest/api/content/201/child/attachment/900/download'})}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=$rows;_links=@{}}}
        }
        if($Request.Uri -match '/pages/202/attachments'){
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=@();_links=@{}}}
        }
        if($Request.Uri -match '/child/attachment/900/download\?version=1$'){
            return [pscustomobject]@{StatusCode=200;Headers=@{};BodyBytes=$script:assetBytes;Body=$script:assetBytes}
        }
        if($Request.Method -ceq 'POST' -and $Request.Uri -match '/content/201/child/attachment$'){
            if($Request.BodyBytes -isnot [byte[]] -or [string]$Request.Comment -cnotmatch '^SYP171:' -or $script:uploaded){throw 'Malformed or duplicate managed upload'}
            $script:uploaded=$true;$script:uploadedComment=$(if($script:unmarkedUpload){''}else{[string]$Request.Comment})
            if($script:uploadResponseTimeout){throw 'Synthetic attachment response timeout'}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=@(@{id='900';title=$script:remoteAssetName})}}
        }
        if($Request.Uri -match '/spaces/55/pages'){
            $rows=@($script:pages.Values|ForEach-Object {@{id=$_.id;spaceId=$_.spaceId;parentId=$_.parentId;title=$_.title;status='current'}})
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=$rows;_links=@{}}}
        }
        if($Request.Method -ceq 'POST'){
            $body=$Request.Body|ConvertFrom-Json -AsHashtable
            if([string]$body.body.value -match '__SYP171_LINK_'){throw 'Deferred template was sent as a page body'}
            $id=if($body.title -ceq 'Linked A'){'201'}else{'202'}
            if($script:pages.ContainsKey($id)){throw 'Duplicate page POST'}
            if($script:dependentParent -and $id -eq '202' -and [string]$body.parentId -cne '201'){throw 'Child used an unconfirmed parent ID'}
            $script:pages[$id]=@{id=$id;spaceId='55';parentId=[string]$body.parentId;title=[string]$body.title;storage=[string]$body.body.value;version=1;message=''}
            if(($script:lostFirstCreate -and $id -eq '201') -or ($script:lostSecondCreate -and $id -eq '202')){throw 'Synthetic lost create response'}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id=$id;spaceId='55';parentId=[string]$body.parentId;title=[string]$body.title;status='current'}}
        }
        if($Request.Method -ceq 'PUT'){
            $body=$Request.Body|ConvertFrom-Json -AsHashtable
            $id=[string]$body.id
            if($script:failFinalBeforeApply -and $id -eq '202'){throw 'Synthetic failed final PUT before apply'}
            if(-not $script:pages.ContainsKey($id) -or $body.version.number -ne $script:pages[$id].version+1 -or
                [string]$body.body.value -match '__SYP171_LINK_'){throw 'Malformed linked final body write'}
            $script:pages[$id].storage=[string]$body.body.value
            $script:pages[$id].version=[int]$body.version.number
            $script:pages[$id].message=[string]$body.version.message
            if($script:timeoutFinalAfterApply -and $id -eq '201'){throw 'Synthetic final PUT response timeout'}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id=$id;version=@{number=$script:pages[$id].version}}}
        }
        $id=if($Request.Uri -match '/pages/([0-9]+)'){$Matches[1]}else{''}
        if($script:pages.ContainsKey($id)){
            $page=$script:pages[$id]
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id=$page.id;spaceId=$page.spaceId;parentId=$page.parentId;title=$page.title;status='current';version=@{number=$page.version;message=$page.message};body=@{storage=@{value=$page.storage}}}}
        }
        return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='99';spaceId='55';parentId='10';title='Synthetic external parent';status='current';version=@{number=7;message=''};body=@{storage=@{value='<p>Parent</p>'}}}}
    }
}
function New-LinkedPlan {
    param([switch]$WithAsset,[switch]$DependentParent,[switch]$WithExistingA)
    Import-Module -Name $planModule -Force
    $assets=@()
    $assetStorage=''
    if($WithAsset){
        New-Item -ItemType Directory -Path (Join-Path $script:fixture 'assets') -Force|Out-Null
        $script:assetBytes=[byte[]]@(137,80,78,71,13,10,26,10)
        [IO.File]::WriteAllBytes((Join-Path $script:fixture 'assets/diagram.png'),$script:assetBytes)
        $script:assetSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($script:assetBytes)).ToLowerInvariant()
        $script:remoteAssetName="syp171-req-a-$($script:assetSha).png"
        $assets=@([pscustomobject]@{localPath='assets/diagram.png';displayFilename='diagram.png';mediaType='image/png';sha256=$script:assetSha})
        $assetStorage="<ac:image><ri:attachment ri:filename=`"$($script:remoteAssetName)`" /></ac:image>"
    }
    $a=[pscustomobject]@{projectionId='req-a';pageId=$null;spaceId='55';parentId='99';title='Linked A';bodyStorage=('<p><a href="https://example.atlassian.net/wiki/pages/viewpage.action?pageId=__SYP171_LINK_req-b__">B</a></p>'+$assetStorage);deferredTargets=@('req-b');assetChanges=$assets}
    $b=[pscustomobject]@{projectionId='req-b';pageId=$null;spaceId='55';parentId='99';title='Linked B';bodyStorage='<p><a href="https://example.atlassian.net/wiki/pages/viewpage.action?pageId=__SYP171_LINK_req-a__">A</a></p>';deferredTargets=@('req-a');assetChanges=@()}
    if($WithExistingA){
        if($DependentParent){throw 'Existing A fixture uses an independent parent'}
        $script:pages['201']=@{id='201';spaceId='55';parentId='99';title='Linked A';storage='<p>Old A</p>';version=3;message=''}
        $a.pageId='201'
        $b.bodyStorage='<p><a href="https://example.atlassian.net/wiki/pages/viewpage.action?pageId=201">A</a></p>'
        $b.deferredTargets=@()
        if($WithAsset){
            $script:uploaded=$true;$script:uploadedComment=''
            $a.bodyStorage='<p>Static A</p>'+$assetStorage
            $a.deferredTargets=@()
            $script:pages['201'].storage=$a.bodyStorage
            $b.bodyStorage='<p><a href="https://example.atlassian.net/wiki/pages/viewpage.action?pageId=__SYP171_LINK_req-b__">Self</a> <a href="https://example.atlassian.net/wiki/pages/viewpage.action?pageId=201">A</a></p>'
            $b.deferredTargets=@('req-b')
        }
    }
    if($DependentParent){$b.parentId='';$b|Add-Member -NotePropertyName parentProjectionId -NotePropertyValue 'req-a'}
    $payloads=@($a,$b)
    $preview=New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixture 'linked-plan.json') -Validation (New-LinkedValidation) -Payloads $payloads -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-LinkedHttp) -ValidationInputs ([pscustomobject]@{root=$script:fixture})
    if($preview.status -cne 'preview'){throw "Linked preview failed: $($preview.reasonCodes -join ',')"}
    $plan=Get-Content -LiteralPath $preview.planPath -Raw|ConvertFrom-Json
    $actions=if($WithExistingA -and $WithAsset){@('create:req-b')}elseif($WithExistingA){@('update:201','create:req-b')}else{@('create:req-a','create:req-b')}
    $auth=@{schemaVersion=1;planSha256=$preview.planSha256;operationId=$plan.operationId;siteOrigin=$site;cloudId=$cloud;approvedActions=@($actions);approvalEvidenceRef='synthetic-test-fixture-only'}
    $authPath=Join-Path $script:fixture 'linked-authorization.json'
    [IO.File]::WriteAllText($authPath,($auth|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{plan=$preview.planPath;auth=$authPath;journal=(Join-Path $script:fixture 'linked-journal.json');sync=(Join-Path $script:fixture 'linked-sync.json')}
}
function Invoke-LinkedPublish {
    param($Fixture)
    Import-Module -Name $publishModule -Force
    return Invoke-ConfluencePlan -PlanPath $Fixture.plan -CurrentValidation (New-LinkedValidation) -AuthorizationPath $Fixture.auth -JournalPath $Fixture.journal -SyncPath $Fixture.sync -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-LinkedHttp)
}

}

Describe 'SYP-171 source-bound new-page interlinks' {
    BeforeEach{$script:fixture=New-LinkedFixtureRoot;$script:pages=@{};$script:calls=[System.Collections.Generic.List[object]]::new();$script:mappingDigest=('b'*64);$script:lostFirstCreate=$false;$script:lostSecondCreate=$false;$script:uploaded=$false;$script:uploadedComment='';$script:remoteAssetName='';$script:assetBytes=[byte[]]@();$script:uploadResponseTimeout=$false;$script:unmarkedUpload=$false;$script:failFinalBeforeApply=$false;$script:timeoutFinalAfterApply=$false;$script:dependentParent=$false}
    AfterEach{Remove-LinkedFixtureRoot -Root $script:fixture}

    # Scenario: SYP171-SCN-009/011/012; two new native projections point to each other.
    # Purpose: Both identities are created/read back before either final link body; sync advances only after final readback.
    It 'InterT10_creates_both_identities_before_final_interlinks_and_no_op' {
        $f=New-LinkedPlan
        $script:calls.Clear()
        $r=Invoke-LinkedPublish $f
        $r.status | Should -Be 'published'
        $writes=@($script:calls|Where-Object {$_.method -in @('POST','PUT')})
        @($writes.method) | Should -Be @('POST','POST','PUT','PUT')
        $script:pages['201'].version | Should -Be 2
        $script:pages['202'].version | Should -Be 2
        $script:pages['201'].storage | Should -Match 'pageId=202'
        $script:pages['202'].storage | Should -Match 'pageId=201'
        $sync=Get-Content -LiteralPath $f.sync -Raw|ConvertFrom-Json
        @($sync.pages.pageId) | Should -Be @('201','202')
        $script:calls.Clear()
        (Invoke-LinkedPublish $f).status | Should -Be 'no-op'
        @($script:calls|Where-Object {$_.method -in @('POST','PUT')}).Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-011; the first intermediate create reached the server but its response was lost.
    # Purpose: Journal keeps uncertain identity and resume never sends a second POST or any final link.
    It 'UnitT20_keeps_lost_identity_uncertain_without_duplicate_create' {
        $f=New-LinkedPlan
        $script:lostFirstCreate=$true;$script:calls.Clear()
        (Invoke-LinkedPublish $f).status | Should -Be 'uncertain'
        (Test-Path -LiteralPath $f.sync) | Should -Be $false
        @($script:calls|Where-Object method -eq 'POST').Count | Should -Be 1
        $script:pages.ContainsKey('201') | Should -Be $true
        $script:pages['201'].storage | Should -Match 'staging req-a'
        $script:lostFirstCreate=$false;$script:calls.Clear()
        (Invoke-LinkedPublish $f).status | Should -Be 'uncertain'
        @($script:calls|Where-Object {$_.method -in @('POST','PUT')}).Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-009/011/012; one of two interlinked new pages carries a managed native image.
    # Purpose: Both page identities precede upload, all binary bytes are read back, and final links/images are committed once.
    It 'InterT30_uploads_managed_binary_between_linked_identity_and_final_body' {
        $f=New-LinkedPlan -WithAsset
        $script:calls.Clear()
        $r=Invoke-LinkedPublish $f
        $r.status | Should -Be 'published'
        $writes=@($script:calls|Where-Object {$_.method -in @('POST','PUT')})
        @($writes.method) | Should -Be @('POST','POST','POST','PUT','PUT')
        $writes[2].uri | Should -Match '/content/201/child/attachment$'
        $script:uploaded | Should -Be $true
        $script:pages['201'].storage | Should -Match "ri:filename=`"$($script:remoteAssetName)`""
        $script:pages['201'].storage | Should -Match 'pageId=202'
        $script:pages['202'].storage | Should -Match 'pageId=201'
        $script:calls.Clear()
        (Invoke-LinkedPublish $f).status | Should -Be 'no-op'
        @($script:calls|Where-Object {$_.method -in @('POST','PUT')}).Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-011/012; a managed upload succeeds remotely but its response times out.
    # Purpose: Exact operation comment and binary readback reconcile one POST before final linked bodies.
    It 'UnitT40_reconciles_marked_attachment_timeout_without_reupload' {
        $f=New-LinkedPlan -WithAsset
        $script:uploadResponseTimeout=$true;$script:calls.Clear()
        (Invoke-LinkedPublish $f).status | Should -Be 'published'
        @($script:calls|Where-Object {$_.method -eq 'POST' -and $_.uri -match '/child/attachment$'}).Count | Should -Be 1
        $script:calls.Clear()
        (Invoke-LinkedPublish $f).status | Should -Be 'no-op'
        @($script:calls|Where-Object {$_.method -in @('POST','PUT')}).Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-011; upload reaches the page but its operation marker is absent.
    # Purpose: The linked operation stays uncertain without final body PUT or duplicate attachment POST.
    It 'UnitT50_keeps_unmarked_attachment_uncertain_without_second_post' {
        $f=New-LinkedPlan -WithAsset
        $script:unmarkedUpload=$true;$script:calls.Clear()
        (Invoke-LinkedPublish $f).status | Should -Be 'uncertain'
        (Test-Path -LiteralPath $f.sync) | Should -Be $false
        @($script:calls|Where-Object method -eq 'PUT').Count | Should -Be 0
        $script:unmarkedUpload=$false;$script:calls.Clear()
        (Invoke-LinkedPublish $f).status | Should -Be 'uncertain'
        @($script:calls|Where-Object {$_.method -in @('POST','PUT')}).Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-010/011; a final linked body PUT fails before the server applies it.
    # Purpose: Journal retains earlier confirmed page but never retries the ambiguous second PUT automatically.
    It 'UnitT60_keeps_failed_final_body_uncertain_without_blind_put' {
        $f=New-LinkedPlan
        $script:failFinalBeforeApply=$true;$script:calls.Clear()
        (Invoke-LinkedPublish $f).status | Should -Be 'uncertain'
        (Test-Path -LiteralPath $f.sync) | Should -Be $false
        $script:pages['201'].version | Should -Be 2
        $script:pages['202'].version | Should -Be 1
        $script:failFinalBeforeApply=$false;$script:calls.Clear()
        (Invoke-LinkedPublish $f).status | Should -Be 'uncertain'
        @($script:calls|Where-Object {$_.method -in @('POST','PUT')}).Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-011/012; a linked child also depends on its newly created parent.
    # Purpose: The child uses only the parent's confirmed intermediate identity, before either final body exists.
    It 'InterT70_creates_linked_child_under_confirmed_intermediate_parent' {
        $f=New-LinkedPlan -DependentParent
        $script:dependentParent=$true;$script:calls.Clear()
        (Invoke-LinkedPublish $f).status | Should -Be 'published'
        $script:pages['202'].parentId | Should -Be '201'
        @($script:calls|Where-Object method -eq 'POST').Count | Should -Be 2
        $script:pages['201'].storage | Should -Match 'pageId=202'
        $script:pages['202'].storage | Should -Match 'pageId=201'
    }

    # Scenario: SYP171-SCN-011/012; a final PUT applies but its HTTP response times out.
    # Purpose: Exact version, body hash and operation marker readback confirm success without duplicate PUT.
    It 'UnitT80_reconciles_marked_final_put_timeout_without_second_write' {
        $f=New-LinkedPlan
        $script:timeoutFinalAfterApply=$true;$script:calls.Clear()
        (Invoke-LinkedPublish $f).status | Should -Be 'published'
        @($script:calls|Where-Object method -eq 'PUT').Count | Should -Be 2
        $script:calls.Clear()
        (Invoke-LinkedPublish $f).status | Should -Be 'no-op'
        @($script:calls|Where-Object method -eq 'PUT').Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-012; verified new page IDs are committed into a new exact mapping revision.
    # Purpose: A fresh preview of the same final bodies becomes no-op under the new mapping digest and writes nothing.
    It 'InterT90_fresh_exact_page_id_mapping_yields_no_op_after_verified_links' {
        $f=New-LinkedPlan
        (Invoke-LinkedPublish $f).status | Should -Be 'published'
        $script:mappingDigest=('d'*64)
        Import-Module -Name $planModule -Force
        $payloads=@(
            [pscustomobject]@{projectionId='req-a';pageId='201';spaceId='55';parentId='99';title='Linked A';bodyStorage=[string]$script:pages['201'].storage;assetChanges=@()},
            [pscustomobject]@{projectionId='req-b';pageId='202';spaceId='55';parentId='99';title='Linked B';bodyStorage=[string]$script:pages['202'].storage;assetChanges=@()}
        )
        $preview=New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixture 'fresh-plan.json') -Validation (New-LinkedValidation) -Payloads $payloads -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-LinkedHttp)
        $preview.status | Should -Be 'preview'
        $plan=Get-Content -LiteralPath $preview.planPath -Raw|ConvertFrom-Json
        @($plan.pages.action) | Should -Be @('no-op','no-op')
        $auth=@{schemaVersion=1;planSha256=$preview.planSha256;operationId=$plan.operationId;siteOrigin=$site;cloudId=$cloud;approvedActions=@();approvalEvidenceRef='synthetic-test-fixture-only'}
        $authPath=Join-Path $script:fixture 'fresh-auth.json'
        [IO.File]::WriteAllText($authPath,($auth|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $script:calls.Clear()
        Import-Module -Name $publishModule -Force
        $r=Invoke-ConfluencePlan -PlanPath $preview.planPath -CurrentValidation (New-LinkedValidation) -AuthorizationPath $authPath -JournalPath (Join-Path $script:fixture 'fresh-journal.json') -SyncPath (Join-Path $script:fixture 'fresh-sync.json') -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-LinkedHttp)
        $r.status | Should -Be 'no-op'
        @($script:calls|Where-Object {$_.method -in @('POST','PUT')}).Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-009/011/012; an existing mapped page gains a link to a new page in one reviewed operation.
    # Purpose: New identity is confirmed before the existing page PUT, then both final bodies read back and rerun no-op.
    It 'InterT95_updates_existing_page_only_after_new_link_identity_and_reads_back_both' {
        $f=New-LinkedPlan -WithExistingA
        $script:calls.Clear()
        $result=Invoke-LinkedPublish $f
        if($result.status -cne 'published'){$plan=Get-Content -LiteralPath $f.plan -Raw|ConvertFrom-Json;throw "Mixed linked publish $($result.status): $($result.reasonCodes -join ',') actions $(@($plan.pages.action) -join ',')"}
        $writes=@($script:calls|Where-Object {$_.method -in @('POST','PUT')})
        @($writes.method) | Should -Be @('POST','PUT','PUT')
        $writes[1].uri | Should -Match '/pages/201$'
        $script:pages['201'].storage | Should -Match 'pageId=202'
        $script:pages['201'].version | Should -Be 4
        $script:pages['202'].storage | Should -Match 'pageId=201'
        $script:pages['202'].version | Should -Be 2
        $script:calls.Clear()
        (Invoke-LinkedPublish $f).status | Should -Be 'no-op'
        @($script:calls|Where-Object {$_.method -in @('POST','PUT')}).Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-011; the new target page may exist but has no confirmed response identity.
    # Purpose: The already mapped page is never edited to an invented or uncertain target URL.
    It 'UnitT96_skips_existing_page_update_after_lost_new_link_target_create_response' {
        $f=New-LinkedPlan -WithExistingA
        $script:lostSecondCreate=$true;$script:calls.Clear()
        $result=Invoke-LinkedPublish $f
        if($result.status -cne 'uncertain'){$plan=Get-Content -LiteralPath $f.plan -Raw|ConvertFrom-Json;throw "Mixed linked uncertain $($result.status): $($result.reasonCodes -join ',') actions $(@($plan.pages.action) -join ',')"}
        $script:pages['201'].storage | Should -Be '<p>Old A</p>'
        $script:pages['201'].version | Should -Be 3
        @($script:calls|Where-Object method -eq 'PUT').Count | Should -Be 0
        $script:lostSecondCreate=$false;$script:calls.Clear()
        (Invoke-LinkedPublish $f).status | Should -Be 'uncertain'
        @($script:calls|Where-Object {$_.method -in @('POST','PUT')}).Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-010/012; the sync baseline is altered after final page readback.
    # Purpose: A rerun must reject a forged operation digest or page identity instead of claiming no-op.
    It 'UnitT97_blocks_tampered_linked_sync_baseline_before_no_op' {
        $f=New-LinkedPlan -WithExistingA
        (Invoke-LinkedPublish $f).status | Should -Be 'published'
        $original=Get-Content -LiteralPath $f.sync -Raw|ConvertFrom-Json -AsHashtable
        $tampered=$original.Clone();$tampered.planSha256=('0'*64)
        [IO.File]::WriteAllText($f.sync,($tampered|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        $script:calls.Clear()
        (Invoke-LinkedPublish $f).status | Should -Be 'blocked'
        @($script:calls|Where-Object {$_.method -in @('POST','PUT')}).Count | Should -Be 0
        $tampered=$original.Clone();$tampered.pages=@($original.pages|ForEach-Object {$_.Clone()});$tampered.pages[0].pageId='999'
        [IO.File]::WriteAllText($f.sync,($tampered|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        $script:calls.Clear()
        (Invoke-LinkedPublish $f).status | Should -Be 'blocked'
        @($script:calls|Where-Object {$_.method -in @('POST','PUT')}).Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-012; an unchanged mapped page with a managed attachment shares a linked operation.
    # Purpose: Sync must carry the exact read-back asset identity/version/hash even for a no-op page.
    It 'InterT98_records_no_op_attachment_evidence_in_linked_sync' {
        $f=New-LinkedPlan -WithExistingA -WithAsset
        $script:calls.Clear()
        (Invoke-LinkedPublish $f).status | Should -Be 'published'
        $writes=@($script:calls|Where-Object {$_.method -in @('POST','PUT')})
        @($writes.method) | Should -Be @('POST','PUT')
        $sync=Get-Content -LiteralPath $f.sync -Raw|ConvertFrom-Json
        $sync.pages[0].action | Should -Be 'no-op'
        @($sync.pages[0].assets).Count | Should -Be 1
        $sync.pages[0].assets[0].remoteAttachmentId | Should -Be '900'
        $sync.pages[0].assets[0].sha256 | Should -Be $script:assetSha
        $tampered=Get-Content -LiteralPath $f.sync -Raw|ConvertFrom-Json -AsHashtable
        $tampered.pages[0].assets[0].remoteAttachmentId='999'
        [IO.File]::WriteAllText($f.sync,($tampered|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        $script:calls.Clear()
        (Invoke-LinkedPublish $f).status | Should -Be 'blocked'
        @($script:calls|Where-Object {$_.method -in @('POST','PUT')}).Count | Should -Be 0
        $tampered.pages[0].assets[0].remoteAttachmentId='900'
        [IO.File]::WriteAllText($f.sync,($tampered|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        $script:calls.Clear()
        (Invoke-LinkedPublish $f).status | Should -Be 'no-op'
        @($script:calls|Where-Object {$_.method -in @('POST','PUT')}).Count | Should -Be 0
    }
}
