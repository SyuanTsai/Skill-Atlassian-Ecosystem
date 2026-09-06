# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Atlassian repository validation bridge' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:RepositoryValidator = Join-Path $script:RepositoryRoot 'tests/validate-repository.ps1'
        $script:StandaloneValidator = Join-Path $script:RepositoryRoot 'tests/validate-repository-standalone.ps1'
        $script:ApiValidator = Join-Path $script:RepositoryRoot 'tests/validate-api-access.ps1'
    }

    It 'InterT10_runs the existing repository contract validator' {
        # Scenario: The canonical Pester run reaches the legacy repository contract checks.
        # Purpose: Preserve licensing, metadata, Skill boundary, and PowerShell parse coverage.
        { & $script:RepositoryValidator } | Should -Not -Throw
        $LASTEXITCODE | Should -Be 0
    }

    It 'InterT20_runs standalone export validation' {
        # Scenario: A source repository is exported without Git metadata under LF and CRLF.
        # Purpose: Preserve the distribution/standalone contract in the single canonical gate.
        { & $script:StandaloneValidator } | Should -Not -Throw
        $LASTEXITCODE | Should -Be 0
    }

    It 'InterT30_runs all offline API credential and access-path checks' {
        # Scenario: The configured Atlassian access helpers are exercised with offline fixtures.
        # Purpose: Keep secret redaction, tenant identity, scope, and failure classification covered.
        { & $script:ApiValidator } | Should -Not -Throw
        $LASTEXITCODE | Should -Be 0
    }
}
