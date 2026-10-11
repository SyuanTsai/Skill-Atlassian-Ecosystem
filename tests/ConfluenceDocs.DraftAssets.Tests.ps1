# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $repositoryRoot=Split-Path -Parent $PSScriptRoot
    $scripts=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts'
    $site='https://example.atlassian.net';$cloud='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';$api="https://api.atlassian.com/ex/confluence/$cloud"
    function Get-DraftAssetValidation {
        [pscustomobject]@{status='valid';siteOrigin=$site;cloudId=$cloud;docsCommit=('a'*40);specCommit=('b'*40);codeCommit=('c'*40);
            sourceDigest=('d'*64);mappingDigest=('e'*64);reviewDigest=('f'*64);validatorVersion='1.13.0';rendererVersion='markdown-it@14.3.1';scenarioIds=@('SYP171-SCN-011','SYP171-SCN-012')}
    }
    function Get-DraftAssetHttp {
        {
            param($Request)
            $script:calls.Add($Request)
            $id=if($Request.Uri -match '/(?:pages|content)/(101|102)(?:/|\?|$)'){$Matches[1]}else{throw 'Unexpected Draft asset endpoint'}
            $remote=$script:remote[$id];$asset=$script:inputs[$id]
            if($Request.Uri -match '/attachments\?'){
                $rows=@(@{id='890';pageId=$id;title='unmanaged-old.png';version=@{number=4}})
                if($remote.uploaded){$rows+=@{id=$asset.attachmentId;pageId=$id;status='current';title=$asset.remoteFilename;mediaType='image/png';fileSize=$asset.bytes.Length;
                    comment=$remote.comment;version=@{number=$remote.assetVersion};downloadLink="/wiki/rest/api/content/$id/child/attachment/$($asset.attachmentId)/download"}}
                return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=$rows;_links=@{}}}
            }
            if($Request.Uri -match '/child/attachment/(901|902)/download\?version=[0-9]+$'){
                return [pscustomobject]@{StatusCode=200;Headers=@{};BodyBytes=$asset.bytes}
            }
            if($Request.Method -ceq 'POST' -and $Request.Uri -match '/child/attachment$'){
                $remote.postCount++
                if($script:mode -ceq 'upload-timeout-before' -or ($script:mode -ceq 'partial-upload-before' -and $id -ceq '102')){throw 'Synthetic timeout before upload'}
                if(-not([Text.Encoding]::UTF8.GetString($Request.BodyBytes)).Contains($asset.remoteFilename,[StringComparison]::Ordinal)){throw 'Wrong immutable filename'}
                $remote.uploaded=$true;$remote.comment=$Request.Comment
                if($script:mode -ceq 'upload-timeout-after'){throw 'Synthetic lost upload response'}
                return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=@(@{id=$asset.attachmentId})}}
            }
            if($Request.Method -ceq 'PUT'){
                $body=$Request.Body|ConvertFrom-Json -AsHashtable
                if($body.status -cne 'draft' -or $body.version.number -ne 1 -or -not $remote.uploaded){throw 'Draft body was written before verified attachment'}
                $remote.putCount++;$remote.draft=$body.body.value;$remote.message=$body.version.message
            }
            $draft=$Request.Method -ceq 'PUT' -or $Request.Uri -match 'status=draft'
            [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id=$id;spaceId='55';parentId='99';title="Synthetic Draft $id";
                status=$(if($draft){'draft'}else{'current'});version=@{number=$(if($draft){1}else{7});message=$(if($draft){$remote.message}else{''})};
                body=@{storage=@{value=$(if($draft){$remote.draft}else{$remote.current})}}}}
        }
    }
    function New-DraftAssetPlan {
        param([string]$Name='plan',[string[]]$Ids=@('101'))
        Import-Module (Join-Path $scripts 'ConfluencePlan.psm1') -Force
        $payloads=@($Ids|ForEach-Object {
            $asset=$script:inputs[$_]
            [pscustomobject]@{projectionId="req-$_";pageId=$_;spaceId='55';parentId='99';title="Synthetic Draft $_";bodyStorage=$asset.body;
                assetChanges=@(@{localPath="assets/$_.png";displayFilename="$_.png";mediaType='image/png';sha256=$asset.sha256})}
        })
        $preview=New-ConfluencePreviewPlan -PlanPath (Join-Path $script:fixtureRoot "$Name.json") -Validation (Get-DraftAssetValidation) -Payloads $payloads `
            -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (Get-DraftAssetHttp) -PublishMode draft -ValidationInputs @{root=$script:fixtureRoot}
        if($preview.status -cne 'preview'){throw "Draft attachment preview failed: $($preview.reasonCodes -join ',')"}
        $plan=Get-Content -LiteralPath $preview.planPath -Raw|ConvertFrom-Json -AsHashtable
        $actions=@(foreach($page in $plan.pages){
            if($page.action -cne 'no-op'){"draft-update:$($page.pageId)"}
            foreach($asset in @($page.assetChanges|Where-Object action -eq 'upload')){"draft-attachment-upload:$($page.pageId):$($asset.remoteFilename)"}
        })
        $auth=@{schemaVersion=3;publishMode='draft';attachmentStrategy='immutable-content-name';planSha256=$preview.planSha256;operationId=$plan.operationId;
            siteOrigin=$site;cloudId=$cloud;approvedActions=$actions;approvalEvidenceRef='synthetic-draft-asset-fixture-only'}
        $authPath=Join-Path $script:fixtureRoot "$Name.auth.json"
        [IO.File]::WriteAllText($authPath,($auth|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        [pscustomobject]@{plan=$preview.planPath;auth=$authPath;journal=(Join-Path $script:fixtureRoot "$Name.journal.json");sync=(Join-Path $script:fixtureRoot "$Name.sync.json")}
    }
    function Invoke-DraftAssetPlan {
        param($Fixture)
        Import-Module (Join-Path $scripts 'ConfluencePublish.psm1') -Force
        Invoke-ConfluencePlan -PlanPath $Fixture.plan -AuthorizationPath $Fixture.auth -CurrentValidation (Get-DraftAssetValidation) -JournalPath $Fixture.journal `
            -SyncPath $Fixture.sync -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (Get-DraftAssetHttp)
    }
}

