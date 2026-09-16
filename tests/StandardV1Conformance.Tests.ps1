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
        $script:AuthorityCommit = 'a403abdf038a3346d775431a6908a71cc3d35a5b'
        $script:AuthorityArchiveSha256 = '17154929fadfa63487263db1efcb78f4948195af9c11c25a66432eff3411b2d3'
    }

    It 'UnitT10_uses_schema_v2_and_the_exact_six_skill_inventory' {
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
        $adapterPath = Join-Path $script:RepositoryRoot 'config/standard-v1.json'
        Test-Path -LiteralPath $adapterPath -PathType Leaf | Should -BeTrue
        $adapter = Get-Content -LiteralPath $adapterPath -Raw | ConvertFrom-Json -Depth 20
        @($adapter.PSObject.Properties.Name) | Should -Be @('schemaVersion', 'standardVersion', 'authority')
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
    }

    It 'UnitT30_exposes_one_canonical_validator_and_the_central_runner_contract' {
        $validatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        Test-Path -LiteralPath $validatorPath -PathType Leaf | Should -BeTrue
        $validator = Get-Content -LiteralPath $validatorPath -Raw
        $validator | Should -Match 'scripts[/\\]Invoke-StandardValidation\.ps1'
        $validator | Should -Match 'standard-validation-adapter\.json'
        $validator | Should -Match 'packageAdapter'
        $validator | Should -Match 'skillValidator'
        $validator | Should -Match 'skillTools'
        $validator | Should -Match 'staticAnalyzer'
        $validator | Should -Match 'repositoryTests'
        $validator | Should -Match 'candidateIdentity'
        $validator | Should -Match 'authority'
        $validator | Should -Match 'toolReceipts|receipt'
        $validator | Should -Not -Match 'ConvertTo-ValidationSecurityFinding'
        $validator | Should -Not -Match 'Get-ValidationSecurityAction'
    }

    It 'UnitT40_routes_validate_yml_to_the_base_owned_protected_entry' {
        $workflowPath = Join-Path $script:RepositoryRoot '.github/workflows/validate.yml'
        Test-Path -LiteralPath $workflowPath -PathType Leaf | Should -BeTrue
        $workflow = Get-Content -LiteralPath $workflowPath -Raw -Encoding UTF8
        $workflow | Should -Match 'scripts/Validate\.ps1'
        $workflow | Should -Match 'push:'
        $workflow | Should -Match 'pull_request_target:'
        $workflow | Should -Not -Match '(?m)^\s+pull_request:\s*$'
        $workflow | Should -Match 'workflow_dispatch:'
        $workflow | Should -Match 'persist-credentials:\s*false'
        $workflow | Should -Match 'actions/checkout@[0-9a-f]{40}'
        $workflow | Should -Not -Match '(?m)^\s*(Install-Module|npm install|go install|pip install)\b'
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/skill-validator.yml') | Should -BeFalse
        $workflow | Should -Match '(?ms)^\s+canonical-validation:\s+.*?scripts/Validate\.ps1'
        foreach ($mirror in @('repository-contract', 'skill-validator', 'skill-tools')) {
            $workflow | Should -Match ("(?ms)^\s+{0}:\s+.*?needs: canonical-validation" -f [regex]::Escape($mirror))
        }
    }
}
