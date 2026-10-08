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
    [IO.File]::WriteAllText((Join-Path $pageFiles 'storage.xml'),$storage,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $pageFiles 'candidate.md'),$projection.markdown,[Text.UTF8Encoding]::new($false))
    $capture=[ordered]@{
        schemaVersion=1;captureId='fixture-capture';capturedAtUtc='2026-09-16T00:00:00Z'
        siteOrigin='https://example.atlassian.net';cloudId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        scope=@{kind='page';pageIds=@('101')};status='complete';reasonCodes=@();incompletePageIds=@()
        pages=@(@{pageId='101';spaceId='55';parentId='99';title='Synthetic source';version=3
            bodySha256=$projection.bodySha256;draftObservation='same-as-published'
            snapshotPath='pages/101/storage.xml';candidatePath='pages/101/candidate.md'
            projectionStatus=$projection.status;sourceBlocks=@($projection.sourceBlocks);unsupported=@();attachments=@()})
    }
    $capturePath=Join-Path $root 'capture.json'
    [IO.File]::WriteAllText($capturePath,($capture|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    $destinations=@(
        @(@{artifact='spec';sectionId='SYN-REQ-001'}),
        @(@{artifact='design';sectionId='approach'}),
        @(@{artifact='tasks';sectionId='cli'}),
        @(@{artifact='reference';sectionId='unknown-retries'}),
        @(@{artifact='reference';sectionId='operator-command'})
    )
    $dispositions=[System.Collections.Generic.List[object]]::new()
    for($i=0;$i -lt $projection.sourceBlocks.Count;$i++){
        $block=$projection.sourceBlocks[$i]
        $status=if($i -eq 3){'unknown'}elseif($i -eq 4){'retained'}else{'accepted'}
        $dispositions.Add(@{
            blockId=$block.id;sourceSha256=$block.sourceSha256;location=$block.location
            status=$status;ready=($status -eq 'accepted');destinations=@($destinations[$i]);reason=if($status -eq 'unknown'){'Outcome absent from source'}elseif($status -eq 'retained'){'Operational source, embedded instruction ignored'}else{'Confirmed source role'}
        })
    }
    $review=[ordered]@{schemaVersion=1;captureId='fixture-capture';siteOrigin='https://example.atlassian.net';dispositions=@($dispositions.ToArray())}
    return [pscustomobject]@{root=$root;capturePath=$capturePath;review=$review;blocks=@($projection.sourceBlocks)}
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
    return Test-ConfluenceImportReview -CapturePath $Fixture.capturePath -ReviewPath $path
}

}

Describe 'SYP-171 source block review coverage' {
    BeforeEach{$script:fixture=New-ImportFixture}
    AfterEach{Remove-ImportFixture -Root $script:fixture.root}

    # Scenario: SYP171-SCN-003; mixed content has a destination or retained reference for every source block.
    # Purpose: The native SDD import cannot silently lose operating or design text.
    It 'UnitT10_accepts_complete_source_block_dispositions' {
        $r=Invoke-ImportFixture $script:fixture $script:fixture.review
        $r.status | Should -Be 'valid'
        $r.sourceBlockCount | Should -Be 5
        $r.unknownCount | Should -Be 1
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
}
