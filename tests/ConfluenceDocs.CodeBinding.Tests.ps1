# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
$modulePath=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/ConfluenceCodeBinding.psm1'

function New-CodeFixture {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('syp171-code-tests-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $root 'src') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'docs') -Force | Out-Null
    & git -C $root init --quiet | Out-Null
    & git -C $root config user.name 'SYP-171 fixture' | Out-Null
    & git -C $root config user.email 'fixture@example.invalid' | Out-Null
    [IO.File]::WriteAllText((Join-Path $root 'src/app.txt'),'baseline',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $root 'docs/current.md'),'Current behavior',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $root 'docs/spec.md'),'# Native spec',[Text.UTF8Encoding]::new($false))
    & git -C $root add -- src/app.txt docs/current.md docs/spec.md | Out-Null
    & git -C $root commit --quiet -m 'Fixture baseline' | Out-Null
    $baseline=(& git -C $root rev-parse HEAD).Trim()
    [IO.File]::WriteAllText((Join-Path $root 'src/unrelated.txt'),'irrelevant',[Text.UTF8Encoding]::new($false))
    & git -C $root add -- src/unrelated.txt | Out-Null
    & git -C $root commit --quiet -m 'Fixture unrelated code' | Out-Null
    $unrelated=(& git -C $root rev-parse HEAD).Trim()
    [IO.File]::WriteAllText((Join-Path $root 'src/app.txt'),'changed behavior',[Text.UTF8Encoding]::new($false))
    & git -C $root add -- src/app.txt | Out-Null
    & git -C $root commit --quiet -m 'Fixture relevant code' | Out-Null
    $relevant=(& git -C $root rev-parse HEAD).Trim()
    [IO.File]::WriteAllText((Join-Path $root 'leave-alone.txt'),'user work',[Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{root=$root;baseline=$baseline;unrelated=$unrelated;relevant=$relevant}
}

function Remove-CodeFixture {
    param([string] $Root)
    if (-not (Test-Path -LiteralPath $Root)) {return}
    $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if([IO.Path]::GetDirectoryName($resolved).TrimEnd('\','/') -cne $parent -or [IO.Path]::GetFileName($resolved) -cnotmatch '^syp171-code-tests-[a-f0-9]{32}$'){throw 'Unsafe code fixture delete.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

function New-BindingData {
    param($Fixture,[string]$Target)
    return [ordered]@{
        schemaVersion=1;targetKind='current'
        docs=@{repositoryPath='.';commit=$Fixture.baseline;sourcePaths=@('docs/current.md')}
        spec=@{repositoryPath='.';commit=$Fixture.baseline;sourcePaths=@('docs/spec.md')}
        code=@{repositoryPath='.';baselineCommit=$Fixture.baseline;targetCommit=$Target;relevantPaths=@('src/app.txt')}
    }
}

function Invoke-BindingFixture {
    param($Fixture,$Data,[string]$ReviewPath='')
    if(-not(Test-Path -LiteralPath $modulePath)){throw 'Code binding module missing.'}
    Import-Module -Name $modulePath -Force
    $path=Join-Path $Fixture.root 'binding.json'
    [IO.File]::WriteAllText($path,($Data|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    $args=@{Root=$Fixture.root;BindingPath=$path}
    if($ReviewPath){$args.ReviewPath=$ReviewPath}
    return Resolve-ConfluenceCodeBinding @args
}

}

Describe 'SYP-171 exact code/docs/spec binding' {
    BeforeEach {$script:fixture=New-CodeFixture}
    AfterEach {Remove-CodeFixture -Root $script:fixture.root}

    # Scenario: SYP171-SCN-005; real committed docs/spec/code and unrelated user work.
    # Purpose: Resolve exact Git objects without staging or mutating another path.
    It 'InterT10_resolves_full_git_revisions_and_preserves_unrelated_work' {
        $r=Invoke-BindingFixture $script:fixture (New-BindingData $script:fixture $script:fixture.baseline)
        $r.status | Should -Be 'valid'
        $r.docsCommit | Should -Be $script:fixture.baseline
        $r.codeCommit | Should -Be $script:fixture.baseline
        $r.sourceDigest | Should -Match '^[a-f0-9]{64}$'
        (Get-Content -LiteralPath (Join-Path $script:fixture.root 'leave-alone.txt') -Raw) | Should -Be 'user work'
        (& git -C $script:fixture.root status --short -- leave-alone.txt).Trim() | Should -Be '?? leave-alone.txt'
    }

    # Scenario: SYP171-SCN-006; relevant code changed while current docs stayed at baseline.
    # Purpose: Without this revision's review/test evidence, publication is stale.
    It 'UnitT20_blocks_relevant_code_change_without_fresh_evidence' {
        $r=Invoke-BindingFixture $script:fixture (New-BindingData $script:fixture $script:fixture.relevant)
        $r.status | Should -Be 'blocked'
        @($r.reasonCodes) | Should -Contain 'DocumentationStale'
        @($r.changedRelevantPaths) | Should -Contain 'src/app.txt'
    }

    # Scenario: SYP171-SCN-006; only an unrelated path changed.
    # Purpose: No stale assertion is made when the selected code path remains unchanged.
    It 'UnitT30_accepts_unrelated_code_diff_with_impact_record' {
        $r=Invoke-BindingFixture $script:fixture (New-BindingData $script:fixture $script:fixture.unrelated)
        $r.status | Should -Be 'valid'
        @($r.changedRelevantPaths).Count | Should -Be 0
        $r.codeCommit | Should -Be $script:fixture.unrelated
    }

    # Scenario: SYP171-SCN-006; a review belongs to a different target code revision.
    # Purpose: Old evidence cannot excuse changed current behavior.
    It 'UnitT40_rejects_review_bound_to_old_code_commit' {
        $review=Join-Path $script:fixture.root 'review.json'
        [IO.File]::WriteAllText($review,(@{schemaVersion=1;outcome='still-correct';codeCommit=$script:fixture.baseline;docsCommit=$script:fixture.baseline;specCommit=$script:fixture.baseline;sourceDigest=('a'*64);evidencePaths=@('run.txt')}|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
        $r=Invoke-BindingFixture $script:fixture (New-BindingData $script:fixture $script:fixture.relevant) $review
        @($r.reasonCodes) | Should -Contain 'DocumentationStale'
        @($r.reasonCodes) | Should -Contain 'ReviewRevisionMismatch'
    }
}
