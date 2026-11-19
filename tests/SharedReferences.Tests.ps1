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
}
