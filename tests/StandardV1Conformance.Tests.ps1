# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Atlassian Ecosystem Standard v1 conformance' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:SourcePath = Join-Path $script:RepositoryRoot 'catalog/source.json'
        $script:AdapterPath = Join-Path $script:RepositoryRoot 'config/standard-v1.json'
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
    }

    It 'uses the canonical schema v2 source inventory and source root' {
        # Scenario: The repository is checked out as a clean Standard v1 source repository.
        # Purpose: Keep all six Atlassian Skills bound to one exact catalog contract.
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot 'skills') -PathType Container | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.agents/skills') | Should -BeFalse
        $source = Get-Content -LiteralPath $script:SourcePath -Raw | ConvertFrom-Json -Depth 20
        @($source.PSObject.Properties.Name) | Should -Be @('schemaVersion','sourceId','repository','skillsRoot','skills')
        $source.schemaVersion | Should -Be 2
        $source.sourceId | Should -Be 'atlassian-ecosystem'
        $source.repository | Should -Be 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git'
        $source.skillsRoot | Should -Be 'skills'
        @($source.skills) | Should -Be @(
            'configure-bitbucket-api-access',
            'configure-confluence-api-access',
            'configure-jira-api-access',
            'publish-requirements-to-confluence',
            'review-bitbucket-pull-request',
            'work-with-jira'
        )
    }

    It 'binds one immutable central authority snapshot without a local security policy' {
        # Scenario: The repository adapter is loaded before any validation tool is resolved.
        # Purpose: Prevent an Atlassian-specific policy fork from silently replacing Standard v1.
        $adapter = Get-Content -LiteralPath $script:AdapterPath -Raw | ConvertFrom-Json -Depth 20
        $adapter.schemaVersion | Should -Be 1
        $adapter.standardVersion | Should -Be 'v1'
        $adapter.authority.repository | Should -Be 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
        $adapter.authority.commit | Should -Match '^[0-9a-f]{40}$'
        $adapter.authority.archiveSha256 | Should -Match '^[0-9a-f]{64}$'
        @($adapter.PSObject.Properties.Name) | Should -Not -Contain 'security'
        @($adapter.authority.files.path) | Should -Contain 'docs/standards/skill-repository-standard.md'
        @($adapter.authority.files.path) | Should -Contain 'docs/standards/validation-security-gate.json'
        @($adapter.authority.files.path) | Should -Contain 'scripts/Resolve-StandardValidationTool.ps1'
        $adapter.deviations | Should -Be 'None'
    }

    It 'exposes the canonical validator and preserves the existing API contract suite' {
        # Scenario: A local, pre-push, or CI caller invokes the Standard v1 validator.
        # Purpose: Ensure the existing Atlassian-specific checks remain inside the canonical gate.
        $validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
        $validator | Should -Match 'Test-Repository\.ps1'
        $validator | Should -Match 'skillspector'
        $validator | Should -Match 'skill-validator'
        $validator | Should -Match 'skill-tools'
        $validator | Should -Match 'Invoke-Pester'
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot 'tests/RepositoryValidation.Tests.ps1') | Should -BeTrue
        $validator | Should -Match '\[string\] \$BaseCommit'
    }

    It 'routes all required checks through one canonical workflow without a second policy workflow' {
        # Scenario: GitHub runs base-owned pull-request-target validation on the current candidate head.
        # Purpose: Keep local, pre-push, and required bridge checks on identical pass/block semantics.
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml') -Raw
        $workflow | Should -Match 'scripts/Validate\.ps1'
        $workflow | Should -Match 'pull_request_target:'
        $workflow | Should -Match 'TRUSTED_SUPERVISOR_COMMIT: \$\{\{ github\.sha \}\}'
        $workflow | Should -Match 'persist-credentials:\s*false'
        $workflow | Should -Match 'actions/checkout@[0-9a-f]{40}'
        $workflow | Should -Match 'actions/setup-go@[0-9a-f]{40}'
        $workflow | Should -Match 'approvedTransitionWorkflowSha256'
        $workflow | Should -Match 'workflowHashPattern'
        $workflow | Should -Match 'Export canonical evidence for clean upload'
        $workflow | Should -Match 'upload-canonical-validation-evidence'
        $workflow | Should -Match 'evidence_base64'
        $workflow | Should -Not -Match '(?m)^\s*(Install-Module|npm install|go install|pip install)\b'
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/skill-validator.yml') | Should -BeFalse

        $workflow | Should -Match '(?ms)^\s+publish-head-required-checks:\s+name:\s+publish head-bound required checks.*?needs:\s+- repository-contract-windows-powershell\s+- canonical-validation'
        $workflow | Should -Match 'HEAD_SHA'
        $workflow | Should -Match "needs\['canonical-validation'\]\.result"
        $workflow | Should -Match "needs\['repository-contract-windows-powershell'\]\.result"
        foreach ($bridge in @('validate-repository.ps1', 'validate-repository-standalone.ps1', 'validate-api-access.ps1')) {
            $bridgeText = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot "tests/$bridge") -Raw
            $bridgeText | Should -Not -Match '\$CompletionMarker'
            $bridgeText | Should -Not -Match 'CompletionMarkerFromInput'
            $bridgeText | Should -Match 'Publish-TrustedBridgeCompletion'
            $bridgeText | Should -Match 'NamedPipeClientStream'
            $bridgeText | Should -Not -Match 'SGV1-Bridge-Completed'
        }
    }
}
