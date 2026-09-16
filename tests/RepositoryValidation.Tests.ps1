# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Atlassian repository validation bridge' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:Components = @(
            'tests/validate-repository.ps1',
            'tests/validate-repository-standalone.ps1',
            'tests/validate-api-access.ps1'
        )
    }

    It 'InterT10_runs_all_existing_repository_and_API_components_from_the_canonical_stage' {
        # Scenario: Package and Static gates have passed and Repository Tests begins.
        # Purpose: Preserve the three existing domain runners without moving their logic.
        $validator = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Validate.ps1') -Raw
        foreach ($component in $script:Components) {
            $validator | Should -Match ([regex]::Escape($component))
            Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $component) -PathType Leaf | Should -BeTrue
        }
    }

    It 'InterT20_marks_components_as_targeted_diagnostics_not_release_gates' {
        # Scenario: A developer invokes a legacy component directly.
        # Purpose: Make the canonical entry the only complete local/CI contract.
        $readme = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'README.md') -Raw
        foreach ($component in @('validate-repository.ps1', 'validate-repository-standalone.ps1', 'validate-api-access.ps1')) {
            $readme | Should -Match ([regex]::Escape($component))
        }
        $readme | Should -Match '(?i)canonical.*repository tests|targeted diagnostics'
        $readme | Should -Match 'scripts/Validate\.ps1'
    }
}
