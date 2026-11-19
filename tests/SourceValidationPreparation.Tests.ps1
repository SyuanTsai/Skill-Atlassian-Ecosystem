# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Consumer configuration preparation' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:Pin = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'config/authority-pin.json') | ConvertFrom-Json
        $script:Gate = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'config/consumer-gate.json') | ConvertFrom-Json
        $script:Catalog = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/source.json') | ConvertFrom-Json
    }

    It 'uses exact top-level property sets' {
        (@($script:Pin.PSObject.Properties.Name) -join "`n") | Should -BeExactly (@('schemaVersion', 'repository', 'commit') -join "`n")
        (@($script:Gate.PSObject.Properties.Name) -join "`n") | Should -BeExactly (@('schemaVersion', 'repositoryId', 'sourceRepository', 'activeSkills', 'repositoryChecks') -join "`n")
    }

    It 'binds the consumer identity to the source catalog' {
        $script:Gate.repositoryId | Should -BeExactly 'skill-atlassian-ecosystem'
        $script:Gate.sourceRepository | Should -BeExactly ([string]$script:Catalog.repository)
        (@($script:Gate.activeSkills) -join "`n") | Should -BeExactly (@($script:Catalog.skills) -join "`n")
    }

    It 'points each declared check at an existing candidate path' {
        foreach ($check in @($script:Gate.repositoryChecks)) {
            (@($check.PSObject.Properties.Name) -join "`n") | Should -BeExactly (@('id', 'kind', 'path') -join "`n")
            Test-Path -LiteralPath (Join-Path $script:RepositoryRoot ([string]$check.path)) | Should -BeTrue
        }
    }

    It 'does not invent a requiredRepositoryChecks field' {
        @($script:Gate.PSObject.Properties.Name) | Should -Not -Contain 'requiredRepositoryChecks'
    }
}
