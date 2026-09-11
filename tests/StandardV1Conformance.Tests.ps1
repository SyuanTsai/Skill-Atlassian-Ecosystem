# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Atlassian Ecosystem Standard v1 conformance' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ExpectedSkills = @(
            'configure-bitbucket-api-access',
            'configure-confluence-api-access',
            'configure-jira-api-access',
            'publish-requirements-to-confluence',
            'review-bitbucket-pull-request',
            'work-with-jira'
        )
        $script:AuthorityCommit = 'd38eba3faf967504751aba759f38102e7538a519'
        $script:AuthorityArchiveSha256 = 'ca1b20dc79ae978d30cc7f400aa6ebd3dbe321e96e526cfbb2b421d6a477f38f'
    }

    It 'UnitT10_uses_schema_v2_and_the_exact_six_skill_inventory' {
        # Scenario: The source catalog is loaded by a Standard v1 validator.
        # Purpose: Bind every Atlassian package to one canonical, exact inventory.
        $sourcePath = Join-Path $script:RepositoryRoot 'catalog/source.json'
        Test-Path -LiteralPath $sourcePath -PathType Leaf | Should -BeTrue
        $source = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json -Depth 20
        @($source.PSObject.Properties.Name) | Should -Be @(
            'schemaVersion', 'sourceId', 'repository', 'skillsRoot', 'skills'
        )
        $source.schemaVersion | Should -Be 2
        $source.sourceId | Should -Be 'atlassian-ecosystem'
        $source.repository | Should -Be 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git'
        $source.skillsRoot | Should -Be 'skills'
        @($source.skills) | Should -Be $script:ExpectedSkills
    }

    It 'UnitT20_binds_the_immutable_authority_snapshot_and_required_hashes' {
        # Scenario: The repository adapter is read before validation tools are resolved.
        # Purpose: Prevent mutable authority refs, guessed archives, and incomplete evidence.
        $adapterPath = Join-Path $script:RepositoryRoot 'config/standard-v1.json'
        Test-Path -LiteralPath $adapterPath -PathType Leaf | Should -BeTrue
        $adapter = Get-Content -LiteralPath $adapterPath -Raw | ConvertFrom-Json -Depth 20
        @($adapter.PSObject.Properties.Name) | Should -Be @('schemaVersion', 'standardVersion', 'authority', 'deviations')
        $adapter.schemaVersion | Should -Be 1
        $adapter.standardVersion | Should -Be 'v1'
        $adapter.authority.repository | Should -Be 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
        $adapter.authority.commit | Should -Be $script:AuthorityCommit
        $adapter.authority.archiveUrl | Should -Be "https://codeload.github.com/SyuanTsai/SyuanTsai-AI-Instructions/zip/$($script:AuthorityCommit)"
        $adapter.authority.archiveSha256 | Should -Be $script:AuthorityArchiveSha256
        @($adapter.authority.files).Count | Should -BeGreaterThan 10
        foreach ($file in @($adapter.authority.files)) {
            $file.path | Should -Match '^[^\\\x00\r\n]+$'
            $file.sha256 | Should -Match '^[0-9a-f]{64}$'
        }
        $adapter.deviations | Should -Be 'None'
        @($adapter.PSObject.Properties.Name) | Should -Not -Contain 'security'
        @($adapter.PSObject.Properties.Name) | Should -Not -Contain 'toolchain'
    }

    It 'UnitT30_exposes_one_canonical_validator_and_keeps_domain_scripts_as_components' {
        # Scenario: A local, pre-push, or CI caller starts validation.
        # Purpose: Ensure component diagnostics cannot become a second release gate.
        $validatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        Test-Path -LiteralPath $validatorPath -PathType Leaf | Should -BeTrue
        $validator = Get-Content -LiteralPath $validatorPath -Raw
        $validator | Should -Match 'tests[/\\]validate-repository\.ps1'
        $validator | Should -Match 'tests[/\\]validate-repository-standalone\.ps1'
        $validator | Should -Match 'tests[/\\]validate-api-access\.ps1'
        $validator | Should -Match 'Package Validation'
        $validator | Should -Match 'SkillSpector Static'
        $validator | Should -Match 'Repository Tests'
        $validator | Should -Match 'Conditional Semantic Scan'
        $validator | Should -Match 'candidateIdentity'
        $validator | Should -Match 'authority'
        $validator | Should -Match 'packageInventory'
        $validator | Should -Match 'toolReceipts'
        $validator | Should -Match 'stageResults'
    }

    It 'UnitT40_routes_validate_yml_to_the_canonical_entry_and_removes_floating_policy_workflow' {
        # Scenario: GitHub receives push, pull_request, or manual-dispatch validation.
        # Purpose: Make each event use one candidate-bound canonical pass/block contract.
        $workflowPath = Join-Path $script:RepositoryRoot '.github/workflows/validate.yml'
        Test-Path -LiteralPath $workflowPath -PathType Leaf | Should -BeTrue
        $workflow = Get-Content -LiteralPath $workflowPath -Raw
        $workflow | Should -Match 'scripts/Validate\.ps1'
        $workflow | Should -Match 'push:'
        $workflow | Should -Match 'pull_request:'
        $workflow | Should -Match 'workflow_dispatch:'
        $workflow | Should -Match 'persist-credentials:\s*false'
        $workflow | Should -Match 'actions/checkout@[0-9a-f]{40}'
        $workflow | Should -Not -Match '(?m)^\s*(Install-Module|npm install|go install|pip install)\b'
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/skill-validator.yml') | Should -BeFalse
        $workflow | Should -Match '(?ms)^\s+canonical-validation:\s+.*?scripts/Validate\.ps1'
        foreach ($mirror in @('repository-contract', 'skill-validator', 'skill-tools')) {
            $workflow | Should -Match ("(?ms)^\s+{0}:\s+.*?needs:\s+canonical-validation" -f [regex]::Escape($mirror))
        }
        $workflow | Should -Not -Match '(?ms)^\s+(repository-contract|skill-validator|skill-tools):\s+.*?\b(Install-Module|npm\s+install|go\s+install|pip\s+install|scripts/Validate\.ps1)'
    }
}
