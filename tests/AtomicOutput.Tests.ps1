# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Consumer file byte contracts' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:JsonPaths = @(
            (Join-Path $script:RepositoryRoot 'config/authority-pin.json')
            (Join-Path $script:RepositoryRoot 'config/consumer-gate.json')
            (Join-Path $script:RepositoryRoot 'config/skillspector-exceptions.json')
        )
    }

    It 'stores consumer JSON as UTF-8 without BOM and with a final LF' {
        foreach ($path in $script:JsonPaths) {
            $bytes = [IO.File]::ReadAllBytes($path)
            ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) | Should -BeFalse
            $bytes[-1] | Should -Be 10
            [Text.UTF8Encoding]::new($false, $true).GetString($bytes) | Should -Not -Match "`r"
        }
    }

    It 'keeps the retained baseline byte-for-byte equal to inventory' {
        $relative = 'config/skillspector-exceptions/review-bitbucket-pull-request.baseline.json'
        $workingHash = (Get-FileHash -LiteralPath (Join-Path $script:RepositoryRoot $relative) -Algorithm SHA256).Hash.ToLowerInvariant()
        $workingHash | Should -BeExactly '342ac6369c27ba42b3b3c5a1263ed6dc16dd34f43076c377fb1cb0cc0f330327'
    }
}
