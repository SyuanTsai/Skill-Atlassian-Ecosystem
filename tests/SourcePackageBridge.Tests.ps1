# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Consumer package layout' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:Catalog = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/source.json') | ConvertFrom-Json
    }

    It 'uses only the canonical skills root' {
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot 'skills') -PathType Container | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.agents/skills') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/skills-catalog.json') | Should -BeFalse
    }

    It 'matches catalog IDs to package directories in ordinal order' {
        [string[]]$actual = @(Get-ChildItem -LiteralPath (Join-Path $script:RepositoryRoot 'skills') -Directory -Force | ForEach-Object Name)
        [Array]::Sort($actual, [StringComparer]::Ordinal)
        ($actual -join "`n") | Should -BeExactly (@($script:Catalog.skills) -join "`n")
    }

    It 'contains only consumer configuration and no legacy tuple basenames' {
        $configNames = @(Get-ChildItem -LiteralPath (Join-Path $script:RepositoryRoot 'config') -File -Force | ForEach-Object Name)
        $configNames | Should -Contain 'authority-pin.json'
        $configNames | Should -Contain 'consumer-gate.json'
        $configNames | Should -Not -Contain 'standard-v1.json'
        $configNames | Should -Not -Contain 'pester-6.2.0-closure.lock.json'
        $scriptNames = @(Get-ChildItem -LiteralPath (Join-Path $script:RepositoryRoot 'scripts') -File -Force | ForEach-Object Name)
        $scriptNames | Should -Not -Contain 'Validate.ps1'
    }
}
