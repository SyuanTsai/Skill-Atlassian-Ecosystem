# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Canonical Standard v1 validation adapter' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    }

    It 'UnitT10_declares_the_authority_bound_stage_order' {
        # Scenario: The canonical entry reads its immutable Standard snapshot.
        # Purpose: Prevent a local policy from reordering security and repository gates.
        $path = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        $text = Get-Content -LiteralPath $path -Raw
        $positions = @(
            $text.IndexOf('Controlled Candidate Acquisition'),
            $text.IndexOf('Integrity Verification'),
            $text.IndexOf('Package Validation'),
            $text.IndexOf('SkillSpector Static'),
            $text.IndexOf('Repository Tests'),
            $text.IndexOf('Conditional Semantic Scan')
        )
        $positions | Should -Not -Contain -1
        for ($i = 1; $i -lt $positions.Count; $i++) {
            $positions[$i] | Should -BeGreaterThan $positions[$i - 1]
        }
    }

    It 'UnitT20_requires_both_package_tools_before_static_scan' {
        # Scenario: A required package tool is missing, incomplete, or returns a failure.
        # Purpose: Block Static and candidate tests until all package evidence is complete.
        $text = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Validate.ps1') -Raw
        $skillValidatorIndex = $text.IndexOf('skill-validator')
        $skillToolsIndex = $text.IndexOf('skill-tools')
        $staticIndex = $text.IndexOf('SkillSpector Static')
        $repositoryIndex = $text.IndexOf('Repository Tests')
        $skillValidatorIndex | Should -BeGreaterThan -1
        $skillToolsIndex | Should -BeGreaterThan -1
        $staticIndex | Should -BeGreaterThan $skillToolsIndex
        $repositoryIndex | Should -BeGreaterThan $staticIndex
        $text | Should -Match 'fail[- ]closed'
        $text | Should -Match 'missing|incomplete|unparsable'
    }

    It 'UnitT30_uses_the_central_resolver_without_floating_tool_acquisition' {
        # Scenario: Canonical validation resolves formal tools at run start.
        # Purpose: Keep source, endpoint, version, and per-run identity under authority control.
        $text = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Validate.ps1') -Raw
        $text | Should -Match 'Resolve-StandardValidationTool\.ps1'
        $text | Should -Match 'latest-stable'
        $text | Should -Not -Match '(?i)skill-validator@latest|skill-tools@latest|npx\s+skill-tools|go install'
        $text | Should -Match 'freeze|frozen'
        $text | Should -Match 'receipt'
    }

    It 'UnitT40_binds_all_component_tests_to_repository_tests_stage' {
        # Scenario: Repository-specific tests are invoked after shared security gates.
        # Purpose: Preserve all API, credential, standalone, and domain safety coverage.
        $text = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Validate.ps1') -Raw
        foreach ($component in @(
            'validate-repository.ps1',
            'validate-repository-standalone.ps1',
            'validate-api-access.ps1'
        )) {
            $text | Should -Match ([regex]::Escape($component))
        }
        $static = $text.IndexOf('SkillSpector Static')
        $repository = $text.IndexOf('Repository Tests')
        $static | Should -BeGreaterThan -1
        $repository | Should -BeGreaterThan $static
    }

    It 'UnitT50_enforces_atomic_caller_output_contract' {
        # Scenario: Two callers request the same evidence path or one path already exists.
        # Purpose: Preserve existing bytes and prevent partial or competing JSON output.
        foreach ($path in @(
            (Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'),
            (Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1')
        )) {
            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
            $text = Get-Content -LiteralPath $path -Raw
            $text | Should -Match 'FileMode\]::CreateNew'
            $text | Should -Match 'FileAccess\]::Write'
            $text | Should -Match 'FileShare\]::None'
            $text | Should -Match 'try\s*\{'
            $text | Should -Match 'finally\s*\{'
            $text | Should -Match 'UTF8Encoding'
        }
    }

    It 'UnitT60_classifies_gh_publish_as_non_authoritative_without_central_extension_policy' {
        # Scenario: The authority does not declare a complete gh executable extension policy.
        # Purpose: Preserve compatibility documentation without misrepresenting it as a gate.
        $text = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Validate.ps1') -Raw
        $text | Should -Match '(?i)gh'
        $text | Should -Match '(?i)diagnostic|compatibility'
        $text | Should -Match '(?i)non[- ]authoritative|not.*canonical|not.*gate'
    }

    It 'UnitT70_preserves_nested_security_finding_identity_in_summary' {
        # Scenario: SkillSpector returns rule identity inside its nested issue object.
        # Purpose: Keep the final security summary traceable without exposing finding text or secrets.
        $text = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Validate.ps1') -Raw
        $text | Should -Match ([regex]::Escape('$issueProperty'))
        $text | Should -Match "'finding_id'"
        $text | Should -Match "'id'\)"
    }
}
