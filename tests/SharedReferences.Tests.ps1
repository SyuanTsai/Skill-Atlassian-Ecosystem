# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Atlassian shared-reference snapshot check' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:CheckPath = Join-Path $script:RepositoryRoot 'scripts/Test-AtlassianSharedReferences.ps1'
        $script:Mappings = @(
            [pscustomobject]@{ Source = 'docs/shared-references/configure-api-access/manual-persistence-linux-macos.md'; Destinations = @('skills/configure-bitbucket-api-access/references/manual-persistence-linux-macos.md', 'skills/configure-confluence-api-access/references/manual-persistence-linux-macos.md', 'skills/configure-jira-api-access/references/manual-persistence-linux-macos.md') }
            [pscustomobject]@{ Source = 'docs/shared-references/configure-api-access/shared-workflow.md'; Destinations = @('skills/configure-bitbucket-api-access/references/shared-workflow.md', 'skills/configure-confluence-api-access/references/shared-workflow.md', 'skills/configure-jira-api-access/references/shared-workflow.md') }
            [pscustomobject]@{ Source = 'docs/shared-references/environment-separation/environment-separation.md'; Destinations = @('skills/configure-bitbucket-api-access/references/environment-separation.md', 'skills/configure-confluence-api-access/references/environment-separation.md', 'skills/configure-jira-api-access/references/environment-separation.md', 'skills/manage-confluence-docs-as-code/references/environment-separation.md', 'skills/publish-requirements-to-confluence/references/environment-separation.md', 'skills/work-with-jira/references/environment-separation.md') }
        )
        function New-SharedReferenceFixture {
            $root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
            foreach ($mapping in $script:Mappings) {
                foreach ($relative in @($mapping.Source) + @($mapping.Destinations)) {
                    $target = Join-Path $root $relative
                    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force)
                    Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $relative) -Destination $target
                }
            }
            $root
        }
        function Get-FixtureRows {
            param([Parameter(Mandatory)][string] $Root)
            @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | ForEach-Object {
                    [IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/') + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                } | Sort-Object -CaseSensitive)
        }
    }

    It 'passes without repository metadata and does not mutate the snapshot' {
        $fixture = New-SharedReferenceFixture
        Test-Path -LiteralPath (Join-Path $fixture '.git') | Should -BeFalse
        $before = Get-FixtureRows -Root $fixture
        $result = (@(& $script:CheckPath -RepositoryRoot $fixture -ReadOnlySnapshot) -join "`n") | ConvertFrom-Json
        $result.result | Should -BeExactly 'passed'
        $after = Get-FixtureRows -Root $fixture
        ($after -join "`n") | Should -BeExactly ($before -join "`n")
    }

    It 'rejects changed destination bytes' {
        $fixture = New-SharedReferenceFixture
        $path = Join-Path $fixture 'skills/configure-bitbucket-api-access/references/shared-workflow.md'
        [IO.File]::AppendAllText($path, "changed`n", [Text.UTF8Encoding]::new($false))
        { & $script:CheckPath -RepositoryRoot $fixture -ReadOnlySnapshot } | Should -Throw '*bytes differ*'
    }

    It 'rejects a missing mapped file' {
        $fixture = New-SharedReferenceFixture
        Remove-Item -LiteralPath (Join-Path $fixture 'skills/work-with-jira/references/environment-separation.md')
        { & $script:CheckPath -RepositoryRoot $fixture -ReadOnlySnapshot } | Should -Throw
    }

    It 'requires the private MCP-only environment to stop instead of using a token' {
        $environmentReference = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'docs/shared-references/environment-separation/environment-separation.md') -Raw
        $jiraSkill = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'skills/work-with-jira/SKILL.md') -Raw

        $environmentReference | Should -Match ([regex]::Escape('If the private environment is configured for MCP only, an MCP failure stops the operation and must not fall back to an API token or another connection.'))
        $jiraSkill | Should -Match ([regex]::Escape("If the resolved environment's required connection method fails, stop and report it; do not fall back to an API token, MCP, Rovo, or another method."))
    }

    It 'requires the work token-only environment to stop instead of using MCP' {
        $environmentReference = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'docs/shared-references/environment-separation/environment-separation.md') -Raw
        $jiraSkill = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'skills/work-with-jira/SKILL.md') -Raw

        $environmentReference | Should -Match ([regex]::Escape('If the work environment is configured for API token only, a token failure stops the operation and must not fall back to MCP or another connection.'))
        $jiraSkill | Should -Match ([regex]::Escape("If the resolved environment's required connection method fails, stop and report it; do not fall back to an API token, MCP, Rovo, or another method."))
    }

    It 'stops when environment signals conflict' {
        $environmentReference = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'docs/shared-references/environment-separation/environment-separation.md') -Raw

        $environmentReference | Should -Match 'signals indicate different environments, stop and ask'
        $environmentReference | Should -Match 'instead of choosing one'
    }

    It 'keeps real prefix to environment mappings out of Skills and shared references' {
        $roots = @(
            Join-Path $script:RepositoryRoot 'skills'
            Join-Path $script:RepositoryRoot 'docs/shared-references'
        )
        $content = @(Get-ChildItem -LiteralPath $roots -File -Recurse -Force | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join [char]10
        $mappingPattern = '(?im)^\s*(?:[-*+]\s+)?(?:\|\s*)?["'']?(?!<)[A-Z][A-Z0-9]{1,9}-?["'']?\s*(?:\|\s*|=>|->|=|→|:)\s*["'']?(?:private|work) environment\b["'']?(?:\s*\|)?'
        $positiveExamples = @(
            '- ZZQ: work environment'
            '"ZZQ": "work environment"'
            "'ZZQ': 'private environment'"
            'ZZQ => private environment'
            'ZZQ -> work environment'
            'ZZQ = private environment'
            '| ZZQ | work environment |'
        )
        $negativeExamples = @(
            'The ZZQ work environment is documented.'
            '- Use ZZQ in the work environment.'
            'ZZQ requires work environment review.'
            '<ZZQ>: work environment'
        )

        foreach ($example in $positiveExamples) {
            $example | Should -Match $mappingPattern
        }
        foreach ($example in $negativeExamples) {
            $example | Should -Not -Match $mappingPattern
        }
        $content | Should -Not -Match $mappingPattern
    }

    It 'loads resolvable environment separation references before access in all six Skills' {
        $skillIds = @(
            'configure-bitbucket-api-access'
            'configure-confluence-api-access'
            'configure-jira-api-access'
            'manage-confluence-docs-as-code'
            'publish-requirements-to-confluence'
            'work-with-jira'
        )

        foreach ($skillId in $skillIds) {
            $skillRoot = Join-Path $script:RepositoryRoot "skills/$skillId"
            $skill = Get-Content -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Raw
            $skill | Should -Match 'Before any .+ access, load \[references/environment-separation\.md\]\(references/environment-separation\.md\)'
            Test-Path -LiteralPath (Join-Path $skillRoot 'references/environment-separation.md') -PathType Leaf | Should -BeTrue
        }
    }
}
