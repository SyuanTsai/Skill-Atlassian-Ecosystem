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
        New-Item -ItemType Directory -Path (Join-Path $root '.confluence') -Force | Out-Null
        & git -C $root init --quiet | Out-Null
        & git -C $root config user.name 'SYP-171 fixture' | Out-Null
        & git -C $root config user.email 'fixture@example.invalid' | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'src/app.txt'),'baseline',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $root 'docs/current.md'),'Current behavior',[Text.UTF8Encoding]::new($false))
        & git -C $root add -- src/app.txt docs/current.md | Out-Null
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
        param([string]$Root)
        if (-not (Test-Path -LiteralPath $Root)) {return}
        $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
        $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
        if([IO.Path]::GetDirectoryName($resolved).TrimEnd('\','/') -cne $parent -or [IO.Path]::GetFileName($resolved) -cnotmatch '^syp171-code-tests-[a-f0-9]{32}$'){throw 'Unsafe code fixture delete.'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }

    function New-BindingData {
        param($Fixture,[string]$CodeCommit)
        return [ordered]@{
            schemaVersion=2;targetKind='current'
            docs=@{repositoryPath='.';commit=$Fixture.baseline;sourcePaths=@('docs/current.md')}
            code=@{repositoryPath='.';commit=$CodeCommit;relevantPaths=@('src/app.txt')}
        }
    }

    function Invoke-BindingFixture {
        param($Fixture,$Data,[string]$ReviewCodeCommit='')
        Import-Module -Name $modulePath -Force
        $bindingPath=Join-Path $Fixture.root '.confluence/code-binding.json'
        $reviewPath=Join-Path $Fixture.root '.confluence/code-review.json'
        [IO.File]::WriteAllText($bindingPath,($Data|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
        $bindingHash=(Get-FileHash -LiteralPath $bindingPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if([string]::IsNullOrWhiteSpace($ReviewCodeCommit)){$ReviewCodeCommit=[string]$Data.code.commit}
        $review=[ordered]@{
            schemaVersion=1;outcome='still-correct';docsCommit=[string]$Data.docs.commit;codeCommit=$ReviewCodeCommit
            bindingSha256=$bindingHash;evidencePaths=@('src/app.txt')
        }
        [IO.File]::WriteAllText($reviewPath,($review|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        return Resolve-ConfluenceMarkdownCodeBinding -Root $Fixture.root -BindingPath $bindingPath `
            -DocsCommit ([string]$Data.docs.commit) -RequiredDocsSourcePaths @('docs/current.md') -ReviewPath $reviewPath
    }
}

Describe 'SYP-171 Markdown current-code binding contract v2' {
    BeforeEach {$script:fixture=New-CodeFixture}
    AfterEach {Remove-CodeFixture -Root $script:fixture.root}

    # Scenario: A reviewer binds a Markdown statement to exact current code and docs evidence.
    # Purpose: Resolve real Git commits and accept standard nested evidence paths on Windows.
    It 'InterT10_resolves_v2_binding_and_review_from_nested_confluence_paths' {
        $r=Invoke-BindingFixture $script:fixture (New-BindingData $script:fixture $script:fixture.relevant)
        $r.status | Should -Be 'valid'
        $r.docsCommit | Should -Be $script:fixture.baseline
        $r.codeCommit | Should -Be $script:fixture.relevant
        $r.bindingSha256 | Should -Match '^[a-f0-9]{64}$'
        (Get-Content -LiteralPath (Join-Path $script:fixture.root 'leave-alone.txt') -Raw) | Should -Be 'user work'
        (& git -C $script:fixture.root status --short -- leave-alone.txt).Trim() | Should -Be '?? leave-alone.txt'
    }

    # Scenario: A relevant code path changed after its reviewed code commit.
    # Purpose: Current-behavior evidence cannot silently describe a stale relevant file.
    It 'InterT20_rejects_related_code_changes_after_the_bound_commit' {
        $r=Invoke-BindingFixture $script:fixture (New-BindingData $script:fixture $script:fixture.baseline)
        $r.status | Should -Be 'invalid'
        @($r.reasonCodes) | Should -Contain 'BoundCodeChanged'
    }

    # Scenario: HEAD changes on a relevant path while its old bytes are restored in the worktree.
    # Purpose: Both the selected code commit and current HEAD must agree on each relevant file.
    It 'InterT25_rejects_old_working_bytes_after_head_changes_the_relevant_file' {
        [IO.File]::WriteAllText((Join-Path $script:fixture.root 'src/app.txt'),'baseline',[Text.UTF8Encoding]::new($false))
        $r=Invoke-BindingFixture $script:fixture (New-BindingData $script:fixture $script:fixture.baseline)
        $r.status | Should -Be 'invalid'
        @($r.reasonCodes) | Should -Contain 'BoundCodeChanged'
    }

    # Scenario: A relevant file has an uncommitted change after a matching code review.
    # Purpose: Dirty relevant bytes cannot be silently attributed to the reviewed revision.
    It 'InterT27_rejects_a_dirty_relevant_working_file' {
        [IO.File]::WriteAllText((Join-Path $script:fixture.root 'src/app.txt'),'uncommitted change',[Text.UTF8Encoding]::new($false))
        $r=Invoke-BindingFixture $script:fixture (New-BindingData $script:fixture $script:fixture.relevant)
        $r.status | Should -Be 'invalid'
        @($r.reasonCodes) | Should -Contain 'BoundCodeChanged'
    }

    # Scenario: Only an unrelated code path changed after the reviewed commit.
    # Purpose: Current-code freshness is scoped to declared relevant files.
    It 'InterT30_accepts_unrelated_code_changes_when_relevant_files_are_unchanged' {
        & git -C $script:fixture.root checkout --quiet $script:fixture.unrelated
        $r=Invoke-BindingFixture $script:fixture (New-BindingData $script:fixture $script:fixture.baseline)
        $r.status | Should -Be 'valid'
        $r.codeCommit | Should -Be $script:fixture.baseline
    }

    # Scenario: Review evidence names a different code revision than the immutable binding.
    # Purpose: A review from an earlier version cannot authorize current claims.
    It 'InterT40_rejects_review_bound_to_an_older_code_commit' {
        $r=Invoke-BindingFixture $script:fixture (New-BindingData $script:fixture $script:fixture.relevant) $script:fixture.baseline
        $r.status | Should -Be 'invalid'
        @($r.reasonCodes) | Should -Contain 'CodeReviewRequired'
    }
}
