# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference='Stop'
    $repositoryRoot=Split-Path -Parent $PSScriptRoot
    $workflowPath=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceMarkdownWorkflow.psm1'
    Import-Module (Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluencePlan.psm1') -Force
    $site='https://example.atlassian.net'
    $cloud='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'

    function New-MarkdownPreviewFixture {
        param([switch]$MappingIdent)
        $root=Join-Path ([IO.Path]::GetTempPath()) ('syp171-markdown-preview-'+[Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'docs') -Force | Out-Null
        [IO.File]::Copy((Join-Path $repositoryRoot '.gitattributes'),(Join-Path $root '.gitattributes'),$true)
        [IO.File]::WriteAllText((Join-Path $root 'docs/general.md'),"# Overview`n`nOrdinary **Markdown**.",[Text.UTF8Encoding]::new($false))
        $mapping=[ordered]@{
            schemaVersion=4;adapter=@{id='powershell-markdown';version='1'};siteOrigin=$site;cloudId=$cloud;sourceMode='git-markdown'
            entries=@(@{projectionId='general-doc';sourceArtifact='docs/general.md';sourceSectionId='document';pageId='101';spaceId='55';parentId='99';parentProjectionId='';title=$(if($MappingIdent){'General $Id$'}else{'General'});assets=@();linkBindings=@();contentKind='general'})
        }
        [IO.File]::WriteAllText((Join-Path $root 'mapping.json'),($mapping|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        if($MappingIdent){
            $attributesPath=Join-Path $root '.gitattributes'
            $attributes=[IO.File]::ReadAllText($attributesPath,[Text.UTF8Encoding]::new($false,$true))
            [IO.File]::WriteAllText($attributesPath,($attributes+"`n/mapping.json ident`n"),[Text.UTF8Encoding]::new($false))
        }
        & git -C $root init --quiet | Out-Null
        & git -C $root config user.name 'SYP-171 Markdown preview fixture' | Out-Null
        & git -C $root config user.email 'fixture@example.invalid' | Out-Null
        & git -C $root config core.autocrlf false | Out-Null
        & git -C $root add -- .gitattributes docs/general.md mapping.json | Out-Null
        & git -C $root commit --quiet -m 'Fixture plain Markdown preview' | Out-Null
        $commit=(& git -C $root rev-parse HEAD).Trim()
        return [pscustomobject]@{root=$root;mappingPath=(Join-Path $root 'mapping.json');commit=$commit;planPath=(Join-Path $root 'preview.json');reviewPath=''}
    }
    function Remove-MarkdownPreviewFixture {
        param([Parameter(Mandatory)][string]$Root)
        $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
        $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
        if([IO.Path]::GetDirectoryName($resolved).TrimEnd('\','/') -cne $parent -or
            [IO.Path]::GetFileName($resolved) -cnotmatch '^syp171-markdown-preview-[a-f0-9]{32}$'){throw 'Unsafe Markdown preview fixture cleanup target.'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    function Add-MarkdownPreviewIdentAsset {
        $assetPath=Join-Path $script:fixture.root 'docs/assets/diagram.png'
        New-Item -ItemType Directory -Path (Split-Path -Parent $assetPath) -Force|Out-Null
        $committedAssetText='fixture image $Id$ bytes'
        [IO.File]::WriteAllBytes($assetPath,[Text.Encoding]::ASCII.GetBytes($committedAssetText))
        $attributesPath=Join-Path $script:fixture.root '.gitattributes'
        $attributes=[IO.File]::ReadAllText($attributesPath,[Text.UTF8Encoding]::new($false,$true))
        [IO.File]::WriteAllText($attributesPath,($attributes+"`n/docs/assets/diagram.png ident`n"),[Text.UTF8Encoding]::new($false))
        & git -C $script:fixture.root add -- .gitattributes docs/assets/diagram.png|Out-Null
        $assetBlob=(& git -C $script:fixture.root rev-parse ':docs/assets/diagram.png').Trim()
        if($LASTEXITCODE -ne 0 -or $assetBlob -cnotmatch '^[a-f0-9]{40}$'){throw 'Unable to identify the committed ident asset fixture.'}
        $workingAssetText=$committedAssetText.Replace('$Id$','$Id: '+$assetBlob+' $')
        [IO.File]::WriteAllBytes($assetPath,[Text.Encoding]::ASCII.GetBytes($workingAssetText))
        $assetBytes=[IO.File]::ReadAllBytes($assetPath)
        $assetHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($assetBytes)).ToLowerInvariant()
        [IO.File]::WriteAllText((Join-Path $script:fixture.root 'docs/general.md'),"# Overview`n`nOrdinary **Markdown**.`n`n![diagram](assets/diagram.png)",[Text.UTF8Encoding]::new($false))
        $mapping=Get-Content -LiteralPath $script:fixture.mappingPath -Raw|ConvertFrom-Json -AsHashtable
        $mapping.entries[0].assets=@(@{localPath='docs/assets/diagram.png';displayFilename='diagram.png';mediaType='image/png';sha256=$assetHash})
        [IO.File]::WriteAllText($script:fixture.mappingPath,($mapping|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        & git -C $script:fixture.root add -- .gitattributes docs/general.md docs/assets/diagram.png mapping.json|Out-Null
        & git -C $script:fixture.root commit --quiet -m 'Fixture ident-normalized managed asset'
        if($LASTEXITCODE -ne 0){throw 'Unable to commit the ident asset fixture.'}
        $script:fixture.commit=(& git -C $script:fixture.root rev-parse HEAD).Trim()
        & git -C $script:fixture.root diff --quiet $script:fixture.commit -- docs/assets/diagram.png
        if($LASTEXITCODE -ne 0){throw 'Git ident asset fixture is not clean under the effective filter.'}
    }
    function Add-MarkdownPreviewCapture {
        param([ValidateSet('valid','destination-mismatch','stale-destination','unknown')][string]$Case='valid',[switch]$LargeAsset,[switch]$NormalizeRawCapture)
        Import-Module (Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/StorageProjection.psm1') -Force
        $captureRoot=Join-Path $script:fixture.root '.confluence/captures/fixture'
        $rawDirectory=Join-Path $captureRoot 'pages/101'
        $assetDirectory=Join-Path $captureRoot 'assets'
        $docsAssetDirectory=Join-Path $script:fixture.root 'docs/assets'
        New-Item -ItemType Directory -Path $rawDirectory,$assetDirectory,$docsAssetDirectory -Force|Out-Null
        $rawBytes=[IO.File]::ReadAllBytes((Join-Path $repositoryRoot 'tests/fixtures/syp171-import/mixed-storage.xml'))
        $storage=[Text.UTF8Encoding]::new($false,$true).GetString($rawBytes)
        $projection=ConvertFrom-ConfluenceStorage -Storage $storage -PageId '101' -PageVersion 3
        [IO.File]::WriteAllBytes((Join-Path $rawDirectory 'storage.xml'),$rawBytes)
        [IO.File]::WriteAllText((Join-Path $rawDirectory 'candidate.md'),[string]$projection.markdown,[Text.UTF8Encoding]::new($false))
        if($LargeAsset){
            $assetBytes=[byte[]]::new(5MB)
            [Array]::Fill[byte]($assetBytes,42)
            [byte[]]$pngHeader=@(137,80,78,71,13,10,26,10)
            [Array]::Copy($pngHeader,$assetBytes,$pngHeader.Length)
        }else{$assetBytes=[byte[]]@(137,80,78,71,13,10,26,10,1,2,3)}
        $assetHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($assetBytes)).ToLowerInvariant()
        [IO.File]::WriteAllBytes((Join-Path $assetDirectory 'diagram.png'),$assetBytes)
        [IO.File]::WriteAllBytes((Join-Path $docsAssetDirectory 'diagram.png'),$assetBytes)
        $markdown=[string]$projection.markdown+"`n`n![diagram](assets/diagram.png)`n"
        [IO.File]::WriteAllText((Join-Path $script:fixture.root 'docs/general.md'),$markdown,[Text.UTF8Encoding]::new($false))
        $markdownBytes=[IO.File]::ReadAllBytes((Join-Path $script:fixture.root 'docs/general.md'))
        $markdownHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($markdownBytes)).ToLowerInvariant()
        $destinationPath=if($Case -ceq 'destination-mismatch'){'docs/other.md'}else{'docs/general.md'}
        $reviewHash=if($Case -ceq 'stale-destination'){'f'*64}else{$markdownHash}
        $capture=[ordered]@{
            schemaVersion=1;captureId='preview-capture';capturedAtUtc='2026-10-12T00:00:00Z'
            siteOrigin=$site;cloudId=$cloud;scope=@{kind='page';pageIds=@('101')};status='complete';reasonCodes=@();incompletePageIds=@()
            pages=@(@{pageId='101';spaceId='55';parentId='99';title='Captured source';version=3
                bodySha256=$projection.bodySha256;draftObservation='same-as-published';snapshotPath='pages/101/storage.xml';candidatePath='pages/101/candidate.md'
                projectionStatus=$projection.status;sourceBlocks=@($projection.sourceBlocks);unsupported=@($projection.unsupported|ForEach-Object {@{code=$_.code;location=$_.location;sourceSha256=$_.sourceSha256}})
                attachments=@(@{attachmentId='501';version=2;filename='diagram.png';mediaType='image/png';byteLength=$assetBytes.Length;sha256=$assetHash;assetPath='assets/diagram.png'})})
        }
        $capturePath=Join-Path $captureRoot 'capture.json'
        $captureJson=$capture|ConvertTo-Json -Depth 16
        if($NormalizeRawCapture){$captureJson=[regex]::Replace($captureJson,"\r?\n","`r`n")}
        [IO.File]::WriteAllText($capturePath,$captureJson,[Text.UTF8Encoding]::new($false))
        $dispositions=[System.Collections.Generic.List[object]]::new()
        for($index=0;$index -lt @($projection.sourceBlocks).Count;$index++){
            $block=$projection.sourceBlocks[$index]
            $isUnknown=$Case -ceq 'unknown' -and $index -eq 0
            $destinations=[System.Collections.Generic.List[object]]::new()
            if(-not $isUnknown){$destinations.Add(@{sourceArtifact=$destinationPath;sourceSectionId='document';contentSha256=$reviewHash})}
            $dispositions.Add(@{blockId=$block.id;sourceSha256=$block.sourceSha256;location=$block.location
                status=$(if($isUnknown){'unknown'}else{'accepted'});ready=(-not $isUnknown)
                destinations=$destinations.ToArray()
                reason=$(if($isUnknown){'Outcome needs review'}else{'Accepted captured content'})})
        }
        $importReview=[ordered]@{schemaVersion=2;captureId='preview-capture';siteOrigin=$site;dispositions=@($dispositions.ToArray())
            attachments=@(@{pageId='101';attachmentId='501';version=2;sha256=$assetHash;status='supported';ready=$true
                destination=@{localPath='docs/assets/diagram.png';displayFilename='diagram.png';mediaType='image/png';byteLength=$assetBytes.Length;contentSha256=$assetHash}
                reason='Supported image attachment is mapped'})}
        $importReviewPath=Join-Path $captureRoot 'import-review.json'
        [IO.File]::WriteAllText($importReviewPath,($importReview|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
        $dossierPath=Join-Path $script:fixture.root '.confluence/review-dossier.json'
        [IO.File]::WriteAllText($dossierPath,(@{schemaVersion=2;capturePath='.confluence/captures/fixture/capture.json';importReviewPath='.confluence/captures/fixture/import-review.json'}|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
        $mapping=Get-Content -LiteralPath $script:fixture.mappingPath -Raw|ConvertFrom-Json -AsHashtable
        $mapping.sourceMode='capture-markdown'
        $mapping.entries[0].assets=@(@{localPath='docs/assets/diagram.png';displayFilename='diagram.png';mediaType='image/png';sha256=$assetHash})
        [IO.File]::WriteAllText($script:fixture.mappingPath,($mapping|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        if($NormalizeRawCapture){
            & git -C $script:fixture.root config core.autocrlf true
            $attributesPath=Join-Path $script:fixture.root '.gitattributes'
            $attributes=[IO.File]::ReadAllText($attributesPath,[Text.UTF8Encoding]::new($false,$true))
            [IO.File]::WriteAllText($attributesPath,($attributes+"`n/.confluence/captures/fixture/capture.json text eol=lf`n"),[Text.UTF8Encoding]::new($false))
            & git -C $script:fixture.root add -- .gitattributes
        }
        & git -C $script:fixture.root add -- docs/general.md docs/assets mapping.json
        & git -C $script:fixture.root add -f -- .confluence
        & git -C $script:fixture.root commit --quiet -m 'Fixture reviewed capture and Markdown destination'
        $script:fixture.commit=(& git -C $script:fixture.root rev-parse HEAD).Trim()
        $script:fixture.reviewPath=$dossierPath
    }
    function New-MarkdownPreviewHttp {
        return {
            param($Request)
            $script:requests.Add([pscustomobject]@{Method=[string]$Request.Method;Uri=[string]$Request.Uri})
            if([string]$Request.Uri -match '/pages/[0-9]+/attachments\?limit=50$'){
                return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=@();_links=@{}}}
            }
            $isDraft=([string]$Request.Uri).Contains('status=draft',[StringComparison]::Ordinal)
            $storage=if($isDraft){'<p>Draft baseline</p>'}else{'<p>Published baseline</p>'}
            $status=if($isDraft){'draft'}else{'current'}
            $version=if($isDraft){1}else{7}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id='101';spaceId='55';parentId='99';title='General';status=$status;version=@{number=$version};body=@{storage=@{value=$storage}}}}
        }
    }
    function Test-MarkdownPreviewPlanShape {
        param([object]$Plan)
        Import-Module (Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluencePlan.psm1') -Force
        return Test-ConfluencePlanShape -Plan $Plan
    }
    function Invoke-MarkdownPreview {
        param([string]$Mode='current')
        Import-Module -Name $workflowPath -Force
        $previewArgs=@{
            Root=$script:fixture.root;MappingPath=$script:fixture.mappingPath;DocsCommit=$script:fixture.commit
            PlanPath=$script:fixture.planPath;ExpectedSiteOrigin=$site
            ApiBase="https://api.atlassian.com/ex/confluence/$cloud";HttpInvoker=(New-MarkdownPreviewHttp);PublishMode=$Mode
        }
        if($script:fixture.reviewPath){$previewArgs.ReviewPath=$script:fixture.reviewPath}
        $result=New-ConfluenceMarkdownPreviewPlan @previewArgs
        return $result
    }
}

Describe 'SYP-171 Markdown preview integration' {
    BeforeEach{$script:fixture=New-MarkdownPreviewFixture;$script:requests=[System.Collections.Generic.List[object]]::new()}
    AfterEach{if($null -ne $script:fixture){Remove-MarkdownPreviewFixture -Root $script:fixture.root;$script:fixture=$null}}

    # Scenario: A committed general Markdown page enters the same immutable preview contract as the normal Push preview.
    # Purpose: Projection, tenant reads, plan construction, and zero remote writes all use the shared Markdown workflow.
    It 'InterT10_builds_a_current_preview_without_runtime_code_evidence_or_remote_writes' {
        $r=Invoke-MarkdownPreview
        $r.status | Should -Be 'preview'
        $r.validation.status | Should -Be 'valid'
        $plan=Get-Content -LiteralPath $script:fixture.planPath -Raw|ConvertFrom-Json -AsHashtable
        $plan.schemaVersion | Should -Be 5
        $plan.publishMode | Should -Be 'current'
        $plan.sourceMode | Should -Be 'git-markdown'
        $plan.codeCommit | Should -Be ''
        $plan.Contains('specCommit') | Should -Be $false
        (Test-MarkdownPreviewPlanShape -Plan $plan) | Should -BeTrue
        $plan.pages[0].action | Should -Be 'update'
        $body=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes((Join-Path (Split-Path -Parent $script:fixture.planPath) $plan.pages[0].payloadPath)))
        $body | Should -BeExactly '<h1 id="overview">Overview</h1><p>Ordinary <strong>Markdown</strong>.</p>'
        @($script:requests|Where-Object Method -cne 'GET').Count | Should -Be 0
    }

    # Scenario: An existing-page draft preview receives mixed-case mode input.
    # Purpose: Mode normalization preserves explicit draft conflict and authorization semantics.
    It 'InterT20_normalizes_mixed_case_draft_preview_mode' {
        $r=Invoke-MarkdownPreview -Mode 'Draft'
        $r.status | Should -Be 'preview'
        $plan=Get-Content -LiteralPath $script:fixture.planPath -Raw|ConvertFrom-Json -AsHashtable
        $plan.publishMode | Should -Be 'draft'
        (Test-MarkdownPreviewPlanShape -Plan $plan) | Should -BeTrue
        @($script:requests|Where-Object Method -cne 'GET').Count | Should -Be 0
    }

    # Scenario: Windows autocrlf presents the selected Git blob with CRLF working bytes.
    # Purpose: Validation binds normalized source identity while the payload and mapping digest use exact commit blob bytes.
    It 'InterT30_accepts_autocrlf_working_files_and_hashes_the_mapping_commit_blob' {
        & git -C $script:fixture.root config core.autocrlf true
        foreach($relative in @('docs/general.md','mapping.json')){
            $path=Join-Path $script:fixture.root $relative
            $text=[IO.File]::ReadAllText($path,[Text.UTF8Encoding]::new($false,$true))
            $lf=[regex]::Replace($text,"\r?\n","`n")
            [IO.File]::WriteAllText($path,$lf.Replace("`n","`r`n"),[Text.UTF8Encoding]::new($false))
        }

        $r=Invoke-MarkdownPreview

        $r.status | Should -Be 'preview'
        $r.validation.status | Should -Be 'valid'
        Import-Module -Name (Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceMapping.psm1') -Force
        $mappingBlob=Get-ConfluenceCommittedBlob -Root $script:fixture.root -Commit $script:fixture.commit -Path 'mapping.json'
        $expectedDigest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$mappingBlob.bytes)).ToLowerInvariant()
        $r.validation.mappingDigest | Should -BeExactly $expectedDigest
        $plan=Get-Content -LiteralPath $script:fixture.planPath -Raw|ConvertFrom-Json -AsHashtable
        $body=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes((Join-Path (Split-Path -Parent $script:fixture.planPath) $plan.pages[0].payloadPath)))
        $body | Should -BeExactly '<h1 id="overview">Overview</h1><p>Ordinary <strong>Markdown</strong>.</p>'
    }

    # Scenario: Git's built-in ident expansion leaves mapping bytes different while Git's effective diff remains clean.
    # Purpose: Mapping routes and content kinds must come from the selected committed JSON; only line-ending normalization is tolerated.
    It 'InterT35_rejects_clean_filter_mapping_semantic_changes_before_remote_reads' {
        Remove-MarkdownPreviewFixture -Root $script:fixture.root
        $script:fixture=New-MarkdownPreviewFixture -MappingIdent
        $mapping=Get-Content -LiteralPath $script:fixture.mappingPath -Raw|ConvertFrom-Json -AsHashtable
        $mappingBlob=(& git -C $script:fixture.root rev-parse "$($script:fixture.commit):mapping.json").Trim()
        $mapping.entries[0].title='General $Id: '+$mappingBlob+' $'
        [IO.File]::WriteAllText($script:fixture.mappingPath,($mapping|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        & git -C $script:fixture.root diff --quiet $script:fixture.commit -- mapping.json 2>$null
        $LASTEXITCODE | Should -Be 0

        $result=Invoke-MarkdownPreview

        $result.status | Should -Be 'blocked'
        @($result.reasonCodes) | Should -Contain 'MappingCommitMismatch'
        $script:requests.Count | Should -Be 0
    }

    # Scenario: Git's ident filter leaves a mapped attachment's worktree bytes different from its committed blob.
    # Purpose: Attachment payloads must use exact committed bytes even when Git's effective diff reports a clean file.
    It 'InterT36_rejects_git_normalized_managed_asset_before_remote_reads' {
        Add-MarkdownPreviewIdentAsset

        $result=Invoke-MarkdownPreview

        $result.status | Should -Be 'blocked'
        @($result.reasonCodes) | Should -Contain 'AttachmentDestinationChanged'
        $script:requests.Count | Should -Be 0
    }

    # Scenario: A captured page, its reviewed Markdown destination, and a supported attachment are all in the selected docs commit.
    # Purpose: Import review and exact destination byte hashes must pass before the ordinary immutable preview contract.
    It 'InterT40_previews_capture_after_page_version_block_and_attachment_review' {
        Add-MarkdownPreviewCapture
        $result=Invoke-MarkdownPreview
        $result.status | Should -Be 'preview'
        $result.validation.status | Should -Be 'valid'
        $result.validation.sourceMode | Should -Be 'capture-markdown'
        $plan=Get-Content -LiteralPath $script:fixture.planPath -Raw|ConvertFrom-Json -AsHashtable
        (Test-MarkdownPreviewPlanShape -Plan $plan) | Should -BeTrue
        @($plan.pages[0].assetChanges).Count | Should -Be 1
        @($script:requests|Where-Object Method -cne 'GET').Count | Should -Be 0
    }

    # Scenario: A reviewed capture contains a 5 MiB attachment that remains under the 20 MiB asset limit.
    # Purpose: Capture asset validation must use its bounded attachment allowance while Markdown and mapping stay at 4 MiB.
    It 'InterT45_previews_capture_with_a_committed_asset_above_four_mib' {
        Add-MarkdownPreviewCapture -LargeAsset
        $result=Invoke-MarkdownPreview
        $result.status | Should -Be 'preview'
        $result.validation.status | Should -Be 'valid'
        $result.validation.sourceMode | Should -Be 'capture-markdown'
        $plan=Get-Content -LiteralPath $script:fixture.planPath -Raw|ConvertFrom-Json -AsHashtable
        $planAsset=$plan.pages[0].assetChanges[0]
        $planAsset.byteLength | Should -Be 5MB
        $planAsset.sha256 | Should -BeExactly (Get-FileHash -LiteralPath (Join-Path $script:fixture.root 'docs/assets/diagram.png') -Algorithm SHA256).Hash.ToLowerInvariant()
        @($script:requests|Where-Object Method -cne 'GET').Count | Should -Be 0
    }

    # Scenario: Git normalizes captured JSON after capture and its working bytes no longer equal the recorded blob.
    # Purpose: Capture metadata is hash-bound evidence and must not silently normalize through autocrlf.
    It 'InterT47_rejects_git_normalized_raw_capture_metadata' {
        Add-MarkdownPreviewCapture -NormalizeRawCapture
        $result=Invoke-MarkdownPreview
        $result.status | Should -Be 'blocked'
        @($result.reasonCodes) | Should -Contain 'CaptureArtifactBytesChanged'
        @($script:requests|Where-Object Method -cne 'GET').Count | Should -Be 0
    }

    # Scenario: A review approves a different Markdown path or an older content digest.
    # Purpose: Preview must bind capture dispositions to the exact mapped committed destination, not merely valid review status.
    It 'InterT50_blocks_mismatched_or_stale_capture_destinations' -TestCases @(
        @{Case='destination-mismatch';Reason='DispositionDestinationMismatch'},
        @{Case='stale-destination';Reason='DispositionDestinationChanged'}
    ) {
        param($Case,$Reason)
        Add-MarkdownPreviewCapture -Case $Case
        $result=Invoke-MarkdownPreview
        $result.status | Should -Be 'blocked'
        @($result.reasonCodes) | Should -Contain $Reason
        (Test-Path -LiteralPath $script:fixture.planPath) | Should -BeFalse
    }

    # Scenario: An unresolved captured block remains non-ready.
    # Purpose: A valid review record cannot turn unknown content into a publishable Markdown page.
    It 'InterT60_blocks_unknown_capture_disposition_before_preview' {
        Add-MarkdownPreviewCapture -Case unknown
        $result=Invoke-MarkdownPreview
        $result.status | Should -Be 'blocked'
        @($result.reasonCodes) | Should -Contain 'ImportDispositionNotReady'
        (Test-Path -LiteralPath $script:fixture.planPath) | Should -BeFalse
    }
}
