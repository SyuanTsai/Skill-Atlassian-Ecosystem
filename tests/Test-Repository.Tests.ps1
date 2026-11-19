# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Atlassian repository snapshot behavior' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:CheckPath = Join-Path $script:RepositoryRoot 'scripts/Test-AtlassianRepository.ps1'
        function New-AtlassianFixture {
            $root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $root -Force)
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog') -Destination $root -Recurse
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'skills') -Destination $root -Recurse
            $root
        }
        function Write-FixtureCatalog {
            param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)] $Value)
            $json = $Value | ConvertTo-Json -Depth 20
            [IO.File]::WriteAllText((Join-Path $Root 'catalog/source.json'), $json + "`n", [Text.UTF8Encoding]::new($false))
        }
        function Get-FixtureRows {
            param([Parameter(Mandatory)][string] $Root)
            @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | ForEach-Object {
                    [IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/') + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                } | Sort-Object -CaseSensitive)
        }
    }

    It 'validates a snapshot without repository metadata' {
        $fixture = New-AtlassianFixture
        Test-Path -LiteralPath (Join-Path $fixture '.git') | Should -BeFalse
        $result = (@(& $script:CheckPath -RepositoryRoot $fixture -ReadOnlySnapshot) -join "`n") | ConvertFrom-Json
        $result.result | Should -BeExactly 'passed'
        $result.activeSkillCount | Should -Be 7
    }

    It 'does not write into the candidate snapshot' {
        $fixture = New-AtlassianFixture
        $before = Get-FixtureRows -Root $fixture
        [void](@(& $script:CheckPath -RepositoryRoot $fixture -ReadOnlySnapshot))
        $after = Get-FixtureRows -Root $fixture
        ($after -join "`n") | Should -BeExactly ($before -join "`n")
    }

    It 'rejects an incorrect source identity' {
        $fixture = New-AtlassianFixture
        $catalog = Get-Content -Raw -LiteralPath (Join-Path $fixture 'catalog/source.json') | ConvertFrom-Json
        $catalog.sourceId = 'wrong-source'
        Write-FixtureCatalog -Root $fixture -Value $catalog
        { & $script:CheckPath -RepositoryRoot $fixture -ReadOnlySnapshot } | Should -Throw '*identity is invalid*'
    }

    It 'rejects duplicate Skill IDs' {
        $fixture = New-AtlassianFixture
        $catalog = Get-Content -Raw -LiteralPath (Join-Path $fixture 'catalog/source.json') | ConvertFrom-Json
        $catalog.skills = @($catalog.skills[0], $catalog.skills[0])
        Write-FixtureCatalog -Root $fixture -Value $catalog
        { & $script:CheckPath -RepositoryRoot $fixture -ReadOnlySnapshot } | Should -Throw '*Duplicate Skill ID*'
    }

    It 'rejects an undeclared package directory' {
        $fixture = New-AtlassianFixture
        [void](New-Item -ItemType Directory -Path (Join-Path $fixture 'skills/undeclared-package'))
        { & $script:CheckPath -RepositoryRoot $fixture -ReadOnlySnapshot } | Should -Throw '*inventory does not exactly match*'
    }

    It 'rejects a package missing OpenAI metadata' {
        $fixture = New-AtlassianFixture
        Remove-Item -LiteralPath (Join-Path $fixture 'skills/configure-bitbucket-api-access/agents/openai.yaml')
        { & $script:CheckPath -RepositoryRoot $fixture -ReadOnlySnapshot } | Should -Throw '*missing required metadata*'
    }

    It 'rejects an extra nested Skill publication entry' {
        $fixture = New-AtlassianFixture
        $path = Join-Path $fixture 'skills/configure-bitbucket-api-access/references/SKILL.md'
        [IO.File]::WriteAllText($path, "---`nname: unexpected`ndescription: unexpected publication`n---`nbody`n", [Text.UTF8Encoding]::new($false))
        { & $script:CheckPath -RepositoryRoot $fixture -ReadOnlySnapshot } | Should -Throw '*Publisher-discoverable Skill inventory*'
    }

    It 'rejects a root-level Skill publication entry' {
        $fixture = New-AtlassianFixture
        $path = Join-Path $fixture 'foo/SKILL.md'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force)
        [IO.File]::WriteAllText($path, "---`nname: foo`ndescription: unexpected publication`n---`nbody`n", [Text.UTF8Encoding]::new($false))
        { & $script:CheckPath -RepositoryRoot $fixture -ReadOnlySnapshot } | Should -Throw '*Publisher-discoverable Skill inventory*'
    }

    It 'rejects a plugin Skill publication entry' {
        $fixture = New-AtlassianFixture
        $path = Join-Path $fixture 'plugins/x/skills/foo/SKILL.md'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force)
        [IO.File]::WriteAllText($path, "---`nname: foo`ndescription: unexpected publication`n---`nbody`n", [Text.UTF8Encoding]::new($false))
        { & $script:CheckPath -RepositoryRoot $fixture -ReadOnlySnapshot } | Should -Throw '*Publisher-discoverable Skill inventory*'
    }

    It 'rejects a string schemaVersion' {
        $fixture = New-AtlassianFixture
        $catalog = Get-Content -Raw -LiteralPath (Join-Path $fixture 'catalog/source.json') | ConvertFrom-Json
        $catalog.schemaVersion = '2'
        Write-FixtureCatalog -Root $fixture -Value $catalog
        { & $script:CheckPath -RepositoryRoot $fixture -ReadOnlySnapshot } | Should -Throw '*schemaVersion must be integer 2*'
    }

    It 'rejects a fractional JSON representation of schemaVersion' {
        $fixture = New-AtlassianFixture
        $catalogPath = Join-Path $fixture 'catalog/source.json'
        $catalogText = Get-Content -Raw -LiteralPath $catalogPath
        $catalogText = $catalogText -creplace '"schemaVersion"\s*:\s*2', '"schemaVersion": 2.0'
        [IO.File]::WriteAllText($catalogPath, $catalogText, [Text.UTF8Encoding]::new($false))
        { & $script:CheckPath -RepositoryRoot $fixture -ReadOnlySnapshot } | Should -Throw '*schemaVersion must be integer 2*'
    }
}
