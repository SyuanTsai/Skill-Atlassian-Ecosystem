# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Atlassian package conformance' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:Catalog = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/source.json') | ConvertFrom-Json
    }

    It 'uses the exact source inventory contract' {
        (@($script:Catalog.PSObject.Properties.Name) -join "`n") | Should -BeExactly (@('schemaVersion', 'sourceId', 'repository', 'skillsRoot', 'skills') -join "`n")
        $script:Catalog.schemaVersion | Should -Be 2
        $script:Catalog.sourceId | Should -BeExactly 'atlassian-ecosystem'
        $script:Catalog.repository | Should -BeExactly 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git'
        $script:Catalog.skillsRoot | Should -BeExactly 'skills'
    }

    It 'keeps Skill IDs unique and ordinally sorted' {
        @($script:Catalog.skills | Select-Object -Unique) | Should -HaveCount @($script:Catalog.skills).Count
        [string[]]$sorted = @($script:Catalog.skills)
        [Array]::Sort($sorted, [StringComparer]::Ordinal)
        (@($script:Catalog.skills) -join "`n") | Should -BeExactly ($sorted -join "`n")
    }

    It 'requires Skill instructions and OpenAI metadata in every package' {
        foreach ($skillId in @($script:Catalog.skills)) {
            $root = Join-Path $script:RepositoryRoot ('skills/' + [string]$skillId)
            Test-Path -LiteralPath (Join-Path $root 'SKILL.md') -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $root 'agents/openai.yaml') -PathType Leaf | Should -BeTrue
        }
    }

    It 'binds every frontmatter name to its package ID' {
        foreach ($skillId in @($script:Catalog.skills)) {
            $text = [IO.File]::ReadAllText((Join-Path $script:RepositoryRoot ('skills/' + [string]$skillId + '/SKILL.md')), [Text.UTF8Encoding]::new($false, $true)).Replace("`r`n", "`n")
            ($text -cmatch '(?s)\A---\n(?<frontmatter>.*?)\n---\n(?<body>.*)\z') | Should -BeTrue
            $nameLines = @(([string]$Matches.frontmatter).Split("`n") | Where-Object { $_ -cmatch '^name:\s+' })
            $nameLines | Should -HaveCount 1
            $nameLines[0].Substring(5).Trim() | Should -BeExactly ([string]$skillId)
        }
    }

    It 'provides required quoted interface metadata' {
        foreach ($skillId in @($script:Catalog.skills)) {
            $text = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot ('skills/' + [string]$skillId + '/agents/openai.yaml'))
            $text | Should -Match '(?m)^interface:$'
            $text | Should -Match '(?m)^  display_name: "[^"\r\n]+"$'
            $text | Should -Match '(?m)^  short_description: "[^"\r\n]+"$'
            $text | Should -Match '(?m)^  default_prompt: "[^"\r\n]+"$'
        }
    }
}
