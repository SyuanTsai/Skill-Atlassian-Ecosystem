# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
$reviewModule=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ImportReview.psm1'
$projectionModule=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/StorageProjection.psm1'
$sourcePath=Join-Path $PSScriptRoot 'fixtures/syp171-import/mixed-storage.xml'

function New-ImportFixture {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('syp171-import-tests-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Import-Module -Name $projectionModule -Force
    $storage=Get-Content -LiteralPath $sourcePath -Raw -Encoding utf8
    $projection=ConvertFrom-ConfluenceStorage -Storage $storage -PageId '101' -PageVersion 3
    $pageFiles=Join-Path $root 'pages/101'
    New-Item -ItemType Directory -Path $pageFiles -Force|Out-Null
    $destinationDirectory=Join-Path $root 'docs'
    New-Item -ItemType Directory -Path $destinationDirectory -Force|Out-Null
    $destinationBytes=[Text.UTF8Encoding]::new($false).GetBytes("# Reviewed import`n`nAccepted captured content.`n")
    [IO.File]::WriteAllBytes((Join-Path $destinationDirectory 'accepted.md'),$destinationBytes)
    $destinationHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($destinationBytes)).ToLowerInvariant()
    $assetBytes=[byte[]]@(1,2,3,4)
    $captureAssetDirectory=Join-Path $pageFiles 'assets'
    New-Item -ItemType Directory -Path $captureAssetDirectory -Force|Out-Null
    [IO.File]::WriteAllBytes((Join-Path $captureAssetDirectory 'diagram.png'),$assetBytes)
    $assetHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($assetBytes)).ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $pageFiles 'storage.xml'),$storage,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $pageFiles 'candidate.md'),$projection.markdown,[Text.UTF8Encoding]::new($false))
    $capture=[ordered]@{
        schemaVersion=1;captureId='fixture-capture';capturedAtUtc='2026-09-16T00:00:00Z'
        siteOrigin='https://example.atlassian.net';cloudId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        scope=@{kind='page';pageIds=@('101')};status='complete';reasonCodes=@();incompletePageIds=@()
        pages=@(@{pageId='101';spaceId='55';parentId='99';title='Synthetic source';version=3
            bodySha256=$projection.bodySha256;draftObservation='same-as-published'
            snapshotPath='pages/101/storage.xml';candidatePath='pages/101/candidate.md'
            projectionStatus=$projection.status;sourceBlocks=@($projection.sourceBlocks);unsupported=@();attachments=@(@{
                attachmentId='501';version=2;filename='diagram.png';mediaType='image/png';byteLength=$assetBytes.Length;sha256=$assetHash;assetPath='pages/101/assets/diagram.png'
            })})
    }
    $capturePath=Join-Path $root 'capture.json'
    [IO.File]::WriteAllText($capturePath,($capture|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    $destination=@{sourceArtifact='docs/accepted.md';sourceSectionId='document';contentSha256=$destinationHash}
    $dispositions=[System.Collections.Generic.List[object]]::new()
    for($i=0;$i -lt $projection.sourceBlocks.Count;$i++){
        $block=$projection.sourceBlocks[$i]
            $status=if($i -eq 3){'unknown'}elseif($i -eq 4){'retained'}else{'accepted'}
            $blockDestinations=[System.Collections.Generic.List[object]]::new()
            if($status -eq 'accepted'){$blockDestinations.Add($destination)}
        $dispositions.Add(@{
            blockId=$block.id;sourceSha256=$block.sourceSha256;location=$block.location
            status=$status;ready=($status -eq 'accepted');destinations=$blockDestinations.ToArray();reason=if($status -eq 'unknown'){'Outcome absent from source'}elseif($status -eq 'retained'){'Operational source, embedded instruction ignored'}else{'Confirmed source role'}
        })
    }
    $review=[ordered]@{schemaVersion=2;captureId='fixture-capture';siteOrigin='https://example.atlassian.net';dispositions=@($dispositions.ToArray());attachments=@(@{
        pageId='101';attachmentId='501';version=2;sha256=$assetHash;status='supported';ready=$true
        destination=@{localPath='docs/assets/diagram.png';displayFilename='diagram.png';mediaType='image/png';byteLength=$assetBytes.Length;contentSha256=$assetHash}
        reason='Supported image is mapped for publication'
    })}
    return [pscustomobject]@{root=$root;capturePath=$capturePath;review=$review;blocks=@($projection.sourceBlocks);assetHash=$assetHash}
}

function Remove-ImportFixture {
    param([string]$Root)
    if(-not(Test-Path -LiteralPath $Root)){return}
    $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if([IO.Path]::GetDirectoryName($resolved).TrimEnd('\','/') -cne $parent -or [IO.Path]::GetFileName($resolved) -cnotmatch '^syp171-import-tests-[a-f0-9]{32}$'){throw 'Unsafe import fixture delete.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

function Invoke-ImportFixture {
    param($Fixture,$Review)
    if(-not(Test-Path -LiteralPath $reviewModule)){throw 'Import review module missing.'}
    Import-Module -Name $reviewModule -Force
    $path=Join-Path $Fixture.root 'review.json'
    [IO.File]::WriteAllText($path,($Review|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    $result=Test-ConfluenceImportReview -CapturePath $Fixture.capturePath -ReviewPath $path
    return $result
}

}

Describe 'SYP-171 source block review coverage' {
    BeforeEach{$script:fixture=New-ImportFixture}
    AfterEach{Remove-ImportFixture -Root $script:fixture.root}

    # Scenario: SYP171-SCN-003; mixed content has a destination or retained reference for every source block.
    # Purpose: Imported content and an attachment are traced to exact Markdown and binary destinations.
    It 'UnitT10_accepts_complete_source_block_dispositions_and_keeps_not_ready_out_of_destinations' {
        $r=Invoke-ImportFixture $script:fixture $script:fixture.review
        $r.status | Should -Be 'valid'
        $r.sourceBlockCount | Should -Be 5
        $r.unknownCount | Should -Be 1
        $r.nonReadyCount | Should -Be 2
        @($r.acceptedDestinations).Count | Should -Be 3
        @($r.acceptedAttachments).Count | Should -Be 1
        $r.acceptedAttachments[0].sha256 | Should -Be $script:fixture.assetHash
    }

    # Scenario: SYP171-SCN-003/008; a full capture manifest acquires a second THEN authority field.
    # Purpose: Import review must reject unknown operational fields instead of approving a requirement copy in JSON.
    It 'UnitT15_rejects_THEN_shadow_field_in_capture_manifest' {
        $capture=Get-Content -LiteralPath $script:fixture.capturePath -Raw|ConvertFrom-Json -AsHashtable
        $capture['THEN']='Synthetic expected result shadow'
        [IO.File]::WriteAllText($script:fixture.capturePath,($capture|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        $r=Invoke-ImportFixture $script:fixture $script:fixture.review
        $r.status | Should -Be 'invalid'
        @($r.reasonCodes) | Should -Contain 'ReviewSchemaInvalid'
    }

    # Scenario: SYP171-SCN-003/008; capture JSON repeats an authority-bearing property.
    # Purpose: Parsing must fail before duplicate keys can collapse into one apparently valid value.
    It 'UnitT16_rejects_duplicate_capture_property' {
        $json=Get-Content -LiteralPath $script:fixture.capturePath -Raw
        $json=$json.Replace('"schemaVersion": 1,','"schemaVersion": 1, "schemaVersion": 1,')
        [IO.File]::WriteAllText($script:fixture.capturePath,$json,[Text.UTF8Encoding]::new($false))
        $r=Invoke-ImportFixture $script:fixture $script:fixture.review
        $r.status | Should -Be 'invalid'
        @($r.reasonCodes) | Should -Contain 'ReviewSchemaInvalid'
    }

    # Scenario: SYP171-SCN-001/002; a page-scoped manifest substitutes a different page for the selected target.
    # Purpose: A complete capture must account for the exact authorized page inventory, not merely contain valid page records.
    It 'UnitT17_rejects_page_scope_inventory_substitution' {
        $capture=Get-Content -LiteralPath $script:fixture.capturePath -Raw|ConvertFrom-Json -AsHashtable
        $capture.scope.pageIds=@('102')
        [IO.File]::WriteAllText($script:fixture.capturePath,($capture|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        $r=Invoke-ImportFixture $script:fixture $script:fixture.review
        $r.status | Should -Be 'invalid'
        @($r.reasonCodes) | Should -Contain 'ReviewSchemaInvalid'
    }

    # Scenario: SYP171-SCN-001/003; storage bytes change after source block review was prepared.
    # Purpose: A valid-looking manifest and dispositions cannot approve altered raw capture content.
    It 'UnitT18_blocks_review_when_capture_snapshot_bytes_change' {
        [IO.File]::AppendAllText((Join-Path $script:fixture.root 'pages/101/storage.xml'),'<p>tampered</p>',[Text.UTF8Encoding]::new($false))
        $r=Invoke-ImportFixture $script:fixture $script:fixture.review
        $r.status | Should -Be 'blocked'
        @($r.reasonCodes) | Should -Contain 'CaptureSourceChanged'
    }

    # Scenario: SYP171-SCN-003; a captured source paragraph is absent from review.
    # Purpose: Whole-capture acceptance stops until the paragraph is accounted for.
    It 'UnitT20_blocks_missing_source_disposition' {
        $script:fixture.review.dispositions=@($script:fixture.review.dispositions | Select-Object -Skip 1)
        $r=Invoke-ImportFixture $script:fixture $script:fixture.review
        @($r.reasonCodes) | Should -Contain 'SourceDispositionMissing'
    }

    # Scenario: SYP171-SCN-004; missing outcome is marked ready.
    # Purpose: A candidate without approved THEN remains visible and non-ready.
    It 'UnitT30_rejects_unknown_marked_implementation_ready' {
        $script:fixture.review.dispositions[3].ready=$true
        $r=Invoke-ImportFixture $script:fixture $script:fixture.review
        @($r.reasonCodes) | Should -Contain 'UnknownMarkedReady'
    }

    # Scenario: SYP171-SCN-003; source hash no longer matches capture.
    # Purpose: Reusing a review after the source changed is not accepted.
    It 'UnitT40_rejects_review_of_different_source_bytes' {
        $script:fixture.review.dispositions[0].sourceSha256='a'*64
        $r=Invoke-ImportFixture $script:fixture $script:fixture.review
        @($r.reasonCodes) | Should -Contain 'SourceHashMismatch'
    }

    # Scenario: An accepted source block points at a Markdown artifact with a malformed content hash.
    # Purpose: Destination identity and commit-byte digest are mandatory review evidence.
    It 'UnitT50_rejects_accepted_destination_without_exact_content_hash' {
        $script:fixture.review.dispositions[0].destinations[0].contentSha256='not-a-hash'
        $r=Invoke-ImportFixture $script:fixture $script:fixture.review
        $r.status | Should -Be 'blocked'
        @($r.reasonCodes) | Should -Contain 'ReviewSchemaInvalid'
    }

    # Scenario: A non-accepted captured block names a Markdown destination.
    # Purpose: Retained, excluded, and unknown content cannot pass as accepted publication input.
    It 'UnitT55_rejects_publish_destination_for_nonaccepted_disposition' {
        $accepted=$script:fixture.review.dispositions[0].destinations[0]
        $script:fixture.review.dispositions[3].destinations=@($accepted)
        $r=Invoke-ImportFixture $script:fixture $script:fixture.review
        $r.status | Should -Be 'blocked'
        @($r.reasonCodes) | Should -Contain 'NonAcceptedDestinationForbidden'
    }

    # Scenario: An attachment has a supported, reviewed destination; manual and not-converted remain visible but non-ready.
    # Purpose: Attachment disposition cannot be inferred from a successful download or from review status alone.
    It 'UnitT60_preserves_supported_manual_and_not_converted_attachment_dispositions' {
        $supported=Invoke-ImportFixture $script:fixture $script:fixture.review
        $supported.status | Should -Be 'valid'
        @($supported.acceptedAttachments).Count | Should -Be 1

        foreach($status in @('manual','not-converted')){
            $script:fixture.review.attachments[0].status=$status
            $script:fixture.review.attachments[0].ready=$false
            $script:fixture.review.attachments[0].destination=$null
            $script:fixture.review.attachments[0].reason="Attachment requires $status handling"
            $reviewed=Invoke-ImportFixture $script:fixture $script:fixture.review
            $reviewed.status | Should -Be 'valid'
            $reviewed.nonReadyCount | Should -Be 3
            @($reviewed.acceptedAttachments).Count | Should -Be 0
        }
    }

    # Scenario: A captured attachment version changes after its disposition is reviewed.
    # Purpose: An old attachment review cannot authorize different content bytes.
    It 'UnitT65_rejects_attachment_review_with_a_different_capture_hash' {
        $script:fixture.review.attachments[0].sha256='a'*64
        $script:fixture.review.attachments[0].destination.contentSha256='a'*64
        $result=Invoke-ImportFixture $script:fixture $script:fixture.review
        @($result.reasonCodes) | Should -Contain 'AttachmentHashMismatch'
    }

    It 'InterT70_reprojects_deep_raw_storage_stably_and_keeps_unsupported_review_nonready' {
        Import-Module -Name $projectionModule -Force
        $storage = ('<strong>' * 129) + 'deep reviewed source' + ('</strong>' * 129)
        $rawBytes = [Text.UTF8Encoding]::new($false).GetBytes($storage)
        $rawHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rawBytes)).ToLowerInvariant()
        $projection = ConvertFrom-ConfluenceStorage -Storage $storage -PageId '101' -PageVersion 3
        $capture = Get-Content -LiteralPath $script:fixture.capturePath -Raw | ConvertFrom-Json -AsHashtable
        $capture.status = 'partial'
        $capture.reasonCodes = @('UnsupportedContent')
        $capture.incompletePageIds = @()
        $page = $capture.pages[0]
        $page.bodySha256 = $projection.bodySha256
        $page.projectionStatus = $projection.status
        $page.sourceBlocks = @($projection.sourceBlocks | ForEach-Object { [ordered]@{
            id=$_.id;location=$_.location;sourceSha256=$_.sourceSha256;sourceType=$_.sourceType;supported=$_.supported
        } })
        $page.unsupported = @($projection.unsupported | ForEach-Object { [ordered]@{
            code=$_.code;location=$_.location;sourceSha256=$_.sourceSha256
        } })
        [IO.File]::WriteAllBytes((Join-Path $script:fixture.root 'pages/101/storage.xml'), $rawBytes)
        [IO.File]::WriteAllBytes((Join-Path $script:fixture.root 'pages/101/candidate.md'), [byte[]]::new(0))
        [IO.File]::WriteAllText($script:fixture.capturePath, ($capture | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
        $script:fixture.review.dispositions = @([ordered]@{
            blockId=$projection.sourceBlocks[0].id;sourceSha256=$projection.sourceBlocks[0].sourceSha256
            location=$projection.sourceBlocks[0].location;status='unknown';ready=$false;destinations=@();reason='Deep storage needs a human review'
        })
        $script:fixture.review.attachments = @([ordered]@{
            pageId='101';attachmentId='501';version=2;sha256=$script:fixture.assetHash;status='not-converted';ready=$false
            destination=$null;reason='Attachment remains a separate manual review'
        })

        $result = Invoke-ImportFixture $script:fixture $script:fixture.review

        $result.status | Should -BeExactly 'blocked'
        @($result.reasonCodes) | Should -Contain 'CaptureIncomplete'
        $result.sourceBlockCount | Should -Be 1
        $result.unknownCount | Should -Be 1
        $result.nonReadyCount | Should -Be 2
        @($result.acceptedDestinations).Count | Should -Be 0
        @($result.acceptedAttachments).Count | Should -Be 0
        $storedRaw = [IO.File]::ReadAllBytes((Join-Path $script:fixture.root 'pages/101/storage.xml'))
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($storedRaw)).ToLowerInvariant() | Should -BeExactly $rawHash
        [IO.File]::ReadAllBytes((Join-Path $script:fixture.root 'pages/101/candidate.md')).Length | Should -Be 0
        $resultAfterRecapture = Invoke-ImportFixture $script:fixture $script:fixture.review
        ($resultAfterRecapture | ConvertTo-Json -Depth 12 -Compress) | Should -BeExactly ($result | ConvertTo-Json -Depth 12 -Compress)
    }

    It 'InterT71_blocks_a_complete_legacy_deep_capture_without_rewriting_its_evidence' {
        $storage = ('<strong>' * 129) + 'deep reviewed source' + ('</strong>' * 129)
        $rawBytes = [Text.UTF8Encoding]::new($false).GetBytes($storage)
        $rawHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rawBytes)).ToLowerInvariant()

        # Legacy fixture was projected by the pre-depth-guard reader in base fcf6ac5:
        # one supported strong block and its then-candidate consisted of one newline.
        $legacyBlock = [ordered]@{
            id='BLOCK-417378b4c77754a4fb49';location='/root[1]/strong[1]'
            sourceSha256=$rawHash;sourceType='strong';supported=$true
        }
        $legacyCandidate = [Text.UTF8Encoding]::new($false).GetBytes("`n")
        $capture = Get-Content -LiteralPath $script:fixture.capturePath -Raw | ConvertFrom-Json -AsHashtable
        $capture.status = 'complete'
        $capture.reasonCodes = @()
        $page = $capture.pages[0]
        $page.bodySha256 = $rawHash
        $page.projectionStatus = 'supported'
        $page.sourceBlocks = @($legacyBlock)
        $page.unsupported = @()
        [IO.File]::WriteAllBytes((Join-Path $script:fixture.root 'pages/101/storage.xml'), $rawBytes)
        [IO.File]::WriteAllBytes((Join-Path $script:fixture.root 'pages/101/candidate.md'), $legacyCandidate)
        [IO.File]::WriteAllText($script:fixture.capturePath, ($capture | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
        $script:fixture.review.dispositions = @([ordered]@{
            blockId=$legacyBlock.id;sourceSha256=$legacyBlock.sourceSha256;location=$legacyBlock.location
            status='accepted';ready=$true;destinations=@(@{sourceArtifact='docs/accepted.md';sourceSectionId='document';contentSha256=(Get-FileHash -LiteralPath (Join-Path $script:fixture.root 'docs/accepted.md') -Algorithm SHA256).Hash.ToLowerInvariant()})
            reason='Accepted by the review that accompanied the legacy capture'
        })

        $result = Invoke-ImportFixture $script:fixture $script:fixture.review

        $result.status | Should -BeExactly 'blocked'
        @($result.reasonCodes) | Should -Contain 'CaptureSourceChanged'
        @($result.acceptedDestinations).Count | Should -Be 0
        $storedRaw = [IO.File]::ReadAllBytes((Join-Path $script:fixture.root 'pages/101/storage.xml'))
        $storedCandidate = [IO.File]::ReadAllBytes((Join-Path $script:fixture.root 'pages/101/candidate.md'))
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($storedRaw)).ToLowerInvariant() | Should -BeExactly $rawHash
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($storedCandidate)).ToLowerInvariant() | Should -BeExactly ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($legacyCandidate)).ToLowerInvariant())
    }

    # Scenario: A complete header is paired with a real unsupported storage macro and a disposition that accepts it.
    # Purpose: Import review must preserve the capture's source support boundary and never expose the unsupported block as a ready destination.
    It 'InterT72_does_not_promote_a_real_unsupported_source_block_from_a_complete_header' {
        Import-Module -Name $projectionModule -Force
        $storage = '<p>Supported source</p><ac:structured-macro ac:name="unsupported-macro"><ac:parameter ac:name="format">raw source marker</ac:parameter></ac:structured-macro>'
        $rawBytes = [Text.UTF8Encoding]::new($false).GetBytes($storage)
        $rawHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rawBytes)).ToLowerInvariant()
        $projection = ConvertFrom-ConfluenceStorage -Storage $storage -PageId '101' -PageVersion 3
        $projection.status | Should -BeExactly 'unsupported'
        @($projection.sourceBlocks | Where-Object { -not $_.supported }).Count | Should -Be 1
        @($projection.unsupported | Where-Object code -CEQ 'UnsupportedMacro').Count | Should -Be 1

        $capture = Get-Content -LiteralPath $script:fixture.capturePath -Raw | ConvertFrom-Json -AsHashtable
        $capture.status = 'complete'
        $capture.reasonCodes = @()
        $capture.incompletePageIds = @()
        $page = $capture.pages[0]
        $page.bodySha256 = $rawHash
        $page.projectionStatus = $projection.status
        $page.sourceBlocks = @($projection.sourceBlocks | ForEach-Object { [ordered]@{
            id=$_.id;location=$_.location;sourceSha256=$_.sourceSha256;sourceType=$_.sourceType;supported=$_.supported
        } })
        $page.unsupported = @($projection.unsupported | ForEach-Object { [ordered]@{
            code=$_.code;location=$_.location;sourceSha256=$_.sourceSha256
        } })
        $candidateBytes = [Text.UTF8Encoding]::new($false).GetBytes($projection.markdown)
        [IO.File]::WriteAllBytes((Join-Path $script:fixture.root 'pages/101/storage.xml'), $rawBytes)
        [IO.File]::WriteAllBytes((Join-Path $script:fixture.root 'pages/101/candidate.md'), $candidateBytes)
        [IO.File]::WriteAllText($script:fixture.capturePath, ($capture | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))

        $destinationHash = (Get-FileHash -LiteralPath (Join-Path $script:fixture.root 'docs/accepted.md') -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:fixture.review.dispositions = @($projection.sourceBlocks | ForEach-Object { [ordered]@{
            blockId=$_.id;sourceSha256=$_.sourceSha256;location=$_.location;status='accepted';ready=$true
            destinations=@(@{sourceArtifact='docs/accepted.md';sourceSectionId='document';contentSha256=$destinationHash})
            reason='Accepted by the review accompanying the capture'
        } })

        $result = Invoke-ImportFixture $script:fixture $script:fixture.review

        $result.status | Should -BeExactly 'blocked'
        @($result.reasonCodes) | Should -Contain 'CaptureIncomplete'
        $unsupportedId = [string]($projection.sourceBlocks | Where-Object { -not $_.supported } | Select-Object -First 1 -ExpandProperty id)
        @($result.acceptedDestinations | Where-Object { $_.blockId -ceq $unsupportedId }).Count | Should -Be 0
        $storedRaw = [IO.File]::ReadAllBytes((Join-Path $script:fixture.root 'pages/101/storage.xml'))
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($storedRaw)).ToLowerInvariant() | Should -BeExactly $rawHash
    }

    # Scenario: An honestly partial capture contains the same real unsupported storage macro, but its review marks that block accepted.
    # Purpose: Incomplete status alone must not expose an unsupported source block as an accepted destination.
    It 'InterT73_honest_partial_capture_does_not_expose_unsupported_destinations' {
        Import-Module -Name $projectionModule -Force
        $storage = '<p>Supported source</p><ac:structured-macro ac:name="unsupported-macro"><ac:parameter ac:name="format">raw source marker</ac:parameter></ac:structured-macro>'
        $rawBytes = [Text.UTF8Encoding]::new($false).GetBytes($storage)
        $rawHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rawBytes)).ToLowerInvariant()
        $projection = ConvertFrom-ConfluenceStorage -Storage $storage -PageId '101' -PageVersion 3
        $projection.status | Should -BeExactly 'unsupported'
        @($projection.sourceBlocks | Where-Object { -not $_.supported }).Count | Should -Be 1

        $capture = Get-Content -LiteralPath $script:fixture.capturePath -Raw | ConvertFrom-Json -AsHashtable
        $capture.status = 'partial'
        $capture.reasonCodes = @('UnsupportedContent')
        $capture.incompletePageIds = @()
        $page = $capture.pages[0]
        $page.bodySha256 = $rawHash
        $page.projectionStatus = $projection.status
        $page.sourceBlocks = @($projection.sourceBlocks | ForEach-Object { [ordered]@{
            id=$_.id;location=$_.location;sourceSha256=$_.sourceSha256;sourceType=$_.sourceType;supported=$_.supported
        } })
        $page.unsupported = @($projection.unsupported | ForEach-Object { [ordered]@{
            code=$_.code;location=$_.location;sourceSha256=$_.sourceSha256
        } })
        [IO.File]::WriteAllBytes((Join-Path $script:fixture.root 'pages/101/storage.xml'), $rawBytes)
        [IO.File]::WriteAllBytes((Join-Path $script:fixture.root 'pages/101/candidate.md'), [Text.UTF8Encoding]::new($false).GetBytes($projection.markdown))
        [IO.File]::WriteAllText($script:fixture.capturePath, ($capture | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))

        $destinationHash = (Get-FileHash -LiteralPath (Join-Path $script:fixture.root 'docs/accepted.md') -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:fixture.review.dispositions = @($projection.sourceBlocks | ForEach-Object { [ordered]@{
            blockId=$_.id;sourceSha256=$_.sourceSha256;location=$_.location;status='accepted';ready=$true
            destinations=@(@{sourceArtifact='docs/accepted.md';sourceSectionId='document';contentSha256=$destinationHash})
            reason='Accepted by the review accompanying the capture'
        } })

        $result = Invoke-ImportFixture $script:fixture $script:fixture.review

        $result.status | Should -BeExactly 'blocked'
        @($result.reasonCodes) | Should -Contain 'CaptureIncomplete'
        @($result.reasonCodes) | Should -Contain 'UnsupportedSourceDispositionForbidden'
        $result.nonReadyCount | Should -Be 1
        $unsupportedId = [string]($projection.sourceBlocks | Where-Object { -not $_.supported } | Select-Object -First 1 -ExpandProperty id)
        @($result.acceptedDestinations | Where-Object { $_.blockId -ceq $unsupportedId }).Count | Should -Be 0
        $storedRaw = [IO.File]::ReadAllBytes((Join-Path $script:fixture.root 'pages/101/storage.xml'))
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($storedRaw)).ToLowerInvariant() | Should -BeExactly $rawHash
    }
}
