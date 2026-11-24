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

    function Get-PhysicalPath {
        param([string]$Path)
        $physical=& /bin/sh -c 'cd "$1" && pwd -P' sh $Path
        if($LASTEXITCODE -ne 0){throw 'Physical path lookup failed.'}
        return ([string]$physical).Trim()
    }

    function New-MarkdownPreviewFixture {
        param([switch]$MappingIdent)
        $tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
        if(-not $IsWindows){$tempParent=Get-PhysicalPath -Path $tempParent}
        $root=Join-Path $tempParent ('syp171-markdown-preview-'+[Guid]::NewGuid().ToString('N'))
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
        if(-not $IsWindows){$parent=Get-PhysicalPath -Path $parent}
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
        param([ValidateSet('valid','destination-mismatch','stale-destination','unknown','depth-unsupported')][string]$Case='valid',[switch]$LargeAsset,[switch]$NormalizeRawCapture)
        Import-Module (Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/StorageProjection.psm1') -Force
        $captureRoot=Join-Path $script:fixture.root '.confluence/captures/fixture'
        $rawDirectory=Join-Path $captureRoot 'pages/101'
        $assetDirectory=Join-Path $captureRoot 'assets'
        $docsAssetDirectory=Join-Path $script:fixture.root 'docs/assets'
        New-Item -ItemType Directory -Path $rawDirectory,$assetDirectory,$docsAssetDirectory -Force|Out-Null
        if($Case -ceq 'depth-unsupported'){
            $storage=('<strong>' * 129) + 'deep preview source' + ('</strong>' * 129)
            $rawBytes=[Text.UTF8Encoding]::new($false).GetBytes($storage)
        }else{
            $rawBytes=[IO.File]::ReadAllBytes((Join-Path $repositoryRoot 'tests/fixtures/syp171-import/mixed-storage.xml'))
            $storage=[Text.UTF8Encoding]::new($false,$true).GetString($rawBytes)
        }
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
        $captureStatus='complete'
        [object[]]$captureReasons=@()
        if($Case -ceq 'depth-unsupported'){
            $captureStatus='partial'
            [object[]]$captureReasons=@('UnsupportedContent')
        }
        $capture=[ordered]@{
            schemaVersion=1;captureId='preview-capture';capturedAtUtc='2026-10-12T00:00:00Z'
            siteOrigin=$site;cloudId=$cloud;scope=@{kind='page';pageIds=@('101')};status=$captureStatus;reasonCodes=$captureReasons;incompletePageIds=@()
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
            $isUnknown=$Case -in @('unknown','depth-unsupported') -and $index -eq 0
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
    function Add-MarkdownPreviewLinkedTarget {
        param([AllowNull()][string]$TargetPageId,[string]$Href='setup.md#setup')
        [IO.File]::WriteAllText((Join-Path $script:fixture.root 'docs/general.md'),"# Overview`n`nSee [Setup]($Href).",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $script:fixture.root 'docs/setup.md'),"# Setup`n`nSetup steps.",[Text.UTF8Encoding]::new($false))
        $mapping=Get-Content -LiteralPath $script:fixture.mappingPath -Raw|ConvertFrom-Json -AsHashtable
        $mapping.entries[0].linkBindings=@(@{href=$Href;targetProjectionId='setup-guide'})
        $target=[ordered]@{projectionId='setup-guide';sourceArtifact='docs/setup.md';sourceSectionId='document';pageId=$null;spaceId='55';parentId='99';parentProjectionId='';title='Setup';assets=@();linkBindings=@();contentKind='general'}
        if(-not [string]::IsNullOrEmpty($TargetPageId)){$target.pageId=$TargetPageId}
        $mapping.entries=@($mapping.entries[0],$target)
        [IO.File]::WriteAllText($script:fixture.mappingPath,($mapping|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        & git -C $script:fixture.root add -- docs/general.md docs/setup.md mapping.json|Out-Null
        & git -C $script:fixture.root commit --quiet -m 'Fixture cross-page heading link'
        if($LASTEXITCODE -ne 0){throw 'Unable to commit the cross-page link fixture.'}
        $script:fixture.commit=(& git -C $script:fixture.root rev-parse HEAD).Trim()
    }
    function New-MarkdownPreviewMultiPageHttp {
        return {
            param($Request)
            $script:requests.Add([pscustomobject]@{Method=[string]$Request.Method;Uri=[string]$Request.Uri})
            if([string]$Request.Uri -match '/pages/[0-9]+/attachments\?limit=50$'){
                return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{results=@();_links=@{}}}
            }
            $pageId=if([string]$Request.Uri -match '/pages/([0-9]+)'){$Matches[1]}else{throw 'Unexpected preview request.'}
            $title=if($pageId -ceq '102'){'Setup'}else{'General'}
            $isDraft=([string]$Request.Uri).Contains('status=draft',[StringComparison]::Ordinal)
            $storage=if($isDraft){'<p>Draft baseline</p>'}else{'<p>Published baseline</p>'}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{id=$pageId;spaceId='55';parentId='99';title=$title;status=$(if($isDraft){'draft'}else{'current'});version=@{number=$(if($isDraft){1}else{7})};body=@{storage=@{value=$storage}}}}
        }
    }
    function Invoke-MarkdownPreview {
        param([string]$Mode='current',[string[]]$ProjectionScope,[scriptblock]$Http,[string[]]$DraftEditorLinkTargets,[string]$RetainedSectionHeading,[string[]]$RetainedSectionTargets)
        Import-Module -Name $workflowPath -Force
        $previewArgs=@{
            Root=$script:fixture.root;MappingPath=$script:fixture.mappingPath;DocsCommit=$script:fixture.commit
            PlanPath=$script:fixture.planPath;ExpectedSiteOrigin=$site
            ApiBase="https://api.atlassian.com/ex/confluence/$cloud";HttpInvoker=$(if($Http){$Http}else{New-MarkdownPreviewHttp});PublishMode=$Mode
        }
        if($PSBoundParameters.ContainsKey('ProjectionScope')){$previewArgs.ProjectionScope=$ProjectionScope}
        if($PSBoundParameters.ContainsKey('DraftEditorLinkTargets')){$previewArgs.DraftEditorLinkTargets=$DraftEditorLinkTargets}
        if($PSBoundParameters.ContainsKey('RetainedSectionHeading')){$previewArgs.RetainedSectionHeading=$RetainedSectionHeading}
        if($PSBoundParameters.ContainsKey('RetainedSectionTargets')){$previewArgs.RetainedSectionTargets=$RetainedSectionTargets}
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

    # Scenario: A committed Markdown page links to a heading in another mapped page of the same preview.
    # Purpose: Preview's generic Dictionary of committed-source snapshots must resolve that cross-page fragment into a page link.
    It 'InterT25_previews_cross_page_heading_link_from_committed_source_snapshots' {
        Add-MarkdownPreviewLinkedTarget -TargetPageId '102'

        $r=Invoke-MarkdownPreview -Http (New-MarkdownPreviewMultiPageHttp)

        @($r.reasonCodes) | Should -HaveCount 0
        $r.status | Should -Be 'preview'
        $plan=Get-Content -LiteralPath $script:fixture.planPath -Raw|ConvertFrom-Json -AsHashtable
        $plan.Contains('projectionScope') | Should -BeFalse
        $page=@($plan.pages|Where-Object {$_.projectionId -ceq 'general-doc'})
        $page | Should -HaveCount 1
        $body=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes((Join-Path (Split-Path -Parent $script:fixture.planPath) $page[0].payloadPath)))
        $body | Should -Match ([regex]::Escape("$site/wiki/pages/viewpage.action?pageId=102#setup"))
        @($script:requests|Where-Object Method -cne 'GET').Count | Should -Be 0
    }

    # Scenario: A Draft preview covers one existing page that links to a mapped page whose destination is still undecided.
    # Purpose: The plan stays blocked, and the result names each blocking entry and the page-less link target.
    It 'InterT26_draft_preview_reports_per_entry_scope_blockers' {
        Add-MarkdownPreviewLinkedTarget -TargetPageId $null

        $r=Invoke-MarkdownPreview -Mode draft -Http (New-MarkdownPreviewMultiPageHttp)

        $r.status | Should -BeExactly 'blocked'
        @($r.reasonCodes) | Should -Be @('DraftScopeUnsupported')
        $blockers=@($r.blockers)
        $blockers.Count | Should -Be 2
        $blockers[0].projectionId | Should -BeExactly 'general-doc'
        @($blockers[0].reasonCodes) | Should -Be @('LinkTargetPageIdMissing')
        @($blockers[0].linkTargets) | Should -Be @('setup-guide')
        $blockers[1].projectionId | Should -BeExactly 'setup-guide'
        @($blockers[1].reasonCodes) | Should -Be @('PageIdMissing')
        Test-Path -LiteralPath $script:fixture.planPath | Should -BeFalse
        $script:requests.Count | Should -Be 0
    }

    # Scenario: A Draft preview is limited to one page that links to an out-of-scope page with a real page ID.
    # Purpose: Only scoped entries become payloads; the link still resolves; the plan records the scope and every exclusion.
    It 'InterT27_scoped_draft_preview_records_scope_and_excluded_entries' {
        Add-MarkdownPreviewLinkedTarget -TargetPageId '102'

        $r=Invoke-MarkdownPreview -Mode draft -ProjectionScope @('general-doc') -Http (New-MarkdownPreviewMultiPageHttp)

        @($r.reasonCodes) | Should -HaveCount 0
        $r.status | Should -BeExactly 'preview'
        $planJson=Get-Content -LiteralPath $script:fixture.planPath -Raw
        Test-Json -Json $planJson -SchemaFile (Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/references/publish-plan.schema.json') | Should -BeTrue
        $plan=$planJson|ConvertFrom-Json -AsHashtable
        (Test-MarkdownPreviewPlanShape -Plan $plan) | Should -BeTrue
        @($plan.pages|ForEach-Object {$_.projectionId}) | Should -Be @('general-doc')
        @($plan.projectionScope.projectionIds) | Should -Be @('general-doc')
        $excluded=@($plan.projectionScope.excludedEntries)
        $excluded.Count | Should -Be 1
        $excluded[0].projectionId | Should -BeExactly 'setup-guide'
        @($excluded[0].reasonCodes) | Should -Be @('ExcludedByProjectionScope')
        $mismatched=$planJson|ConvertFrom-Json -AsHashtable
        $mismatched.projectionScope.projectionIds=@('setup-guide')
        $mismatched.projectionScope.excludedEntries=@(@{projectionId='general-doc';reasonCodes=@('ExcludedByProjectionScope')})
        (Test-MarkdownPreviewPlanShape -Plan $mismatched) | Should -BeFalse
        $body=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes((Join-Path (Split-Path -Parent $script:fixture.planPath) $plan.pages[0].payloadPath)))
        $body | Should -Match ([regex]::Escape("$site/wiki/pages/viewpage.action?pageId=102#setup"))
        @($script:requests|Where-Object {$_.Uri -match '/pages/102'}).Count | Should -Be 0
        @($script:requests|Where-Object Method -cne 'GET').Count | Should -Be 0
    }

    # Scenario: A scoped preview page links to a mapped page that has no page ID and is outside the scope.
    # Purpose: Scope never hides an unresolved link: Draft and current previews both block and name the scoped entry.
    It 'InterT28_scoped_preview_still_blocks_links_to_pageless_entries' {
        Add-MarkdownPreviewLinkedTarget -TargetPageId $null

        $draft=Invoke-MarkdownPreview -Mode draft -ProjectionScope @('general-doc') -Http (New-MarkdownPreviewMultiPageHttp)

        $draft.status | Should -BeExactly 'blocked'
        @($draft.reasonCodes) | Should -Be @('DraftScopeUnsupported')
        @($draft.blockers).Count | Should -Be 1
        $draft.blockers[0].projectionId | Should -BeExactly 'general-doc'
        @($draft.blockers[0].reasonCodes) | Should -Be @('LinkTargetPageIdMissing')
        @($draft.blockers[0].linkTargets) | Should -Be @('setup-guide')

        $current=Invoke-MarkdownPreview -ProjectionScope @('general-doc') -Http (New-MarkdownPreviewMultiPageHttp)

        $current.status | Should -BeExactly 'blocked'
        @($current.reasonCodes) | Should -Be @('ProjectionScopeDependencyExcluded')
        @($current.blockers).Count | Should -Be 1
        $current.blockers[0].projectionId | Should -BeExactly 'general-doc'
        @($current.blockers[0].reasonCodes) | Should -Be @('LinkTargetExcluded')
        @($current.blockers[0].linkTargets) | Should -Be @('setup-guide')
        Test-Path -LiteralPath $script:fixture.planPath | Should -BeFalse
        $script:requests.Count | Should -Be 0
    }

    # Scenario: A caller passes an empty, duplicated, malformed, or unmapped projection scope.
    # Purpose: Scope is an explicit, exact selection; anything ambiguous is rejected before remote reads or plan output.
    It 'InterT29_rejects_invalid_projection_scope_<Case>' -TestCases @(
        @{Case='empty';Scope=@()}
        @{Case='duplicate';Scope=@('general-doc','general-doc')}
        @{Case='malformed';Scope=@('General-Doc')}
        @{Case='unmapped';Scope=@('general-doc','missing-entry')}
    ) {
        param($Case,$Scope)
        Add-MarkdownPreviewLinkedTarget -TargetPageId '102'

        $r=Invoke-MarkdownPreview -ProjectionScope $Scope -Http (New-MarkdownPreviewMultiPageHttp)

        $r.status | Should -BeExactly 'invalid'
        @($r.reasonCodes) | Should -Be @('ProjectionScopeInvalid')
        Test-Path -LiteralPath $script:fixture.planPath | Should -BeFalse
        $script:requests.Count | Should -Be 0
    }

    # Scenario: A scoped current plan is checked again before execution, unchanged and after its recorded scope was edited.
    # Purpose: Execution recomputes the scope record from the current mapping and refuses a plan whose recorded scope differs.
    It 'InterT31_execution_revalidates_the_recorded_projection_scope' {
        Add-MarkdownPreviewLinkedTarget -TargetPageId '102'
        $preview=Invoke-MarkdownPreview -ProjectionScope @('general-doc') -Http (New-MarkdownPreviewMultiPageHttp)
        $preview.status | Should -BeExactly 'preview'
        Import-Module -Name (Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceValidation.psm1') -Force
        $validation=Invoke-ConfluenceValidation -Root $script:fixture.root -MappingPath $script:fixture.mappingPath -DocsCommit $script:fixture.commit
        $api="https://api.atlassian.com/ex/confluence/$cloud"
        Import-Module (Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluencePlan.psm1') -Force

        (Test-ConfluencePlanDrift -PlanPath $script:fixture.planPath -CurrentValidation $validation -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-MarkdownPreviewMultiPageHttp)).status | Should -BeExactly 'ready'

        $planText=[IO.File]::ReadAllText($script:fixture.planPath,[Text.UTF8Encoding]::new($false,$true))
        $tampered=$planText.Replace('"ExcludedByProjectionScope"','"ExcludedByProjectionScope","PageIdMissing"')
        $tampered | Should -Not -BeExactly $planText
        [IO.File]::WriteAllText($script:fixture.planPath,$tampered,[Text.UTF8Encoding]::new($false))
        $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($script:fixture.planPath))).ToLowerInvariant()
        [IO.File]::WriteAllText("$($script:fixture.planPath).sha256","$digest`n",[Text.UTF8Encoding]::new($false))
        $plan=$tampered|ConvertFrom-Json -AsHashtable
        (Test-MarkdownPreviewPlanShape -Plan $plan) | Should -BeTrue
        $script:requests.Clear()

        $drift=Test-ConfluencePlanDrift -PlanPath $script:fixture.planPath -CurrentValidation $validation -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-MarkdownPreviewMultiPageHttp)
        $drift.status | Should -BeExactly 'blocked'
        @($drift.reasonCodes) | Should -Be @('ProjectionScopeChanged')

        $authPath=Join-Path $script:fixture.root 'authorization.json'
        $auth=[ordered]@{schemaVersion=1;planSha256=$digest;operationId=$plan.operationId;siteOrigin=$site;cloudId=$cloud
            approvedActions=@($plan.pages|Where-Object action -ne 'no-op'|ForEach-Object {"update:$($_.pageId)"});approvalEvidenceRef='synthetic-fixture-only'}
        [IO.File]::WriteAllText($authPath,($auth|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        Import-Module (Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluencePublish.psm1') -Force
        $executed=Invoke-ConfluencePlan -PlanPath $script:fixture.planPath -CurrentValidation $validation -AuthorizationPath $authPath `
            -JournalPath "$($script:fixture.planPath).journal.json" -SyncPath "$($script:fixture.planPath).sync.json" -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-MarkdownPreviewMultiPageHttp)
        $executed.status | Should -BeExactly 'blocked'
        @($executed.reasonCodes) | Should -Be @('ProjectionScopeChanged')
        @($script:requests|Where-Object Method -cne 'GET').Count | Should -Be 0
        Test-Path -LiteralPath "$($script:fixture.planPath).journal.json" | Should -BeFalse
    }
    # Scenario: A Draft preview names a mapped target whose links must open its Draft in the Confluence editor.
    # Purpose: Only that target's links become resumedraft URLs; the plan records the policy so the digest and authorization cover it.
    It 'InterT32_draft_link_policy_renders_editor_urls_and_records_the_policy' {
        Add-MarkdownPreviewLinkedTarget -TargetPageId '102' -Href 'setup.md'

        $r=Invoke-MarkdownPreview -Mode draft -ProjectionScope @('general-doc') -DraftEditorLinkTargets @('setup-guide') -Http (New-MarkdownPreviewMultiPageHttp)

        @($r.reasonCodes) | Should -HaveCount 0
        $r.status | Should -BeExactly 'preview'
        $planJson=Get-Content -LiteralPath $script:fixture.planPath -Raw
        Test-Json -Json $planJson -SchemaFile (Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/references/publish-plan.schema.json') | Should -BeTrue
        $plan=$planJson|ConvertFrom-Json -AsHashtable
        (Test-MarkdownPreviewPlanShape -Plan $plan) | Should -BeTrue
        $targets=@($plan.draftLinkPolicy.draftEditorTargets)
        $targets.Count | Should -Be 1
        $targets[0].projectionId | Should -BeExactly 'setup-guide'
        $targets[0].pageId | Should -BeExactly '102'
        $body=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes((Join-Path (Split-Path -Parent $script:fixture.planPath) $plan.pages[0].payloadPath)))
        $body | Should -Match ([regex]::Escape("$site/wiki/pages/resumedraft.action?draftId=102"))
        $body | Should -Not -Match 'viewpage\.action'
        @($r.draftLinkPolicy.draftEditorTargets).Count | Should -Be 1

        $plan.Contains('draftLinkPolicy') | Should -BeTrue
        Remove-Item -LiteralPath $script:fixture.planPath,"$($script:fixture.planPath).sha256" -Force
        $default=Invoke-MarkdownPreview -Mode draft -ProjectionScope @('general-doc') -Http (New-MarkdownPreviewMultiPageHttp)
        $default.status | Should -BeExactly 'preview'
        $defaultPlan=Get-Content -LiteralPath $script:fixture.planPath -Raw|ConvertFrom-Json -AsHashtable
        $defaultPlan.Contains('draftLinkPolicy') | Should -BeFalse
        $defaultBody=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes((Join-Path (Split-Path -Parent $script:fixture.planPath) $defaultPlan.pages[0].payloadPath)))
        $defaultBody | Should -Match ([regex]::Escape("$site/wiki/pages/viewpage.action?pageId=102"))
        @($script:requests|Where-Object Method -cne 'GET').Count | Should -Be 0
    }

    # Scenario: The Draft link policy is requested in current mode, names an invalid or page-less target, or meets a link fragment.
    # Purpose: The policy is explicit and exact; anything it cannot honor is refused before remote reads instead of being dropped.
    It 'InterT33_rejects_unusable_draft_link_policies_<Case>' -TestCases @(
        @{Case='current-mode';Mode='current';Targets=@('setup-guide');TargetPageId='102';Href='setup.md';Status='invalid';Reason='DraftLinkPolicyRequiresDraftMode'}
        @{Case='empty';Mode='draft';Targets=@();TargetPageId='102';Href='setup.md';Status='invalid';Reason='DraftLinkPolicyInvalid'}
        @{Case='duplicate';Mode='draft';Targets=@('setup-guide','setup-guide');TargetPageId='102';Href='setup.md';Status='invalid';Reason='DraftLinkPolicyInvalid'}
        @{Case='malformed';Mode='draft';Targets=@('Setup-Guide');TargetPageId='102';Href='setup.md';Status='invalid';Reason='DraftLinkPolicyInvalid'}
        @{Case='unmapped';Mode='draft';Targets=@('missing-entry');TargetPageId='102';Href='setup.md';Status='invalid';Reason='DraftLinkPolicyInvalid'}
        @{Case='pageless';Mode='draft';Targets=@('setup-guide');TargetPageId=$null;Href='setup.md';Status='invalid';Reason='DraftLinkPolicyInvalid'}
        @{Case='fragment';Mode='draft';Targets=@('setup-guide');TargetPageId='102';Href='setup.md#setup';Status='blocked';Reason='DraftLinkFragmentUnsupported'}
    ) {
        param($Case,$Mode,$Targets,$TargetPageId,$Href,$Status,$Reason)
        Add-MarkdownPreviewLinkedTarget -TargetPageId $TargetPageId -Href $Href

        $r=Invoke-MarkdownPreview -Mode $Mode -ProjectionScope @('general-doc') -DraftEditorLinkTargets $Targets -Http (New-MarkdownPreviewMultiPageHttp)

        $r.status | Should -BeExactly $Status
        @($r.reasonCodes) | Should -Be @($Reason)
        if($Case -ceq 'fragment'){
            @($r.blockers).Count | Should -Be 1
            $r.blockers[0].projectionId | Should -BeExactly 'general-doc'
            @($r.blockers[0].reasonCodes) | Should -Be @('DraftLinkFragmentUnsupported')
            @($r.blockers[0].linkTargets) | Should -Be @('setup-guide')
        }
        Test-Path -LiteralPath $script:fixture.planPath | Should -BeFalse
        $script:requests.Count | Should -Be 0
    }

    # Scenario: A Draft plan with a link policy is checked before execution, unchanged and after its recorded policy was edited.
    # Purpose: Execution recomputes the policy from the current mapping and refuses a plan whose recorded policy differs.
    It 'InterT34_execution_revalidates_the_recorded_draft_link_policy' {
        Add-MarkdownPreviewLinkedTarget -TargetPageId '102' -Href 'setup.md'
        $preview=Invoke-MarkdownPreview -Mode draft -ProjectionScope @('general-doc') -DraftEditorLinkTargets @('setup-guide') -Http (New-MarkdownPreviewMultiPageHttp)
        $preview.status | Should -BeExactly 'preview'
        Import-Module -Name (Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceValidation.psm1') -Force
        $validation=Invoke-ConfluenceValidation -Root $script:fixture.root -MappingPath $script:fixture.mappingPath -DocsCommit $script:fixture.commit
        $api="https://api.atlassian.com/ex/confluence/$cloud"
        Import-Module (Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluencePlan.psm1') -Force

        (Test-ConfluencePlanDrift -PlanPath $script:fixture.planPath -CurrentValidation $validation -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-MarkdownPreviewMultiPageHttp)).status | Should -BeExactly 'ready'

        $planText=[IO.File]::ReadAllText($script:fixture.planPath,[Text.UTF8Encoding]::new($false,$true))
        ([regex]::Matches($planText,'"pageId": "102"')).Count | Should -Be 1
        $tampered=$planText.Replace('"pageId": "102"','"pageId": "103"')
        [IO.File]::WriteAllText($script:fixture.planPath,$tampered,[Text.UTF8Encoding]::new($false))
        $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($script:fixture.planPath))).ToLowerInvariant()
        [IO.File]::WriteAllText("$($script:fixture.planPath).sha256","$digest`n",[Text.UTF8Encoding]::new($false))
        $plan=$tampered|ConvertFrom-Json -AsHashtable
        (Test-MarkdownPreviewPlanShape -Plan $plan) | Should -BeTrue
        $script:requests.Clear()

        $drift=Test-ConfluencePlanDrift -PlanPath $script:fixture.planPath -CurrentValidation $validation -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-MarkdownPreviewMultiPageHttp)
        $drift.status | Should -BeExactly 'blocked'
        @($drift.reasonCodes) | Should -Be @('DraftLinkPolicyChanged')

        $authPath=Join-Path $script:fixture.root 'authorization.json'
        $auth=[ordered]@{schemaVersion=4;publishMode='draft';attachmentStrategy='immutable-content-name';planSha256=$digest;operationId=$plan.operationId;siteOrigin=$site;cloudId=$cloud
            approvedActions=@($plan.pages|Where-Object action -ne 'no-op'|ForEach-Object {"draft-update:$($_.pageId)"});approvalEvidenceRef='synthetic-fixture-only'}
        [IO.File]::WriteAllText($authPath,($auth|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        Import-Module (Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluencePublish.psm1') -Force
        $executed=Invoke-ConfluencePlan -PlanPath $script:fixture.planPath -CurrentValidation $validation -AuthorizationPath $authPath `
            -JournalPath "$($script:fixture.planPath).journal.json" -SyncPath "$($script:fixture.planPath).sync.json" -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker (New-MarkdownPreviewMultiPageHttp)
        $executed.status | Should -BeExactly 'blocked'
        @($executed.reasonCodes) | Should -Be @('DraftLinkPolicyChanged')
        @($script:requests|Where-Object Method -cne 'GET').Count | Should -Be 0
        Test-Path -LiteralPath "$($script:fixture.planPath).journal.json" | Should -BeFalse
    }
    # Scenario: A preview asks to keep a retained target section, with incomplete or unusable parameters or a target lacking the marker.
    # Purpose: The workflow validates the opt-in policy against the mapping and scope before remote reads, then hands it to the plan.
    It 'InterT37_validates_and_applies_the_retained_section_policy_<Case>' -TestCases @(
        @{Case='heading-only';Options=@{RetainedSectionHeading='Retained'};TargetPageId=$null;Status='invalid';Reason='RetainedSectionPolicyInvalid'}
        @{Case='targets-only';Options=@{RetainedSectionTargets=@('general-doc')};TargetPageId=$null;Status='invalid';Reason='RetainedSectionPolicyInvalid'}
        @{Case='blank-heading';Options=@{RetainedSectionHeading='  ';RetainedSectionTargets=@('general-doc')};TargetPageId=$null;Status='invalid';Reason='RetainedSectionPolicyInvalid'}
        @{Case='pageless-target';Options=@{RetainedSectionHeading='Retained';RetainedSectionTargets=@('setup-guide')};TargetPageId=$null;Status='invalid';Reason='RetainedSectionPolicyInvalid'}
        @{Case='out-of-scope';Options=@{RetainedSectionHeading='Retained';RetainedSectionTargets=@('setup-guide')};TargetPageId='102';Status='invalid';Reason='RetainedSectionPolicyInvalid'}
        @{Case='unmapped';Options=@{RetainedSectionHeading='Retained';RetainedSectionTargets=@('missing-entry')};TargetPageId=$null;Status='invalid';Reason='RetainedSectionPolicyInvalid'}
        @{Case='marker-missing';Options=@{RetainedSectionHeading='Retained';RetainedSectionTargets=@('general-doc')};TargetPageId='102';Status='blocked';Reason='RetainedSectionMarkerMissing'}
    ) {
        param($Case,$Options,$TargetPageId,$Status,$Reason)
        Add-MarkdownPreviewLinkedTarget -TargetPageId $TargetPageId -Href 'setup.md'
        $previewArgs=@{Mode='draft';Http=(New-MarkdownPreviewMultiPageHttp);ProjectionScope=@('general-doc')}
        foreach($key in $Options.Keys){$previewArgs[$key]=$Options[$key]}

        $r=Invoke-MarkdownPreview @previewArgs

        $r.status | Should -BeExactly $Status
        @($r.reasonCodes) | Should -Be @($Reason)
        if($Status -ceq 'blocked'){
            @($r.blockers|ForEach-Object {"$($_.projectionId):$(@($_.reasonCodes)-join '+')"}) | Should -Be @('general-doc:RetainedSectionMarkerMissing')
        }else{$script:requests.Count | Should -Be 0}
        Test-Path -LiteralPath $script:fixture.planPath | Should -BeFalse
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
    It 'InterT50_blocks_mismatched_or_stale_capture_destinations_<Case>' -TestCases @(
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

    It 'InterT65_keeps_deep_capture_raw_evidence_and_blocks_nonready_markdown_preview' {
        Add-MarkdownPreviewCapture -Case depth-unsupported
        $capturePath=Join-Path $script:fixture.root '.confluence/captures/fixture/capture.json'
        $capture=Get-Content -LiteralPath $capturePath -Raw|ConvertFrom-Json
        $page=$capture.pages[0]
        $rawPath=Join-Path (Split-Path -Parent $capturePath) $page.snapshotPath
        $rawBytes=[IO.File]::ReadAllBytes($rawPath)
        $rawHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rawBytes)).ToLowerInvariant()
        $page.projectionStatus | Should -BeExactly 'unsupported'
        @($page.unsupported|Where-Object code -CEQ 'StorageDepthExceeded').Count | Should -Be 1
        $page.bodySha256 | Should -BeExactly $rawHash
        $page.unsupported[0].sourceSha256 | Should -BeExactly $rawHash
        $review=Get-Content -LiteralPath (Join-Path (Split-Path -Parent $capturePath) 'import-review.json') -Raw|ConvertFrom-Json
        $review.dispositions[0].status | Should -BeExactly 'unknown'
        $review.dispositions[0].ready | Should -BeFalse
        @($review.dispositions[0].destinations).Count | Should -Be 0
        [IO.File]::ReadAllBytes((Join-Path (Split-Path -Parent $capturePath) $page.candidatePath)).Length | Should -Be 0

        $result=Invoke-MarkdownPreview

        $result.status | Should -BeExactly 'blocked'
        @($result.reasonCodes) | Should -Contain 'CaptureIncomplete'
        (Test-Path -LiteralPath $script:fixture.planPath) | Should -BeFalse
        @($script:requests).Count | Should -Be 0
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($rawPath))).ToLowerInvariant() | Should -BeExactly $rawHash
    }
}
