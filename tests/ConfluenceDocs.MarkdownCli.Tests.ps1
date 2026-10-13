# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference='Stop'
    $repositoryRoot=Split-Path -Parent $PSScriptRoot
    $testEntry=Join-Path $repositoryRoot 'skills/manage-confluence-docs-as-code/scripts/Test-ConfluenceDocs.ps1'
    $site='https://example.atlassian.net'
    $cloud='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'

    function New-MarkdownCliFixture {
        param([string]$SourceMode='git-markdown',[string]$ContentKind='general',[switch]$StaleCodeReview,[switch]$StaleCodeSource,[switch]$UnrelatedCodeChange)
        $root=Join-Path ([IO.Path]::GetTempPath()) ('syp171-markdown-cli-'+[Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'docs') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root '.confluence') -Force | Out-Null
        if($ContentKind -ceq 'code-current'){New-Item -ItemType Directory -Path (Join-Path $root 'src') -Force|Out-Null;[IO.File]::WriteAllText((Join-Path $root 'src/app.ps1'),'Get-Date',[Text.UTF8Encoding]::new($false))}
        [IO.File]::WriteAllText((Join-Path $root 'docs/general.md'),"# Overview`n`nOrdinary **Markdown**.",[Text.UTF8Encoding]::new($false))
        $mapping=[ordered]@{
            schemaVersion=4;adapter=@{id='powershell-markdown';version='1'};siteOrigin=$site;cloudId=$cloud;sourceMode=$SourceMode
            entries=@(@{projectionId='general-doc';sourceArtifact='docs/general.md';sourceSectionId='document';pageId='101';spaceId='55';parentId='99';parentProjectionId='';title='General';assets=@();linkBindings=@();contentKind=$ContentKind})
        }
        $mappingPath=Join-Path $root '.confluence/mapping.json'
        [IO.File]::WriteAllText($mappingPath,($mapping|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        & git -C $root init --quiet | Out-Null
        & git -C $root config user.name 'SYP-171 Markdown CLI fixture' | Out-Null
        & git -C $root config user.email 'fixture@example.invalid' | Out-Null
        & git -C $root config core.autocrlf false | Out-Null
        & git -C $root add -- docs/general.md .confluence/mapping.json | Out-Null
        if($ContentKind -ceq 'code-current'){& git -C $root add -- src/app.ps1 | Out-Null}
        & git -C $root commit --quiet -m 'Fixture plain Markdown mapping' | Out-Null
        $commit=(& git -C $root rev-parse HEAD).Trim()
        $codeBindingPath='';$codeReviewPath=''
        if($ContentKind -ceq 'code-current'){
            if($UnrelatedCodeChange){
                [IO.File]::WriteAllText((Join-Path $root 'src/unrelated.ps1'),'Write-Output unrelated',[Text.UTF8Encoding]::new($false))
                & git -C $root add -- src/unrelated.ps1 | Out-Null
                & git -C $root commit --quiet -m 'Fixture unrelated code change' | Out-Null
            }
            if($StaleCodeSource){
                [IO.File]::WriteAllText((Join-Path $root 'src/app.ps1'),'Write-Output changed',[Text.UTF8Encoding]::new($false))
                & git -C $root add -- src/app.ps1 | Out-Null
                & git -C $root commit --quiet -m 'Fixture related code change' | Out-Null
            }
            $codeBindingPath=Join-Path $root '.confluence/code-binding.json';$codeReviewPath=Join-Path $root '.confluence/code-review.json'
            $binding=[ordered]@{
                schemaVersion=2;targetKind='current';
                docs=@{repositoryPath='.';commit=$commit;sourcePaths=@('docs/general.md','.confluence/mapping.json')};
                code=@{repositoryPath='.';commit=$commit;relevantPaths=@('src/app.ps1')}
            }
            [IO.File]::WriteAllText($codeBindingPath,($binding|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
            $bindingHash=(Get-FileHash -LiteralPath $codeBindingPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $reviewCommit=if($StaleCodeReview){'0000000000000000000000000000000000000000'}else{$commit}
            $review=[ordered]@{schemaVersion=1;outcome='still-correct';docsCommit=$commit;codeCommit=$reviewCommit;bindingSha256=$bindingHash;evidencePaths=@('src/app.ps1')}
            [IO.File]::WriteAllText($codeReviewPath,($review|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        }
        return [pscustomobject]@{root=$root;mappingPath=$mappingPath;commit=$commit;codeBindingPath=$codeBindingPath;codeReviewPath=$codeReviewPath}
    }

    function Remove-MarkdownCliFixture {
        param([Parameter(Mandatory)][string]$Root)
        $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
        $expectedParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
        if([IO.Path]::GetDirectoryName($resolved).TrimEnd('\','/') -cne $expectedParent -or
            [IO.Path]::GetFileName($resolved) -cnotmatch '^syp171-markdown-cli-[a-f0-9]{32}$'){throw 'Unsafe Markdown CLI fixture cleanup target.'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }

    function Reset-MarkdownCliFixture {
        param([string]$SourceMode='git-markdown',[string]$ContentKind='general',[switch]$StaleCodeReview,[switch]$StaleCodeSource,[switch]$UnrelatedCodeChange)
        if($null -ne $script:fixture -and -not [string]::IsNullOrWhiteSpace([string]$script:fixture.root)){
            Remove-MarkdownCliFixture -Root ([string]$script:fixture.root)
        }
        $script:fixture=New-MarkdownCliFixture -SourceMode $SourceMode -ContentKind $ContentKind -StaleCodeReview:$StaleCodeReview -StaleCodeSource:$StaleCodeSource -UnrelatedCodeChange:$UnrelatedCodeChange
    }

    function Invoke-PublicMarkdownTest {
        param([Parameter(Mandatory)]$Fixture)
        $arguments=@{Root=$Fixture.root;MappingPath=$Fixture.mappingPath;DocsCommit=$Fixture.commit}
        if($Fixture.codeBindingPath){$arguments.CodeBindingPath=$Fixture.codeBindingPath}
        if($Fixture.codeReviewPath){$arguments.CodeReviewPath=$Fixture.codeReviewPath}
        $raw=& $testEntry @arguments
        return $raw|ConvertFrom-Json -ErrorAction Stop
    }
}

Describe 'SYP-171 public Markdown Test contract' {
    BeforeEach{$script:fixture=New-MarkdownCliFixture}
    AfterEach{if($null -ne $script:fixture){Remove-MarkdownCliFixture -Root $script:fixture.root;$script:fixture=$null}}

    # Scenario: A contributor validates a committed general Markdown page without any runtime or code evidence setup.
    # Purpose: The supported entry point must validate exact Git source bytes and report a publishable projection.
    It 'InterT10_tests_plain_git_markdown_without_runtime_or_code_evidence' {
        $result=Invoke-PublicMarkdownTest -Fixture $script:fixture
        $result.status | Should -Be 'valid'
        $result.sourceMode | Should -Be 'git-markdown'
        $result.PSObject.Properties.Name | Should -Not -Contain 'scenarioIds'
        $result.PSObject.Properties.Name | Should -Not -Contain 'specCommit'
        $result.codeCommit | Should -Be ''
        $result.PSObject.Properties.Name | Should -Not -Contain 'publishEligibility'
    }

    # Scenario: A Markdown page is derived from a captured Confluence page and no import review was supplied.
    # Purpose: Capture-derived content cannot bypass the existing source and attachment disposition review.
    It 'InterT20_blocks_capture_mode_without_import_review' {
        Reset-MarkdownCliFixture -SourceMode 'capture-markdown'
        $result=Invoke-PublicMarkdownTest -Fixture $script:fixture
        $result.status | Should -Be 'blocked'
        @($result.reasonCodes) | Should -Contain 'ImportReviewRequired'
    }

    # Scenario: A Markdown page describes current code behavior but has no code binding or correctness review.
    # Purpose: Current-behavior claims remain evidence-bound while ordinary documents need no fabricated code commits.
    It 'InterT30_blocks_code_current_content_without_binding' {
        Reset-MarkdownCliFixture -ContentKind 'code-current'
        $script:fixture.codeBindingPath='';$script:fixture.codeReviewPath=''
        $result=Invoke-PublicMarkdownTest -Fixture $script:fixture
        $result.status | Should -Be 'blocked'
        @($result.reasonCodes) | Should -Contain 'CodeCurrentEvidenceRequired'
    }

    # Scenario: A Markdown page makes a current-code claim with a matching committed code binding and review.
    # Purpose: The evidence path can pass with real documentation and code commits without synthetic spec/test revisions.
    It 'InterT40_accepts_code_current_with_matching_binding_and_review' {
        Reset-MarkdownCliFixture -ContentKind 'code-current'
        $result=Invoke-PublicMarkdownTest -Fixture $script:fixture
        $result.status | Should -Be 'valid'
        $result.docsCommit | Should -Be $script:fixture.commit
        $result.codeCommit | Should -Be $script:fixture.commit
        $result.PSObject.Properties.Name | Should -Not -Contain 'specCommit'
        $result.PSObject.Properties.Name | Should -Not -Contain 'scenarioIds'
        $result.PSObject.Properties.Name | Should -Not -Contain 'publishEligibility'
    }

    # Scenario: A current-code review refers to an older code revision than the bound source.
    # Purpose: Stale evidence must be rejected rather than carried into a new projection.
    It 'InterT50_blocks_stale_code_review_revision' {
        Reset-MarkdownCliFixture -ContentKind 'code-current' -StaleCodeReview
        $result=Invoke-PublicMarkdownTest -Fixture $script:fixture
        $result.status | Should -Be 'blocked'
        @($result.reasonCodes) | Should -Contain 'CodeReviewRequired'
    }

    # Scenario: A relevant code path changes in HEAD after the code-current review was recorded.
    # Purpose: Current-code validation rejects the stale binding even when its old bytes remain available.
    It 'InterT60_blocks_a_relevant_code_change_after_review' {
        Reset-MarkdownCliFixture -ContentKind 'code-current' -StaleCodeSource
        $result=Invoke-PublicMarkdownTest -Fixture $script:fixture
        $result.status | Should -Be 'blocked'
        @($result.reasonCodes) | Should -Contain 'BoundCodeChanged'
    }

    # Scenario: An unrelated code file is added after the current-code review.
    # Purpose: Freshness checks remain limited to the bound relevant files.
    It 'InterT70_accepts_an_unrelated_code_change' {
        Reset-MarkdownCliFixture -ContentKind 'code-current' -UnrelatedCodeChange
        $result=Invoke-PublicMarkdownTest -Fixture $script:fixture
        $result.status | Should -Be 'valid'
        $result.codeCommit | Should -Be $script:fixture.commit
    }
}
