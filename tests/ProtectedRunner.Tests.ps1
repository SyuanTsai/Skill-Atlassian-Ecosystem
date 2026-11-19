# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Authority-published template integrity' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    }

    It 'matches all conversion template SHA-256 identities' {
        $expected = [ordered]@{
            'scripts/Invoke-PinnedAuthority.ps1' = '2b2941066308b689140bdbd57654b5347f39933e3c91c6097ce4646709a3e76b'
            '.github/workflows/consumer-gate.yml' = 'dffbac5117290e8ca4fd1c1179355a9bae59bcc3496ce3e9413e813f88da19d5'
        }
        foreach ($entry in $expected.GetEnumerator()) {
            (Get-FileHash -LiteralPath (Join-Path $script:RepositoryRoot $entry.Key) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $entry.Value
        }
    }

    It 'always has the permanent workflow and conditionally validates transition' {
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/consumer-gate.yml') -PathType Leaf | Should -BeTrue
        $transition = Join-Path $script:RepositoryRoot '.github/workflows/consumer-gate-transition.yml'
        if (Test-Path -LiteralPath $transition -PathType Leaf) {
            (Get-FileHash -LiteralPath $transition -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly '6c78b69f413f9878d9dd73ad42b7bbe5b4442b82617649122e8e8c9bc992132f'
        }
    }
}
