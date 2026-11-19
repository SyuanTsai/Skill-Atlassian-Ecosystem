# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Atlassian consumer repository contract' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:Catalog = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/source.json') | ConvertFrom-Json
        $script:Gate = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'config/consumer-gate.json') | ConvertFrom-Json
        $script:Pin = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'config/authority-pin.json') | ConvertFrom-Json
    }

    It 'publishes both snapshot-safe general check interfaces' {
        foreach ($relative in @('scripts/Test-AtlassianRepository.ps1', 'scripts/Test-AtlassianSharedReferences.ps1')) {
            $command = Get-Command -Name (Join-Path $script:RepositoryRoot $relative) -CommandType ExternalScript
            @($command.Parameters.Keys) | Should -Contain 'RepositoryRoot'
            @($command.Parameters.Keys) | Should -Contain 'ReadOnlySnapshot'
            $command.Parameters['ReadOnlySnapshot'].ParameterType | Should -Be ([switch])
        }
    }

    It 'binds active Skills exactly to the source catalog' {
        (@($script:Gate.activeSkills) -join "`n") | Should -BeExactly (@($script:Catalog.skills) -join "`n")
    }

    It 'declares exactly two general checks and the complete tests tree' {
        @($script:Gate.repositoryChecks) | Should -HaveCount 3
        (@($script:Gate.repositoryChecks.id) -join "`n") | Should -BeExactly (@('repository-atlassian', 'repository-shared-references', 'repository-pester') -join "`n")
        (@($script:Gate.repositoryChecks.kind) -join "`n") | Should -BeExactly (@('general', 'general', 'pester') -join "`n")
        (@($script:Gate.repositoryChecks.path) -join "`n") | Should -BeExactly (@('scripts/Test-AtlassianRepository.ps1', 'scripts/Test-AtlassianSharedReferences.ps1', 'tests') -join "`n")
    }

    It 'uses a replaceable immutable authority pin' {
        (@($script:Pin.PSObject.Properties.Name) -join "`n") | Should -BeExactly (@('schemaVersion', 'repository', 'commit') -join "`n")
        $script:Pin.schemaVersion | Should -Be 1
        $script:Pin.repository | Should -BeExactly 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
        $script:Pin.commit | Should -Match '^[0-9a-f]{40}$'
    }
}