Describe 'SYP-171 immutable Draft attachment closure' {
    BeforeEach {
        $script:fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('syp171-draft-assets-'+[Guid]::NewGuid().ToString('N'))
        $null=New-Item -ItemType Directory -Path (Join-Path $script:fixtureRoot 'assets') -Force
        $script:inputs=@{};$script:remote=@{};$script:mode='normal';$script:calls=[Collections.Generic.List[object]]::new()
        foreach($id in @('101','102')){
            $bytes=[byte[]]@([int]$id,255,13,10,42,128);$sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
            [IO.File]::WriteAllBytes((Join-Path $script:fixtureRoot "assets/$id.png"),$bytes)
            $filename="syp171-req-$id-$sha.png"
            $script:inputs[$id]=@{bytes=$bytes;sha256=$sha;remoteFilename=$filename;attachmentId=$(if($id -ceq '101'){'901'}else{'902'});
                body="<p>Candidate $id</p><ac:image><ri:attachment ri:filename=`"$filename`" /></ac:image>"}
            $script:remote[$id]=@{current='<p>Published</p><ac:image><ri:attachment ri:filename="unmanaged-old.png" /></ac:image>';draft='<p>Previous Draft</p>';
                uploaded=$false;comment='';assetVersion=1;postCount=0;putCount=0;message='';oldAttachmentHash=('9'*64)}
        }
    }
    AfterEach {
        $resolved=[IO.Path]::GetFullPath($script:fixtureRoot)
        if([IO.Path]::GetDirectoryName($resolved).TrimEnd('\','/') -cne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') -or
            [IO.Path]::GetFileName($resolved) -cnotmatch '^syp171-draft-assets-[a-f0-9]{32}$'){throw 'Unexpected Draft asset fixture path'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }

    # Scenario: SYP171-SCN-007/012; approved existing-page Draft references a new immutable asset.
    # Purpose: Upload and exact binary readback precede Draft, preserve current/old assets, and confirm versioned sync.
    It 'InterT10_uploads_and_confirms_assets_before_Draft_then_reruns_without_writes' {
        $before=$script:remote['101'].current;$f=New-DraftAssetPlan
        $plan=Get-Content -LiteralPath $f.plan -Raw|ConvertFrom-Json
        $plan.schemaVersion|Should -Be 4
        $plan.attachmentStrategy|Should -Be 'immutable-content-name'
        (Invoke-DraftAssetPlan $f).status|Should -Be 'drafted'
        $script:remote['101'].postCount|Should -Be 1
        $script:remote['101'].putCount|Should -Be 1
        $script:remote['101'].current|Should -Be $before
        $script:remote['101'].oldAttachmentHash|Should -Be ('9'*64)
        $sync=Get-Content -LiteralPath $f.sync -Raw|ConvertFrom-Json
        $sync.schemaVersion|Should -Be 5
        $sync.pages[0].assets[0].remoteAttachmentId|Should -Be '901'
        $sync.pages[0].assets[0].remoteVersion|Should -Be 1
        $script:calls.Clear();(Invoke-DraftAssetPlan $f).status|Should -Be 'no-op'
        @($script:calls|Where-Object Method -ne 'GET').Count|Should -Be 0
    }

    # Scenario: SYP171-SCN-012; a fresh preview sees an already confirmed Draft and immutable attachment.
    # Purpose: No-op requires the observed ID/version/bytes, including reused attachment evidence in sync.
    It 'InterT20_confirms_fresh_Draft_asset_no_op_without_mutation' {
        $f=New-DraftAssetPlan;(Invoke-DraftAssetPlan $f).status|Should -Be 'drafted'
        $fresh=New-DraftAssetPlan -Name fresh;$script:calls.Clear()
        (Invoke-DraftAssetPlan $fresh).status|Should -Be 'no-op'
        Test-Json -Json (Get-Content -LiteralPath $fresh.plan -Raw) -SchemaFile (Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/references/publish-plan.schema.json')|Should -BeTrue
        @($script:calls|Where-Object Method -ne 'GET').Count|Should -Be 0
        (Get-Content -LiteralPath $fresh.sync -Raw|ConvertFrom-Json).pages[0].assets[0].remoteAttachmentId|Should -Be '901'
    }

    # Scenario: SYP171-SCN-007; a candidate tries to reuse another content hash's managed filename.
    # Purpose: The immutable name must identify this projection, media type and exact approved bytes.
    It 'UnitT25_rejects_a_managed_filename_that_does_not_identify_its_bytes' {
        $f=New-DraftAssetPlan;$plan=Get-Content -LiteralPath $f.plan -Raw|ConvertFrom-Json -AsHashtable
        $plan.pages[0].assetChanges[0].remoteFilename="syp171-req-101-$('0'*64).png"
        Import-Module (Join-Path $scripts 'ConfluencePlan.psm1') -Force
        Test-ConfluencePlanShape -Plan $plan|Should -BeFalse
    }

    # Scenario: SYP171-SCN-007; the reviewed body action is approved but its upload action is omitted.
    # Purpose: Draft approval cannot authorize an undeclared attachment side effect.
    It 'UnitT30_rejects_missing_attachment_approval_before_remote_IO' {
        $f=New-DraftAssetPlan;$auth=Get-Content -LiteralPath $f.auth -Raw|ConvertFrom-Json -AsHashtable
        $auth.approvedActions=@('draft-update:101');[IO.File]::WriteAllText($f.auth,($auth|ConvertTo-Json -Depth 8))
        $script:calls.Clear();(Invoke-DraftAssetPlan $f).reasonCodes|Should -Contain 'AuthorizationMismatch'
        $script:calls.Count|Should -Be 0
    }

    # Scenario: SYP171-SCN-011; an upload reaches the server but its response is lost.
    # Purpose: The original operation resumes from comment/ID/version/binary proof without resending POST.
    It 'InterT40_reconciles_a_lost_upload_response_without_another_POST' {
        $f=New-DraftAssetPlan;$script:mode='upload-timeout-after'
        (Invoke-DraftAssetPlan $f).status|Should -Be 'uncertain'
        Test-Path -LiteralPath $f.sync|Should -BeFalse
        Test-Json -Json (Get-Content -LiteralPath $f.journal -Raw) -SchemaFile (Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/references/operation-journal.schema.json')|Should -BeTrue
        $script:mode='normal';$script:calls.Clear()
        (Invoke-DraftAssetPlan $f).status|Should -Be 'drafted'
        @($script:calls|Where-Object Method -eq 'POST').Count|Should -Be 0
    }

    # Scenario: SYP171-SCN-011; the upload request has no attributable result on the server.
    # Purpose: Re-running an uncertain operation cannot blindly create another attachment or advance sync.
    It 'UnitT50_keeps_an_unproved_upload_uncertain_without_resending' {
        $f=New-DraftAssetPlan;$script:mode='upload-timeout-before'
        (Invoke-DraftAssetPlan $f).status|Should -Be 'uncertain'
        $script:mode='normal';$script:calls.Clear()
        (Invoke-DraftAssetPlan $f).status|Should -Be 'uncertain'
        @($script:calls|Where-Object Method -ne 'GET').Count|Should -Be 0
        Test-Path -LiteralPath $f.sync|Should -BeFalse
    }

    # Scenario: SYP171-SCN-010; current references a currently absent filename using an equivalent namespace alias.
    # Purpose: A Draft upload cannot make a broken published image start rendering without a current-page update.
    It 'UnitT60_blocks_an_upload_that_would_change_a_current_attachment_reference' {
        $name=$script:inputs['101'].remoteFilename
        $script:remote['101'].current="<ac:image><x:attachment xmlns:x=`"http://atlassian.com/resource/identifier`" x:filename=`"$name`" /></ac:image>"
        {New-DraftAssetPlan}|Should -Throw '*DraftAttachmentAffectsCurrent*'
        @($script:calls|Where-Object Method -ne 'GET').Count|Should -Be 0
    }

    # Scenario: SYP171-SCN-010; current references the new filename through a same-page download URL.
    # Purpose: URL-based image and download references cannot bypass the shared-attachment impact check.
    It 'UnitT62_blocks_a_same_page_current_attachment_URL_<Kind>' -ForEach @(@{Kind='image'},@{Kind='link'}) {
        $name=$script:inputs['101'].remoteFilename.Replace('-','%2D')
        $url="$site/wiki/download/attachments/101/${name}?version=1"
        $script:remote['101'].current=if($Kind -ceq 'image'){"<ac:image><ri:url ri:value=`"$url`" /></ac:image>"}else{"<p><a href=`"$url`">Attachment</a></p>"}
        {New-DraftAssetPlan}|Should -Throw '*DraftAttachmentAffectsCurrent*'
        @($script:calls|Where-Object Method -ne 'GET').Count|Should -Be 0
    }

    # Scenario: SYP171-SCN-010; an external host uses the same page number and attachment basename.
    # Purpose: An unrelated external URL does not imply that a selected-site upload changes current rendering.
    It 'UnitT63_allows_an_unrelated_external_attachment_URL' {
        $name=$script:inputs['101'].remoteFilename
        $script:remote['101'].current="<p><a href=`"https://example.org/wiki/download/attachments/101/$name`">External attachment</a></p>"
        $f=New-DraftAssetPlan
        (Get-Content -LiteralPath $f.plan -Raw|ConvertFrom-Json).schemaVersion|Should -Be 4
        @($script:calls|Where-Object Method -ne 'GET').Count|Should -Be 0
    }

    # Scenario: SYP171-SCN-010; current storage is malformed and its attachment effects cannot be inspected.
    # Purpose: Missing current-reference proof cannot be treated as a safe empty attachment inventory.
    It 'UnitT65_blocks_unparseable_current_attachment_references' {
        $script:remote['101'].current='<p>Unclosed'
        {New-DraftAssetPlan}|Should -Throw '*PublishedAttachmentReferencesUnverified*'
    }

    # Scenario: SYP171-SCN-011/012; the second page's upload is unproved after the first page was confirmed.
    # Purpose: The whole batch retains partial evidence, verifies prior pages, and never records partial sync as success.
    It 'InterT70_preserves_partial_batch_progress_without_advancing_sync' {
        $f=New-DraftAssetPlan -Ids @('101','102');$script:mode='partial-upload-before'
        (Invoke-DraftAssetPlan $f).status|Should -Be 'uncertain'
        $script:remote['101'].draft|Should -Be $script:inputs['101'].body
        $script:remote['102'].draft|Should -Be '<p>Previous Draft</p>'
        Test-Path -LiteralPath $f.sync|Should -BeFalse
        $script:mode='normal';$script:calls.Clear()
        (Invoke-DraftAssetPlan $f).status|Should -Be 'uncertain'
        @($script:calls|Where-Object Method -ne 'GET').Count|Should -Be 0
        $journal=Get-Content -LiteralPath $f.journal -Raw|ConvertFrom-Json
        $journal.pages[0].stage|Should -Be 'confirmed'
        $journal.pages[1].assets[0].stage|Should -Be 'write-sent'
    }

    # Scenario: SYP171-SCN-010/012; a confirmed filename is updated externally to another attachment version.
    # Purpose: Identical bytes cannot hide metadata/version drift or authorize another write.
    It 'UnitT80_blocks_confirmed_attachment_version_drift_before_any_write' {
        $f=New-DraftAssetPlan;(Invoke-DraftAssetPlan $f).status|Should -Be 'drafted'
        $script:remote['101'].assetVersion++;$script:calls.Clear()
        (Invoke-DraftAssetPlan $f).reasonCodes|Should -Contain 'ConfirmedAttachmentDrift'
        @($script:calls|Where-Object Method -ne 'GET').Count|Should -Be 0
    }

    # Scenario: SYP171-SCN-011; a local journal claims a new immutable upload was confirmed at version two.
    # Purpose: A forged local baseline cannot turn an overwrite into a valid Draft upload or trigger remote IO.
    It 'UnitT85_rejects_an_upload_journal_that_claims_a_replacement_version' {
        $f=New-DraftAssetPlan;(Invoke-DraftAssetPlan $f).status|Should -Be 'drafted'
        $journal=Get-Content -LiteralPath $f.journal -Raw|ConvertFrom-Json -AsHashtable
        $journal.pages[0].assets[0].remoteVersion=2
        [IO.File]::WriteAllText($f.journal,($journal|ConvertTo-Json -Depth 12));$script:calls.Clear()
        (Invoke-DraftAssetPlan $f).reasonCodes|Should -Contain 'JournalPlanMismatch'
        $script:calls.Count|Should -Be 0
    }

    # Scenario: SYP171-SCN-007; staged binary bytes change after immutable approval.
    # Purpose: The executor checks attachment payloads before remote preflight and cannot upload replacement bytes.
    It 'UnitT90_rejects_changed_staged_attachment_bytes_before_remote_IO' {
        $f=New-DraftAssetPlan;$plan=Get-Content -LiteralPath $f.plan -Raw|ConvertFrom-Json
        [IO.File]::WriteAllBytes((Join-Path $script:fixtureRoot $plan.pages[0].assetChanges[0].payloadPath),[byte[]]@(42))
        $script:calls.Clear();(Invoke-DraftAssetPlan $f).reasonCodes|Should -Contain 'PayloadChanged'
        $script:calls.Count|Should -Be 0
    }

    # Scenario: SYP171-SCN-007/012; attachment Draft artifacts cross the public JSON Schema boundary.
    # Purpose: Consumers receive valid versioned plan, authorization, intent and confirmed sync contracts.
    It 'InterT92_emits_artifacts_that_validate_against_public_Draft_asset_schemas' {
        $f=New-DraftAssetPlan;(Invoke-DraftAssetPlan $f).status|Should -Be 'drafted'
        foreach($pair in @(@($f.plan,'publish-plan'),@($f.auth,'authorization'),@($f.journal,'operation-journal'),@($f.sync,'sync-state'))){
            Test-Json -Json (Get-Content -LiteralPath $pair[0] -Raw) -SchemaFile (Join-Path $repositoryRoot "skills/manage-confluence-docs-as-code/references/$($pair[1]).schema.json")|Should -BeTrue
        }
    }

    # Scenario: SYP171-SCN-012; the recorded sync attachment ID differs from its confirmed journal.
    # Purpose: Sync evidence cannot redefine the accepted attachment or produce a forged no-op result.
    It 'UnitT95_rejects_a_changed_sync_attachment_identity' {
        $f=New-DraftAssetPlan;(Invoke-DraftAssetPlan $f).status|Should -Be 'drafted'
        $sync=Get-Content -LiteralPath $f.sync -Raw|ConvertFrom-Json -AsHashtable
        $sync.pages[0].assets[0].remoteAttachmentId='999'
        [IO.File]::WriteAllText($f.sync,($sync|ConvertTo-Json -Depth 12));$script:calls.Clear()
        (Invoke-DraftAssetPlan $f).reasonCodes|Should -Contain 'SyncJournalMismatch'
        $script:calls.Count|Should -Be 0
    }
}
