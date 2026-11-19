# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Shrink-only SkillSpector exception set' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:Registry = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'config/skillspector-exceptions.json') | ConvertFrom-Json
        $script:Baseline = Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot 'config/skillspector-exceptions/review-bitbucket-pull-request.baseline.json') | ConvertFrom-Json
    }

    It 'contains one review baseline and exactly three review exceptions' {
        @($script:Registry.baselines) | Should -HaveCount 1
        $script:Registry.baselines[0].skillId | Should -BeExactly 'review-bitbucket-pull-request'
        @($script:Registry.exceptions) | Should -HaveCount 3
        @($script:Registry.exceptions | Where-Object skillId -CNE 'review-bitbucket-pull-request') | Should -HaveCount 0
        @($script:Registry.exceptions | Where-Object ruleId -CEQ 'LP3') | Should -HaveCount 1
        @($script:Registry.exceptions | Where-Object ruleId -CEQ 'E1') | Should -HaveCount 2
    }

    It 'keeps registry fingerprints in one-to-one correspondence with the baseline' {
        @($script:Baseline.fingerprints) | Should -HaveCount 3
        $registryHashes = @($script:Registry.exceptions.fingerprint)
        $baselineHashes = @($script:Baseline.fingerprints.hash)
        [Array]::Sort($registryHashes, [StringComparer]::Ordinal)
        [Array]::Sort($baselineHashes, [StringComparer]::Ordinal)
        ($registryHashes -join "`n") | Should -BeExactly ($baselineHashes -join "`n")
    }

    It 'contains no other baseline file' {
        $files = @(Get-ChildItem -LiteralPath (Join-Path $script:RepositoryRoot 'config/skillspector-exceptions') -File -Force)
        $files | Should -HaveCount 1
        $files[0].Name | Should -BeExactly 'review-bitbucket-pull-request.baseline.json'
    }

    It 'preserves the two E1 matched texts at their approved source locations' {
        foreach ($exception in @($script:Registry.exceptions | Where-Object ruleId -CEQ 'E1')) {
            $path = Join-Path $script:RepositoryRoot ('skills/review-bitbucket-pull-request/' + [string]$exception.file)
            $line = (Get-Content -LiteralPath $path -Encoding utf8)[$exception.startLine - 1]
            $offset = [int]$exception.startColumn
            $line.Substring($offset, ([string]$exception.matchedText).Length) | Should -BeExactly ([string]$exception.matchedText)
        }
    }
}
