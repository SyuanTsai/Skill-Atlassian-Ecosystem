# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
$modulePath=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceValidation.psm1'
$testEntry=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/Test-ConfluenceDocs.ps1'
$pushEntry=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/Push-ConfluenceDocs.ps1'
$nativeFixture=Join-Path $PSScriptRoot 'fixtures/syp171-import/native'
$runtime=if([string]::IsNullOrWhiteSpace($env:SYP171_RUNTIME_ROOT)){
    Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts'
}else{$env:SYP171_RUNTIME_ROOT}
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
    param($Fixture)
    if(-not(Test-Path -LiteralPath $modulePath)){throw 'Validation module missing.'}
    Import-Module -Name $modulePath -Force
    return Invoke-ConfluenceValidation -Root $Fixture.root -MappingPath (Join-Path $Fixture.root 'mapping.json') -DocsCommit $Fixture.commit -CodeBindingPath (Join-Path $Fixture.root 'binding.json') -ReviewPath (Join-Path $Fixture.root 'review-dossier.json') -RuntimeRoot $runtime
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

}

Describe 'SYP-171 same-native-source validation' {
    BeforeEach{$script:fixture=New-ValidationFixture}
    AfterEach{Remove-ValidationFixture -Root $script:fixture.root}

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
