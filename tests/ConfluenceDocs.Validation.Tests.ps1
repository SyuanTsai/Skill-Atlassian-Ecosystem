# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
$modulePath=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceValidation.psm1'
$runtimeModulePath=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceRuntime.psm1'
$planModulePath=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluencePlan.psm1'
$publishModulePath=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluencePublish.psm1'
$testEntry=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/Test-ConfluenceDocs.ps1'
$pushEntry=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/Push-ConfluenceDocs.ps1'
$nativeFixture=Join-Path $PSScriptRoot 'fixtures/syp171-import/native'
$runtime=if([string]::IsNullOrWhiteSpace($env:SYP171_RUNTIME_ROOT)){
    Join-Path (Split-Path -Parent $repositoryRoot) 'runtime-tools/confluence-docs-runtime-14.3.1'
}else{$env:SYP171_RUNTIME_ROOT}
$script:runtimeSnapshot=$null
$site='https://example.atlassian.net'
$cloud='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'

function New-ValidationFixture {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('syp171-validation-tests-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $nativeFixture 'openspec') -Destination $root -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $nativeFixture 'references') -Destination $root -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $nativeFixture 'pages') -Destination $root -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $nativeFixture 'capture.json') -Destination (Join-Path $root 'capture.json')
    Copy-Item -LiteralPath (Join-Path $nativeFixture 'import-review.json') -Destination (Join-Path $root 'import-review.json')
    New-Item -ItemType Directory -Path (Join-Path $root 'src') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'tests') | Out-Null
    [IO.File]::WriteAllText((Join-Path $root 'src/app.txt'),'synthetic once-after-disable behavior',[Text.UTF8Encoding]::new($false))
    $testText="# Scenario: SYN-SCN-001`nIt 'synthetic-assertion-001' { 1 | Should -Be 1 }`n"
    [IO.File]::WriteAllText((Join-Path $root 'tests/synthetic-assertion.Tests.ps1'),$testText,[Text.UTF8Encoding]::new($false))
    & git -C $root init --quiet | Out-Null
    & git -C $root config user.name 'SYP-171 validation fixture' | Out-Null
    & git -C $root config user.email 'fixture@example.invalid' | Out-Null
    & git -C $root config core.autocrlf false | Out-Null
    & git -C $root add -- openspec references src/app.txt tests/synthetic-assertion.Tests.ps1 | Out-Null
    & git -C $root commit --quiet -m 'Fixture native SDD and code' | Out-Null
    $commit=(& git -C $root rev-parse HEAD).Trim()
    $spec='openspec/changes/synthetic-retry-import/specs/synthetic-retries/spec.md'
    $mapping=@{schemaVersion=1;adapter=@{id='openspec-native';version='1.13.0'};siteOrigin=$site;cloudId=$cloud;entries=@(@{projectionId='syn-req-001';sourceArtifact=$spec;sourceSectionId='SYN-REQ-001';pageId='101';spaceId='55';parentId='99';title='Synthetic SDD';assets=@()})}
    $binding=@{schemaVersion=1;targetKind='proposed';docs=@{repositoryPath='.';commit=$commit;sourcePaths=@('references/retry-source.md')};spec=@{repositoryPath='.';commit=$commit;sourcePaths=@($spec)};code=@{repositoryPath='.';baselineCommit=$commit;targetCommit=$commit;relevantPaths=@('src/app.txt')}}
    $runPath=Join-Path $root 'run.txt'
    [IO.File]::WriteAllText($runPath,'Synthetic assertion result stored for fixture only',[Text.UTF8Encoding]::new($false))
    $runSha=(Get-FileHash -LiteralPath $runPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $evidence=@{schemaVersion=1;specCommit=$commit;codeCommit=$commit;testCommit=$commit;runId='synthetic-validation-run';cases=@(@{scenarioId='SYN-SCN-001';testId='synthetic-assertion-001';testPath='tests/synthetic-assertion.Tests.ps1';result='passed';evidencePath='run.txt';evidenceSha256=$runSha})}
    $dossier=@{schemaVersion=1;capturePath='capture.json';importReviewPath='import-review.json';codeReviewPath='';scenarioEvidencePath='scenario-evidence.json';approvalStatus='proposed';implementationStatus='proposed'}
    foreach($pair in @(@('mapping.json',$mapping),@('binding.json',$binding),@('scenario-evidence.json',$evidence),@('review-dossier.json',$dossier))){
        [IO.File]::WriteAllText((Join-Path $root $pair[0]),($pair[1]|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    }
    return [pscustomobject]@{root=$root;commit=$commit;spec=$spec}
}
function Remove-ValidationFixture {
    param([string]$Root)
    if(-not(Test-Path -LiteralPath $Root)){return}
    $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if([IO.Path]::GetDirectoryName($resolved).TrimEnd('\','/') -cne $parent -or [IO.Path]::GetFileName($resolved) -cnotmatch '^syp171-validation-tests-[a-f0-9]{32}$'){throw 'Unsafe validation fixture delete.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
function Invoke-ValidationFixture {
    param($Fixture,[string]$SelectedRuntimeRoot=$runtime)
    if(-not(Test-Path -LiteralPath $modulePath)){throw 'Validation module missing.'}
    Import-Module -Name $modulePath -Force
    return Invoke-ConfluenceValidation -Root $Fixture.root -MappingPath (Join-Path $Fixture.root 'mapping.json') -DocsCommit $Fixture.commit -CodeBindingPath (Join-Path $Fixture.root 'binding.json') -ReviewPath (Join-Path $Fixture.root 'review-dossier.json') -RuntimeRoot $SelectedRuntimeRoot
}
function Invoke-ValidationTestEntry {
    param($Fixture,[string]$RuntimeRoot)
    $raw=& $testEntry -Root $Fixture.root -MappingPath (Join-Path $Fixture.root 'mapping.json') -DocsCommit $Fixture.commit `
        -CodeBindingPath (Join-Path $Fixture.root 'binding.json') -ReviewPath (Join-Path $Fixture.root 'review-dossier.json') -RuntimeRoot $RuntimeRoot
    return $raw|ConvertFrom-Json
}
function Get-ValidationRuntimeSnapshot {
    if($null -ne $script:runtimeSnapshot){return $script:runtimeSnapshot}
    $sourceRuntime=if(-not [string]::IsNullOrWhiteSpace($env:SYP171_RUNTIME_ROOT)){
        [IO.Path]::GetFullPath($env:SYP171_RUNTIME_ROOT).TrimEnd('\','/')
    }else{
        Join-Path (Split-Path -Parent $repositoryRoot) 'runtime-tools/confluence-docs-runtime-14.3.1'
    }
    $runtimeSourceRoot=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts'
    $sourceReceiptPath="$($sourceRuntime.TrimEnd('\','/')).receipt.json"
    if(-not(Test-Path -LiteralPath $sourceRuntime -PathType Container) -or -not(Test-Path -LiteralPath $sourceReceiptPath -PathType Leaf)){
        throw 'Runtime adopter tests require an initialized SYP171_RUNTIME_ROOT with its sibling receipt.'
    }
    Import-Module -Name $runtimeModulePath -Force
    $sourceReceipt=Get-Content -LiteralPath $sourceReceiptPath -Raw|ConvertFrom-Json -AsHashtable
    $sourceReceiptHash=(Get-FileHash -LiteralPath $sourceReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $sourceCheck=Test-ConfluenceDocsRuntimeReceipt -ReceiptPath $sourceReceiptPath -ReceiptSha256 $sourceReceiptHash -RuntimeSourceRoot $runtimeSourceRoot
    if($sourceCheck.status -cne 'valid' -or [IO.Path]::GetFullPath([string]$sourceCheck.runtimeRoot).TrimEnd('\','/') -cne $sourceRuntime){
        throw 'The configured SYP171 runtime receipt is not valid for its source root.'
    }

    $tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    $ownerId=[Guid]::NewGuid().ToString('N')
    $ownedRoot=Join-Path $tempParent "syp171-runtime-adopter-tests-$ownerId"
    $runtimeCopy=Join-Path $ownedRoot 'runtime'
    New-Item -ItemType Directory -Path $ownedRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $ownedRoot '.owner'),$ownerId,[Text.UTF8Encoding]::new($false))
    try{
        Copy-Item -LiteralPath $sourceRuntime -Destination $runtimeCopy -Recurse -Force
        $receipt=New-ConfluenceDocsRuntimeReceipt -RuntimeRoot $runtimeCopy -RuntimeSourceRoot $runtimeSourceRoot `
            -NodeVersion ([string]$sourceReceipt.nodeVersion) -NpmVersion ([string]$sourceReceipt.npmVersion)
        $receiptPath="$runtimeCopy.receipt.json"
        [IO.File]::WriteAllText($receiptPath,($receipt|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        $receiptHash=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $copyCheck=Test-ConfluenceDocsRuntimeReceipt -ReceiptPath $receiptPath -ReceiptSha256 $receiptHash -RuntimeSourceRoot $runtimeSourceRoot
        if($copyCheck.status -cne 'valid' -or [IO.Path]::GetFullPath([string]$copyCheck.runtimeRoot).TrimEnd('\','/') -cne [IO.Path]::GetFullPath($runtimeCopy).TrimEnd('\','/')){
            throw 'The test-owned runtime snapshot failed receipt verification.'
        }
        $script:runtimeSnapshot=[pscustomobject]@{ownerId=$ownerId;ownedRoot=$ownedRoot;root=[IO.Path]::GetFullPath($runtimeCopy);
            receiptPath=$receiptPath;runtimeSourceRoot=$runtimeSourceRoot;nodeVersion=$receipt.nodeVersion;npmVersion=$receipt.npmVersion}
        return $script:runtimeSnapshot
    }catch{
        $ownerPath=Join-Path $ownedRoot '.owner'
        $ownedRootItem=if(Test-Path -LiteralPath $ownedRoot -PathType Container){Get-Item -LiteralPath $ownedRoot -Force}else{$null}
        $ownerItem=if(Test-Path -LiteralPath $ownerPath -PathType Leaf){Get-Item -LiteralPath $ownerPath -Force}else{$null}
        if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ownedRoot)).TrimEnd('\','/') -cne $tempParent -or
            [IO.Path]::GetFileName($ownedRoot) -cne "syp171-runtime-adopter-tests-$ownerId" -or
            $null -eq $ownedRootItem -or $null -eq $ownerItem -or
            ($ownedRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($ownerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            (Get-Content -LiteralPath $ownerPath -Raw) -cne $ownerId){
            throw 'Unsafe runtime adopter fixture cleanup target.'
        }
        $reparse=@(Get-ChildItem -LiteralPath $ownedRoot -Recurse -Force | Where-Object {($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0})
        if($reparse.Count -gt 0){throw 'Runtime adopter fixture contains a reparse point; cleanup refused.'}
        Remove-Item -LiteralPath $ownedRoot -Recurse -Force
        throw
    }
}
function Remove-ValidationRuntimeSnapshot {
    if($null -eq $script:runtimeSnapshot){return}
    $ownedRoot=[IO.Path]::GetFullPath($script:runtimeSnapshot.ownedRoot)
    $tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if([IO.Path]::GetDirectoryName($ownedRoot).TrimEnd('\','/') -cne $tempParent -or
        [IO.Path]::GetFileName($ownedRoot) -cne "syp171-runtime-adopter-tests-$($script:runtimeSnapshot.ownerId)" -or
        -not(Test-Path -LiteralPath (Join-Path $ownedRoot '.owner') -PathType Leaf) -or
        (Get-Content -LiteralPath (Join-Path $ownedRoot '.owner') -Raw -ErrorAction Stop) -cne [string]$script:runtimeSnapshot.ownerId){
        throw 'Unsafe runtime adopter fixture cleanup target.'
    }
    $rootItem=Get-Item -LiteralPath $ownedRoot -Force
    $ownerItem=Get-Item -LiteralPath (Join-Path $ownedRoot '.owner') -Force
    if(($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($ownerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){
        throw 'Runtime adopter fixture cleanup encountered a reparse point.'
    }
    $reparse=@(Get-ChildItem -LiteralPath $ownedRoot -Recurse -Force | Where-Object {($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0})
    if($reparse.Count -gt 0){throw 'Runtime adopter fixture contains a reparse point; cleanup refused.'}
    Remove-Item -LiteralPath $ownedRoot -Recurse -Force
    $script:runtimeSnapshot=$null
}
function Set-ValidationEvidenceV2 {
    param($Fixture)
    $buildPath=Join-Path $Fixture.root 'build.txt'
    $environmentPath=Join-Path $Fixture.root 'environment.txt'
    [IO.File]::WriteAllText($buildPath,"Candidate fixture build: code=$($Fixture.commit); test=$($Fixture.commit)",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($environmentPath,'Candidate fixture environment: Windows x64, PowerShell 7, isolated runner',[Text.UTF8Encoding]::new($false))
    $evidencePath=Join-Path $Fixture.root 'scenario-evidence.json'
    $evidence=Get-Content -LiteralPath $evidencePath -Raw|ConvertFrom-Json -AsHashtable
    $evidence.schemaVersion=2
    $evidence.runId='candidate-run-001'
    $evidence.build=@{id='fixture-build-001';codeCommit=$Fixture.commit;testCommit=$Fixture.commit;artifactPath='build.txt';artifactSha256=(Get-FileHash -LiteralPath $buildPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    $evidence.environment=@{id='fixture-environment-001';artifactPath='environment.txt';artifactSha256=(Get-FileHash -LiteralPath $environmentPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    [IO.File]::WriteAllText($evidencePath,($evidence|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{evidencePath=$evidencePath;buildPath=$buildPath;environmentPath=$environmentPath}
}
function New-SeparateSpecRevision {
    param($Fixture,[switch]$Different)
    $specRepo=Join-Path $Fixture.root 'spec-repo'
    $target=Join-Path $specRepo $Fixture.spec
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Fixture.root $Fixture.spec) -Destination $target
    if($Different){[IO.File]::AppendAllText($target,"`nDifferent separate spec revision`n",[Text.UTF8Encoding]::new($false))}
    & git -C $specRepo init --quiet | Out-Null
    & git -C $specRepo config user.name 'SYP-171 validation fixture' | Out-Null
    & git -C $specRepo config user.email 'fixture@example.invalid' | Out-Null
    & git -C $specRepo config core.autocrlf false | Out-Null
    & git -C $specRepo add -- $Fixture.spec | Out-Null
    & git -C $specRepo commit --quiet -m 'Fixture separate native spec' | Out-Null
    $specCommit=(& git -C $specRepo rev-parse HEAD).Trim()
    $bindingPath=Join-Path $Fixture.root 'binding.json'
    $binding=Get-Content -LiteralPath $bindingPath -Raw|ConvertFrom-Json -AsHashtable
    $binding.spec.repositoryPath='spec-repo';$binding.spec.commit=$specCommit
    [IO.File]::WriteAllText($bindingPath,($binding|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    $evidencePath=Join-Path $Fixture.root 'scenario-evidence.json'
    $evidence=Get-Content -LiteralPath $evidencePath -Raw|ConvertFrom-Json -AsHashtable
    $evidence.specCommit=$specCommit
    [IO.File]::WriteAllText($evidencePath,($evidence|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    return $specCommit
}
function Add-ValidationSpecArtifact {
    param($Fixture)
    $relative='openspec/changes/synthetic-retry-import/specs/second-retry/spec.md'
    $source=Join-Path $Fixture.root $Fixture.spec
    $target=Join-Path $Fixture.root $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    $text=Get-Content -LiteralPath $source -Raw -Encoding utf8
    $text=$text.Replace('[SYN-REQ-001]','[SYN-REQ-002]').Replace('[SYN-SCN-001]','[SYN-SCN-002]')
    [IO.File]::WriteAllText($target,$text,[Text.UTF8Encoding]::new($false))
    & git -C $Fixture.root add -- $relative | Out-Null
    & git -C $Fixture.root commit --quiet -m 'Fixture second native requirement' | Out-Null
    $commit=(& git -C $Fixture.root rev-parse HEAD).Trim()
    $bindingPath=Join-Path $Fixture.root 'binding.json'
    $binding=Get-Content -LiteralPath $bindingPath -Raw|ConvertFrom-Json -AsHashtable
    $binding.docs.commit=$commit
    $binding.spec.commit=$commit
    $binding.spec.sourcePaths=@($Fixture.spec,$relative)
    [IO.File]::WriteAllText($bindingPath,($binding|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    $evidencePath=Join-Path $Fixture.root 'scenario-evidence.json'
    $evidence=Get-Content -LiteralPath $evidencePath -Raw|ConvertFrom-Json -AsHashtable
    $evidence.specCommit=$commit
    [IO.File]::WriteAllText($evidencePath,($evidence|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $Fixture.commit=$commit
    return $relative
}

}

Describe 'SYP-171 same-native-source validation' {
    BeforeEach{$script:fixture=New-ValidationFixture}
    AfterEach{Remove-ValidationFixture -Root $script:fixture.root}
    AfterAll{Remove-ValidationRuntimeSnapshot}

    # Scenario: SYP171-SCN-016; fixture has native SDD, code and evidence but no SYP-5 bundle.
    # Purpose: Resolve exact commits and scenario IDs; mark operational files preview-only when uncommitted.
    It 'InterT10_validates_native_source_git_mapping_review_and_evidence_without_syp5' {
        $r=Invoke-ValidationFixture $script:fixture
        $r.status | Should -Be 'valid' -Because ('validation reason codes: {0}' -f ($r.reasonCodes -join ','))
        $r.docsCommit | Should -Be $script:fixture.commit
        @($r.scenarioIds) | Should -Contain 'SYN-SCN-001'
        $r.scenarioAcceptance | Should -Be 'fixture-evidence-only'
        $r.publishEligibility | Should -Be 'preview-only'
    }

    # Scenario: SYP171-SCN-008; committed native source changed in the working tree.
    # Purpose: Published projection cannot be based on bytes absent from the selected commit.
    It 'UnitT20_blocks_native_source_changed_after_git_commit' {
        [IO.File]::AppendAllText((Join-Path $script:fixture.root $script:fixture.spec),"`nUnexpected local change`n",[Text.UTF8Encoding]::new($false))
        $r=Invoke-ValidationFixture $script:fixture
        @($r.reasonCodes) | Should -Contain 'CommittedSourceChanged'
    }

    # Scenario: SYP171-SCN-005/014; the binding names a later spec commit while the validated native bytes still match the older docs commit.
    # Purpose: A real but different spec revision must not be presented as the revision used by the document projection and scenario evidence.
    It 'UnitT25_blocks_bound_spec_commit_with_different_native_bytes' {
        $specPath=Join-Path $script:fixture.root $script:fixture.spec
        $original=[IO.File]::ReadAllText($specPath,[Text.UTF8Encoding]::new($false))
        [IO.File]::AppendAllText($specPath,"`nDifferent spec revision`n",[Text.UTF8Encoding]::new($false))
        & git -C $script:fixture.root add -- $script:fixture.spec | Out-Null
        & git -C $script:fixture.root commit --quiet -m 'Fixture changed spec revision' | Out-Null
        $differentSpecCommit=(& git -C $script:fixture.root rev-parse HEAD).Trim()
        [IO.File]::WriteAllText($specPath,$original,[Text.UTF8Encoding]::new($false))
        $bindingPath=Join-Path $script:fixture.root 'binding.json'
        $binding=Get-Content -LiteralPath $bindingPath -Raw|ConvertFrom-Json -AsHashtable
        $binding.spec.commit=$differentSpecCommit
        [IO.File]::WriteAllText($bindingPath,($binding|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        $evidencePath=Join-Path $script:fixture.root 'scenario-evidence.json'
        $evidence=Get-Content -LiteralPath $evidencePath -Raw|ConvertFrom-Json -AsHashtable
        $evidence.specCommit=$differentSpecCommit
        [IO.File]::WriteAllText($evidencePath,($evidence|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $r=Invoke-ValidationFixture $script:fixture
        $r.status | Should -Be 'blocked'
        @($r.reasonCodes) | Should -Contain 'BoundSpecSourceChanged'
    }

    # Scenario: SYP171-SCN-005/014; the selected spec revision lists a reference but omits the native requirement file.
    # Purpose: A plausible spec commit must not stand in for an unlisted native SHALL/THEN source path.
    It 'UnitT26_blocks_bound_spec_without_native_requirement_path' {
        $bindingPath=Join-Path $script:fixture.root 'binding.json'
        $binding=Get-Content -LiteralPath $bindingPath -Raw|ConvertFrom-Json -AsHashtable
        $binding.spec.sourcePaths=@('references/retry-source.md')
        [IO.File]::WriteAllText($bindingPath,($binding|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        $r=Invoke-ValidationFixture $script:fixture
        $r.status | Should -Be 'blocked'
        @($r.reasonCodes) | Should -Contain 'BoundSpecSourceIncomplete'
    }

    # Scenario: SYP171-SCN-005; the native spec has a matching committed copy in a separate selected spec repository.
    # Purpose: Exact source-byte verification must support a distinct spec commit without requiring it to equal the docs commit.
    It 'InterT27_accepts_matching_native_spec_from_separate_repository' {
        $specCommit=New-SeparateSpecRevision -Fixture $script:fixture
        $r=Invoke-ValidationFixture $script:fixture
        $r.status | Should -Be 'valid'
        $r.specCommit | Should -Be $specCommit
        $r.scenarioAcceptance | Should -Be 'fixture-evidence-only'
    }

    # Scenario: SYP171-SCN-005/014; a separate spec repository commits different native requirement bytes.
    # Purpose: Distinct Git repositories do not make a mismatched spec revision acceptable for the selected document projection.
    It 'UnitT28_blocks_different_native_spec_in_separate_repository' {
        New-SeparateSpecRevision -Fixture $script:fixture -Different | Out-Null
        $r=Invoke-ValidationFixture $script:fixture
        $r.status | Should -Be 'blocked'
        @($r.reasonCodes) | Should -Contain 'BoundSpecSourceChanged'
    }

    # Scenario: SYP171-SCN-014; a scenario result belongs to another spec revision.
    # Purpose: Coverage remains a gap rather than a reported whole-spec PASS.
    It 'UnitT30_keeps_evidence_revision_gap_visible' {
        $path=Join-Path $script:fixture.root 'scenario-evidence.json'
        $e=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -AsHashtable
        $e.specCommit='f'*40
        [IO.File]::WriteAllText($path,($e|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $r=Invoke-ValidationFixture $script:fixture
        $r.scenarioAcceptance | Should -Be 'incomplete'
        @($r.coverageGaps) | Should -Contain 'SYN-SCN-001'
    }

    # Scenario: SYP171-SCN-014; code changes after the test commit, while the report names the newer code revision.
    # Purpose: A passing test file from the older program tree cannot certify coverage of the selected changed code.
    It 'UnitT33_keeps_test_commit_with_stale_relevant_code_as_coverage_gap' {
        [IO.File]::WriteAllText((Join-Path $script:fixture.root 'src/app.txt'),'different selected code behavior',[Text.UTF8Encoding]::new($false))
        & git -C $script:fixture.root add -- src/app.txt | Out-Null
        & git -C $script:fixture.root commit --quiet -m 'Fixture changed selected code' | Out-Null
        $changedCodeCommit=(& git -C $script:fixture.root rev-parse HEAD).Trim()
        $bindingPath=Join-Path $script:fixture.root 'binding.json'
        $binding=Get-Content -LiteralPath $bindingPath -Raw|ConvertFrom-Json -AsHashtable
        $binding.code.targetCommit=$changedCodeCommit
        [IO.File]::WriteAllText($bindingPath,($binding|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        $evidencePath=Join-Path $script:fixture.root 'scenario-evidence.json'
        $evidence=Get-Content -LiteralPath $evidencePath -Raw|ConvertFrom-Json -AsHashtable
        $evidence.codeCommit=$changedCodeCommit;$evidence.runId='release-run-001'
        [IO.File]::WriteAllText($evidencePath,($evidence|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $r=Invoke-ValidationFixture $script:fixture
        $r.status | Should -Be 'valid'
        $r.scenarioAcceptance | Should -Be 'incomplete'
        @($r.coverageGaps) | Should -Contain 'SYN-SCN-001'
    }

    # Scenario: SYP171-SCN-014; tests are committed later without changing selected code paths.
    # Purpose: Independent test revisions remain valid when their relevant program tree still matches codeCommit.
    It 'InterT34_accepts_later_test_commit_with_same_relevant_code' {
        [IO.File]::AppendAllText((Join-Path $script:fixture.root 'tests/synthetic-assertion.Tests.ps1'),"`n# Later test-only revision`n",[Text.UTF8Encoding]::new($false))
        & git -C $script:fixture.root add -- tests/synthetic-assertion.Tests.ps1 | Out-Null
        & git -C $script:fixture.root commit --quiet -m 'Fixture test-only revision' | Out-Null
        $testCommit=(& git -C $script:fixture.root rev-parse HEAD).Trim()
        $evidencePath=Join-Path $script:fixture.root 'scenario-evidence.json'
        $evidence=Get-Content -LiteralPath $evidencePath -Raw|ConvertFrom-Json -AsHashtable
        $evidence.testCommit=$testCommit
        [IO.File]::WriteAllText($evidencePath,($evidence|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $r=Invoke-ValidationFixture $script:fixture
        $r.status | Should -Be 'valid'
        $r.scenarioAcceptance | Should -Be 'fixture-evidence-only'
        @($r.coverageGaps).Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-014; a claimed passing run names a test revision that does not exist.
    # Purpose: A plausible SHA and non-synthetic run label cannot turn an unverified test artifact into whole-spec acceptance.
    It 'UnitT35_keeps_unresolved_test_commit_as_coverage_gap' {
        $path=Join-Path $script:fixture.root 'scenario-evidence.json'
        $e=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -AsHashtable
        $e.testCommit='f'*40;$e.runId='release-run-001'
        [IO.File]::WriteAllText($path,($e|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $r=Invoke-ValidationFixture $script:fixture
        $r.scenarioAcceptance | Should -Be 'incomplete'
        @($r.coverageGaps) | Should -Contain 'SYN-SCN-001'
    }

    # Scenario: SYP171-SCN-014; docs/spec and code/tests live in separate Git repositories.
    # Purpose: Resolve the test revision from the selected code repository rather than assuming the docs root owns it.
    It 'InterT36_resolves_test_revision_in_selected_code_repository' {
        $codeRoot=Join-Path $script:fixture.root 'code-repo'
        New-Item -ItemType Directory -Path (Join-Path $codeRoot 'src') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $codeRoot 'tests') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $codeRoot 'src/app.txt'),'separate code revision',[Text.UTF8Encoding]::new($false))
        $testText="# Scenario: SYN-SCN-001`nIt 'synthetic-assertion-001' { 1 | Should -Be 1 }`n"
        [IO.File]::WriteAllText((Join-Path $codeRoot 'tests/synthetic-assertion.Tests.ps1'),$testText,[Text.UTF8Encoding]::new($false))
        & git -C $codeRoot init --quiet | Out-Null
        & git -C $codeRoot config user.name 'SYP-171 validation fixture' | Out-Null
        & git -C $codeRoot config user.email 'fixture@example.invalid' | Out-Null
        & git -C $codeRoot config core.autocrlf false | Out-Null
        & git -C $codeRoot add -- src/app.txt tests/synthetic-assertion.Tests.ps1 | Out-Null
        & git -C $codeRoot commit --quiet -m 'Fixture separate code' | Out-Null
        $codeCommit=(& git -C $codeRoot rev-parse HEAD).Trim()
        $bindingPath=Join-Path $script:fixture.root 'binding.json'
        $binding=Get-Content -LiteralPath $bindingPath -Raw|ConvertFrom-Json -AsHashtable
        $binding.code.repositoryPath='code-repo'
        $binding.code.baselineCommit=$codeCommit;$binding.code.targetCommit=$codeCommit
        [IO.File]::WriteAllText($bindingPath,($binding|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        $evidencePath=Join-Path $script:fixture.root 'scenario-evidence.json'
        $evidence=Get-Content -LiteralPath $evidencePath -Raw|ConvertFrom-Json -AsHashtable
        $evidence.codeCommit=$codeCommit;$evidence.testCommit=$codeCommit
        [IO.File]::WriteAllText($evidencePath,($evidence|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $r=Invoke-ValidationFixture $script:fixture
        $r.status | Should -Be 'valid'
        $r.codeCommit | Should -Be $codeCommit
        $r.scenarioAcceptance | Should -Be 'fixture-evidence-only'
        @($r.coverageGaps).Count | Should -Be 0
    }

    # Scenario: SYP171-SCN-014; a passing case names a test absent from the selected test revision.
    # Purpose: A real commit alone cannot certify that an arbitrary test ID implements the native scenario.
    It 'UnitT37_keeps_unmapped_test_id_as_coverage_gap' {
        $path=Join-Path $script:fixture.root 'scenario-evidence.json'
        $e=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -AsHashtable
        $e.runId='release-run-001';$e.cases[0].testId='invented-test-name'
        [IO.File]::WriteAllText($path,($e|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $r=Invoke-ValidationFixture $script:fixture
        $r.scenarioAcceptance | Should -Be 'incomplete'
        @($r.coverageGaps) | Should -Contain 'SYN-SCN-001'
    }

    # Scenario: SYP171-SCN-014; reported passing output changes after the candidate's first validation.
    # Purpose: A stale run artifact must invalidate coverage and the digest used by an immutable plan.
    It 'UnitT38_keeps_changed_run_output_as_coverage_gap' {
        $path=Join-Path $script:fixture.root 'scenario-evidence.json'
        $e=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -AsHashtable
        $e.runId='release-run-001'
        [IO.File]::WriteAllText($path,($e|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $before=Invoke-ValidationFixture $script:fixture
        [IO.File]::AppendAllText((Join-Path $script:fixture.root 'run.txt'),"`nTampered output",[Text.UTF8Encoding]::new($false))
        $r=Invoke-ValidationFixture $script:fixture
        $r.scenarioAcceptance | Should -Be 'incomplete'
        @($r.coverageGaps) | Should -Contain 'SYN-SCN-001'
        $r.reviewDigest | Should -Not -Be $before.reviewDigest
    }

    # Scenario: SYP171-SCN-014; test file exists only as an uncommitted working-tree candidate.
    # Purpose: A test name in local bytes cannot certify the evidence's selected Git test revision.
    It 'UnitT39_keeps_uncommitted_test_file_as_coverage_gap' {
        $testPath=Join-Path $script:fixture.root 'tests/local-only.Tests.ps1'
        [IO.File]::WriteAllText($testPath,"# Scenario: SYN-SCN-001`nIt 'synthetic-assertion-001' { 1 | Should -Be 1 }`n",[Text.UTF8Encoding]::new($false))
        $path=Join-Path $script:fixture.root 'scenario-evidence.json'
        $e=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -AsHashtable
        $e.runId='release-run-001';$e.cases[0].testPath='tests/local-only.Tests.ps1'
        [IO.File]::WriteAllText($path,($e|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $r=Invoke-ValidationFixture $script:fixture
        $r.scenarioAcceptance | Should -Be 'incomplete'
        @($r.coverageGaps) | Should -Contain 'SYN-SCN-001'
    }

    # Scenario: SYP171-SCN-008; mapping points at a section absent from the native SDD.
    # Purpose: Operational metadata cannot invent requirement identity.
    It 'UnitT40_rejects_mapping_of_unknown_native_section' {
        $path=Join-Path $script:fixture.root 'mapping.json'
        $m=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -AsHashtable
        $m.entries[0].sourceSectionId='SYN-REQ-999'
        [IO.File]::WriteAllText($path,($m|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
        $r=Invoke-ValidationFixture $script:fixture
        @($r.reasonCodes) | Should -Contain 'MappingSectionUnknown'
    }

    # Scenario: SYP171-SCN-014; a non-fixture run on v1 has no build or environment provenance.
    # Purpose: A run label and hashed assertion output alone cannot report whole-spec coverage.
    It 'UnitT41_keeps_nonfixture_v1_without_build_environment_as_coverage_gap' {
        $path=Join-Path $script:fixture.root 'scenario-evidence.json'
        $e=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -AsHashtable
        $e.runId='candidate-run-001'
        [IO.File]::WriteAllText($path,($e|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $r=Invoke-ValidationFixture $script:fixture
        $r.status | Should -Be 'valid'
        $r.scenarioAcceptance | Should -Be 'incomplete'
        @($r.coverageGaps) | Should -Contain 'SYN-SCN-001'
    }

    # Scenario: SYP171-SCN-014; a versioned candidate records matching build, environment and run artifacts.
    # Purpose: Complete provenance can be reported while behavioral acceptance remains subject to runner review.
    It 'InterT42_reports_versioned_build_environment_run_provenance_only' {
        Set-ValidationEvidenceV2 $script:fixture | Out-Null
        $r=Invoke-ValidationFixture $script:fixture
        $r.status | Should -Be 'valid'
        $r.scenarioAcceptance | Should -Be 'evidence-reported-complete'
        @($r.coverageGaps).Count | Should -Be 0
        $r.publishEligibility | Should -Be 'preview-only'
    }

    # Scenario: SYP171-SCN-014; an already referenced build log changes after validation.
    # Purpose: Stale build bytes invalidate coverage and the immutable plan's review digest.
    It 'UnitT43_keeps_tampered_build_artifact_as_coverage_gap' {
        $paths=Set-ValidationEvidenceV2 $script:fixture
        $before=Invoke-ValidationFixture $script:fixture
        [IO.File]::AppendAllText($paths.buildPath,' tampered',[Text.UTF8Encoding]::new($false))
        $r=Invoke-ValidationFixture $script:fixture
        $r.scenarioAcceptance | Should -Be 'incomplete'
        @($r.coverageGaps) | Should -Contain 'SYN-SCN-001'
        $r.reviewDigest | Should -Not -Be $before.reviewDigest
    }

    # Scenario: SYP171-SCN-014; the recorded environment snapshot changes after validation.
    # Purpose: A stale environment report cannot certify the selected build/run and must change the review digest.
    It 'UnitT44_keeps_tampered_environment_artifact_as_coverage_gap' {
        $paths=Set-ValidationEvidenceV2 $script:fixture
        $before=Invoke-ValidationFixture $script:fixture
        [IO.File]::AppendAllText($paths.environmentPath,' tampered',[Text.UTF8Encoding]::new($false))
        $r=Invoke-ValidationFixture $script:fixture
        $r.scenarioAcceptance | Should -Be 'incomplete'
        @($r.coverageGaps) | Should -Contain 'SYN-SCN-001'
        $r.reviewDigest | Should -Not -Be $before.reviewDigest
    }

    # Scenario: SYP171-SCN-014; build metadata names a different code revision from the selected binding.
    # Purpose: A real artifact hash cannot override an inconsistent code/test/build revision relationship.
    It 'UnitT45_keeps_mismatched_build_code_revision_as_coverage_gap' {
        $paths=Set-ValidationEvidenceV2 $script:fixture
        $e=Get-Content -LiteralPath $paths.evidencePath -Raw|ConvertFrom-Json -AsHashtable
        $e.build.codeCommit='f'*40
        [IO.File]::WriteAllText($paths.evidencePath,($e|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
        $r=Invoke-ValidationFixture $script:fixture
        $r.scenarioAcceptance | Should -Be 'incomplete'
        @($r.coverageGaps) | Should -Contain 'SYN-SCN-001'
    }

    # Scenario: SYP171-SCN-008; a requirement ID is paired with design.md, which is also a native source path.
    # Purpose: Mapping identity must bind the section ID to the artifact that actually contains it.
    It 'UnitT46_rejects_requirement_ID_paired_with_design_artifact' {
        $path=Join-Path $script:fixture.root 'mapping.json'
        $m=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -AsHashtable
        $m.entries[0].sourceArtifact='openspec/changes/synthetic-retry-import/design.md'
        [IO.File]::WriteAllText($path,($m|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
        $r=Invoke-ValidationFixture $script:fixture
        $r.status | Should -Be 'invalid'
        @($r.reasonCodes) | Should -Contain 'MappingSectionUnknown'
    }

    # Scenario: SYP171-SCN-008; two valid spec files contain unique IDs and the mapping swaps one ID to the other path.
    # Purpose: A path from the native inventory and an ID from that inventory must not pass unless their pair exists.
    It 'UnitT47_rejects_requirement_ID_swapped_to_another_spec_path' {
        $secondSpec=Add-ValidationSpecArtifact $script:fixture
        $path=Join-Path $script:fixture.root 'mapping.json'
        $m=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -AsHashtable
        $m.entries[0].sourceArtifact=$secondSpec
        $m.entries[0].sourceSectionId='SYN-REQ-002'
        [IO.File]::WriteAllText($path,($m|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
        $correct=Invoke-ValidationFixture $script:fixture
        $correct.status | Should -Be 'valid'

        $m.entries[0].sourceArtifact=$script:fixture.spec
        [IO.File]::WriteAllText($path,($m|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
        $swapped=Invoke-ValidationFixture $script:fixture
        $swapped.status | Should -Be 'invalid'
        @($swapped.reasonCodes) | Should -Contain 'MappingSectionUnknown'
    }

    # Scenario: SYP171-SCN-016; installed-style Test entry uses the same module contract.
    # Purpose: The public script reports exact source IDs and its preview-only limitation.
    It 'InterT50_runs_fixed_Test_entry_from_committed_native_fixture' {
        $raw=& $testEntry -Root $script:fixture.root -MappingPath (Join-Path $script:fixture.root 'mapping.json') `
            -DocsCommit $script:fixture.commit -CodeBindingPath (Join-Path $script:fixture.root 'binding.json') `
            -ReviewPath (Join-Path $script:fixture.root 'review-dossier.json') -RuntimeRoot $runtime
        $r=$raw|ConvertFrom-Json
        $r.status | Should -Be 'valid'
        @($r.scenarioIds) | Should -Contain 'SYN-SCN-001'
        $r.publishEligibility | Should -Be 'preview-only'
    }

    # Scenario: SYP171-SCN-009; an unsupported fenced block is added to a valid native requirement before Push preview.
    # Purpose: Push must reject source-reader diagnostics before remote reads or creation of a publish plan.
    It 'InterT55_blocks_Push_preview_for_unsupported_native_block' {
        $oldSite=$env:CONFLUENCE_BASE_URL
        try{
            $env:CONFLUENCE_BASE_URL=$site
            $spec=Join-Path $script:fixture.root $script:fixture.spec
            $text=Get-Content -LiteralPath $spec -Raw -Encoding utf8
            $shall=[regex]::Match($text,'(?m)^.*\bSHALL\b.*$')
            $shall.Success | Should -Be $true
            $prefix=$text.Substring(0,$shall.Index+$shall.Length)
            $suffix=$text.Substring($shall.Index+$shall.Length)
            $fence='```'
            $changed=$prefix+"`n`n${fence}sql`nSELECT 1;`n$fence"+$suffix
            [IO.File]::WriteAllText($spec,$changed,[Text.UTF8Encoding]::new($false))
            & git -C $script:fixture.root add -- $script:fixture.spec | Out-Null
            & git -C $script:fixture.root commit --quiet -m 'Fixture unsupported native block' | Out-Null
            $script:fixture.commit=(& git -C $script:fixture.root rev-parse HEAD).Trim()
            $bindingPath=Join-Path $script:fixture.root 'binding.json'
            $binding=Get-Content -LiteralPath $bindingPath -Raw|ConvertFrom-Json -AsHashtable
            $binding.docs.commit=$script:fixture.commit;$binding.spec.commit=$script:fixture.commit
            [IO.File]::WriteAllText($bindingPath,($binding|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
            $evidencePath=Join-Path $script:fixture.root 'scenario-evidence.json'
            $evidence=Get-Content -LiteralPath $evidencePath -Raw|ConvertFrom-Json -AsHashtable
            $evidence.specCommit=$script:fixture.commit
            [IO.File]::WriteAllText($evidencePath,($evidence|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
            $plan=Join-Path $script:fixture.root 'unsupported-block-plan.json'
            $raw=& $pushEntry -Root $script:fixture.root -MappingPath (Join-Path $script:fixture.root 'mapping.json') `
                -DocsCommit $script:fixture.commit -CodeBindingPath (Join-Path $script:fixture.root 'binding.json') `
                -ReviewPath (Join-Path $script:fixture.root 'review-dossier.json') -RuntimeRoot $runtime -PlanPath $plan
            $r=$raw|ConvertFrom-Json
            $r.status | Should -Be 'blocked'
            @($r.reasonCodes) | Should -Contain 'UnsupportedBlockToken'
            (Test-Path -LiteralPath $plan) | Should -Be $false
        }finally{$env:CONFLUENCE_BASE_URL=$oldSite}
    }

    # Scenario: SYP171-SCN-016; the adopter Test entry receives a runtime dependency changed after receipt creation.
    # Purpose: A fixed package version cannot authorize different OpenSpec validator bytes.
    It 'InterT56_rejects_runtime_dependency_bytes_changed_without_version_change' {
        $runtimeSnapshot=Get-ValidationRuntimeSnapshot
        $cliPath=Join-Path $runtimeSnapshot.root 'node_modules/@fission-ai/openspec/bin/openspec.js'
        $packagePath=Join-Path $runtimeSnapshot.root 'node_modules/@fission-ai/openspec/package.json'
        $originalCli=[IO.File]::ReadAllBytes($cliPath)
        $originalReceipt=[IO.File]::ReadAllBytes($runtimeSnapshot.receiptPath)
        try{
            [IO.File]::AppendAllText($cliPath,"`n// test-owned bytes changed after receipt`n",[Text.UTF8Encoding]::new($false))
            (Get-Content -LiteralPath $packagePath -Raw|ConvertFrom-Json).version | Should -Be '1.13.0'
            $r=Invoke-ValidationTestEntry -Fixture $script:fixture -RuntimeRoot $runtimeSnapshot.root
            $r.status | Should -Be 'invalid'
            @($r.reasonCodes) | Should -Contain 'RuntimeClosureChanged'
        }finally{
            [IO.File]::WriteAllBytes($cliPath,$originalCli)
            [IO.File]::WriteAllBytes($runtimeSnapshot.receiptPath,$originalReceipt)
        }
    }

    # Scenario: SYP171-SCN-016; the adopter Test entry is given a valid receipt for a different requested root.
    # Purpose: A sibling receipt must stay bound to the runtime directory it attests.
    It 'InterT57_rejects_receipt_bound_to_a_different_runtime_root' {
        $runtimeSnapshot=Get-ValidationRuntimeSnapshot
        $otherRoot=Join-Path $runtimeSnapshot.ownedRoot 'different-runtime-root'
        New-Item -ItemType Directory -Path $otherRoot | Out-Null
        $otherReceipt="$otherRoot.receipt.json"
        Copy-Item -LiteralPath $runtimeSnapshot.receiptPath -Destination $otherReceipt
        $r=Invoke-ValidationTestEntry -Fixture $script:fixture -RuntimeRoot $otherRoot
        $r.status | Should -Be 'invalid'
        @($r.reasonCodes) | Should -Contain 'RuntimeReceiptInvalid'
    }

    # Scenario: SYP171-SCN-016; PATH cannot resolve Node after the adopter receipt is established.
    # Purpose: The verified runtime Node preserves the same complete fixture inventory without PATH dependence.
    It 'InterT58_uses_receipt_node_when_PATH_contains_no_node' {
        $runtimeSnapshot=Get-ValidationRuntimeSnapshot
        $baseline=Invoke-ValidationTestEntry -Fixture $script:fixture -RuntimeRoot $runtimeSnapshot.root
        $baseline.status | Should -Be 'valid'
        @($baseline.scenarioIds).Count | Should -Be 1
        @($baseline.scenarioIds) | Should -Contain 'SYN-SCN-001'
        $originalPath=$env:PATH
        try{
            $pathEntries=@($originalPath -split ';'|Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
            $withoutNode=@(foreach($entry in $pathEntries){
                $hasNode=$false
                foreach($extension in @('.exe','.cmd','.bat','.com')){
                    if(Test-Path -LiteralPath (Join-Path $entry "node$extension") -PathType Leaf){$hasNode=$true;break}
                }
                if(-not $hasNode){$entry}
            })
            $env:PATH=$withoutNode -join ';'
            (Get-Command node -CommandType Application -ErrorAction SilentlyContinue) | Should -Be $null
            $r=Invoke-ValidationTestEntry -Fixture $script:fixture -RuntimeRoot $runtimeSnapshot.root
            $r.status | Should -Be 'valid'
            $r.sourceDigest | Should -Be $baseline.sourceDigest
            @($r.scenarioIds).Count | Should -Be @($baseline.scenarioIds).Count
            @($r.scenarioIds) | Should -Contain 'SYN-SCN-001'
        }finally{$env:PATH=$originalPath}
    }

    # Scenario: SYP171-SCN-016; a test-owned runtime receipt is validly re-signed after preview with identical closure bytes.
    # Purpose: Receipt identity alone changes reviewDigest and blocks apply before HTTP, journal, sync, or plan mutation.
    It 'InterT59_blocks_preview_apply_after_receipt_identity_changes' {
        $runtimeSnapshot=Get-ValidationRuntimeSnapshot
        Import-Module -Name $runtimeModulePath -Force
        Import-Module -Name $publishModulePath -Force
        Import-Module -Name $planModulePath -Force
        $before=Invoke-ValidationTestEntry -Fixture $script:fixture -RuntimeRoot $runtimeSnapshot.root
        $before.status | Should -Be 'valid'
        @($before.scenarioIds) | Should -Contain 'SYN-SCN-001'

        $api="https://api.atlassian.com/ex/confluence/$cloud"
        $script:runtimePublishCalls=[System.Collections.Generic.List[object]]::new()
        $http={
            param($Request)
            $script:runtimePublishCalls.Add([pscustomobject]@{Method=[string]$Request.Method;Uri=[string]$Request.Uri})
            if([string]$Request.Method -cne 'GET'){throw 'Receipt identity test attempted a remote write'}
            return [pscustomobject]@{StatusCode=200;Headers=@{};Body=@{
                id='101';spaceId='55';parentId='99';title='Synthetic SDD';status='current'
                version=@{number=1};body=@{storage=@{value='<p>Before</p>'}}
            }}
        }
        $inputs=@{
            root=$script:fixture.root;mappingPath=(Join-Path $script:fixture.root 'mapping.json');docsCommit=$script:fixture.commit
            codeBindingPath=(Join-Path $script:fixture.root 'binding.json');reviewPath=(Join-Path $script:fixture.root 'review-dossier.json')
            runtimeRoot=$runtimeSnapshot.root
        }
        $payload=@([pscustomobject]@{
            projectionId='syn-req-001';pageId='101';spaceId='55';parentId='99';title='Synthetic SDD'
            bodyStorage='<p>After</p>';assetChanges=@()
        })
        $planPath=Join-Path $script:fixture.root 'runtime-receipt-plan.json'
        $preview=New-ConfluencePreviewPlan -PlanPath $planPath -Validation $before -Payloads $payload `
            -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker $http -ValidationInputs $inputs
        $preview.status | Should -Be 'preview' -Because ('preview reason codes: {0}' -f ($preview.reasonCodes -join ','))
        @($script:runtimePublishCalls|Where-Object Method -ne 'GET').Count | Should -Be 0
        $previewPlan=Get-Content -LiteralPath $planPath -Raw|ConvertFrom-Json -AsHashtable
        $previewPlan.pages[0].action | Should -Be 'update'
        $planBefore=[IO.File]::ReadAllBytes($planPath)
        $digestBefore=[IO.File]::ReadAllBytes("$planPath.sha256")
        $journalPath="$planPath.journal.json"
        $syncPath="$planPath.sync.json"
        $authPath=Join-Path $script:fixture.root 'runtime-receipt-authorization.json'
        $planDigest=(Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $authorization=[ordered]@{
            schemaVersion=1;planSha256=$planDigest;operationId=$previewPlan.operationId
            siteOrigin=$previewPlan.siteOrigin;cloudId=$previewPlan.cloudId
            approvalEvidenceRef='synthetic-test-only';approvedActions=@('update:101')
        }
        [IO.File]::WriteAllText($authPath,($authorization|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $callsBeforeApply=$script:runtimePublishCalls.Count
        $originalReceipt=[IO.File]::ReadAllBytes($runtimeSnapshot.receiptPath)
        try{
            $receipt=Get-Content -LiteralPath $runtimeSnapshot.receiptPath -Raw|ConvertFrom-Json -AsHashtable
            $receipt.createdAtUtc=([DateTimeOffset]::Parse([string]$receipt.createdAtUtc).AddSeconds(1).UtcDateTime).ToString('o')
            [IO.File]::WriteAllText($runtimeSnapshot.receiptPath,($receipt|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
            $receiptHash=(Get-FileHash -LiteralPath $runtimeSnapshot.receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $receiptCheck=Test-ConfluenceDocsRuntimeReceipt -ReceiptPath $runtimeSnapshot.receiptPath `
                -ReceiptSha256 $receiptHash -RuntimeSourceRoot $runtimeSnapshot.runtimeSourceRoot
            $receiptCheck.status | Should -Be 'valid'

            $after=Invoke-ValidationTestEntry -Fixture $script:fixture -RuntimeRoot $runtimeSnapshot.root
            $after.status | Should -Be 'valid'
            $after.sourceDigest | Should -Be $before.sourceDigest
            $after.mappingDigest | Should -Be $before.mappingDigest
            $after.docsCommit | Should -Be $before.docsCommit
            $after.specCommit | Should -Be $before.specCommit
            $after.codeCommit | Should -Be $before.codeCommit
            $after.validatorVersion | Should -Be $before.validatorVersion
            $after.rendererVersion | Should -Be $before.rendererVersion
            (@($after.scenarioIds)-join ',') | Should -Be (@($before.scenarioIds)-join ',')
            $after.reviewDigest | Should -Not -Be $before.reviewDigest

            $apply=Invoke-ConfluencePlan -PlanPath $planPath -CurrentValidation $after -AuthorizationPath $authPath `
                -JournalPath $journalPath -SyncPath $syncPath -ExpectedSiteOrigin $site -ApiBase $api -HttpInvoker $http
            $apply.status | Should -Be 'blocked'
            @($apply.reasonCodes) | Should -Contain 'ProjectionChanged'
            $script:runtimePublishCalls.Count | Should -Be $callsBeforeApply
            @($script:runtimePublishCalls|Where-Object Method -ne 'GET').Count | Should -Be 0
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($planPath)) | Should -Be ([Convert]::ToBase64String($planBefore))
            [Convert]::ToBase64String([IO.File]::ReadAllBytes("$planPath.sha256")) | Should -Be ([Convert]::ToBase64String($digestBefore))
            (Test-Path -LiteralPath $journalPath) | Should -Be $false
            (Test-Path -LiteralPath $syncPath) | Should -Be $false
            (Test-Path -LiteralPath "$journalPath.lock") | Should -Be $false
        }finally{
            [IO.File]::WriteAllBytes($runtimeSnapshot.receiptPath,$originalReceipt)
        }
    }

    # Scenario: SYP171-SCN-007; the process REST tenant is different from the mapped site.
    # Purpose: Public Push stops before HTTP or plan writes, even though offline source validation passes.
    It 'InterT60_blocks_wrong_tenant_in_fixed_Push_entry_before_HTTP' {
        $old=$env:CONFLUENCE_BASE_URL
        try{
            $env:CONFLUENCE_BASE_URL='https://wrong.atlassian.net'
            $plan=Join-Path $script:fixture.root 'plan.json'
            $raw=& $pushEntry -Root $script:fixture.root -MappingPath (Join-Path $script:fixture.root 'mapping.json') `
                -DocsCommit $script:fixture.commit -CodeBindingPath (Join-Path $script:fixture.root 'binding.json') `
                -ReviewPath (Join-Path $script:fixture.root 'review-dossier.json') -RuntimeRoot $runtime -PlanPath $plan
            $r=$raw|ConvertFrom-Json
            $r.status | Should -Be 'blocked'
            @($r.reasonCodes) | Should -Contain 'TenantMismatch'
            (Test-Path -LiteralPath $plan) | Should -Be $false
        }finally{$env:CONFLUENCE_BASE_URL=$old}
    }
}
