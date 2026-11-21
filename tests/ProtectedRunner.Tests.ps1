# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Authority-published template integrity' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    }

    It 'matches all conversion template SHA-256 identities' {
        $expected = [ordered]@{
            'scripts/Invoke-PinnedAuthority.ps1' = '4bde1cf7ca72a1a65ddc2ea30799daa3ff26deb69361406a38e1c9d4a7ae9835'
            '.github/workflows/consumer-gate.yml' = 'e67b40ac2b18f6d13aab573a17b8a55eed74df9ed41721f710bfb46a52881519'
        }
        foreach ($entry in $expected.GetEnumerator()) {
            (Get-FileHash -LiteralPath (Join-Path $script:RepositoryRoot $entry.Key) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $entry.Value
        }
    }

    It 'always has the permanent workflow and conditionally validates transition' {
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/consumer-gate.yml') -PathType Leaf | Should -BeTrue
        $transition = Join-Path $script:RepositoryRoot '.github/workflows/consumer-gate-transition.yml'
        if (Test-Path -LiteralPath $transition -PathType Leaf) {
            (Get-FileHash -LiteralPath $transition -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly '61032baf65fd52829e327470253df22d9a832986c6efdbfb3da9d8f7bba4ffac'
        }
    }
}
