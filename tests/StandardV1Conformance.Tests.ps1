# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Atlassian Ecosystem Standard v1 conformance' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:SourcePath = Join-Path $script:RepositoryRoot 'catalog/source.json'
        $script:AdapterPath = Join-Path $script:RepositoryRoot 'config/standard-v1.json'
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $script:RepositoryValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1'
        $script:ExpectedAuthorityCommit = 'd574cf903567cb30d7f9051b671d6be61de1f42e'
        $script:ExpectedAuthorityArchiveSha256 = 'e79395d308bb2b8212eac3366cf64067f73f8d7a0687c6d4d5153c63c44cc993'
        $script:ExpectedAuthorityFiles = @(
            @{ path = 'docs/standards/README.md'; sha256 = '23b62b48bf4dd66979587250e4fa28c4c2bd51e6220281577961ea45ea8e1484' }
            @{ path = 'docs/standards/internal-source-continuation.json'; sha256 = '4e4bd288835e861a5c020a709a4bee81b0ade3ca0d5d2140a8992b4f4e3578c2' }
            @{ path = 'docs/standards/managed-skill-lifecycle.md'; sha256 = '70950cf8bdd02819efae6f6e06ac5be1da3e70f809c23e3c6f8d3b217797416c' }
            @{ path = 'docs/standards/schemas/internal-source-continuation-v1.schema.json'; sha256 = '559aaa9f7ec44f347ad9c431f57caaed017824bc7949a480658aa1f3af07f01c' }
            @{ path = 'docs/standards/schemas/internal-source-review-assessment-v1.schema.json'; sha256 = 'c25f810e1c6b7b8848c6deda87e8ad2c6b5df8f1073da9bfb9d078a2966fbd60' }
            @{ path = 'docs/standards/schemas/managed-skill-lifecycle-v1.schema.json'; sha256 = '9a7f4c02588d2b88194e953a41766a72a9426fa89d4c3781c5750dcc22d35863' }
            @{ path = 'docs/standards/schemas/openai-agent-metadata.schema.json'; sha256 = '23c1aaee28a54fea1946a61d6122a2097906ffa5bdd66c8014fc6b1625c9062a' }
            @{ path = 'docs/standards/schemas/source-inventory-v2.schema.json'; sha256 = '084550944b4141ab5535f58fb6e99730a5c34b56103f6b59fd5a352679caa98e' }
            @{ path = 'docs/standards/schemas/standard-semantic-consent-evidence-v2.schema.json'; sha256 = '109091979d0a47e2035d3d8b20963fcdb85680e5da737bf1f27121608115d430' }
            @{ path = 'docs/standards/schemas/standard-validation-adapter-v1.schema.json'; sha256 = '11aa88fc25716d748bd4f514f1a44f02390ad1745dd5a5c5beee07f642fd5639' }
            @{ path = 'docs/standards/schemas/standard-validation-evidence-v1.schema.json'; sha256 = '064a90db32904a42351ca4794beed978f93bf55642748de497eae44a15674747' }
            @{ path = 'docs/standards/schemas/static-parser-host-ownership-v1.schema.json'; sha256 = '466812e079bd6bbd4eb3937277841df0b8167901b146d64a97a10ac94d9bf5ce' }
            @{ path = 'docs/standards/schemas/static-parser-profile-execution-v1.schema.json'; sha256 = 'b813c113d45d40b70accdb795f67d1e7b50e3642e106e8e8ca4b4a51e55a4fe2' }
            @{ path = 'docs/standards/schemas/upstream-adapter-v1.schema.json'; sha256 = '3cff6246463188a91cc54c6a46315a949314767a759c6214e5b28e4db95ac8d7' }
            @{ path = 'docs/standards/schemas/validation-security-gate-v1.schema.json'; sha256 = '9b186773b85b242c216942cac5fe8dc4eaa231ac7edac0e194c790c94e4bf9dc' }
            @{ path = 'docs/standards/skill-repository-review-matrix.md'; sha256 = '299925aabe3cab360827baad9bdeb1f0f56fc320dad967e49fe0b6bf9cdf8f8a' }
            @{ path = 'docs/standards/skill-repository-standard.md'; sha256 = 'bf342a90cf137d1517f1ed2cf5a3baac31d621b5a1af76777187e5b624d58238' }
            @{ path = 'docs/standards/standard-validation-contract-v1.json'; sha256 = 'ba2f36ef113eb2937f39819099e339eb13731ef0036bb731037dbc0720d8e12e' }
            @{ path = 'docs/standards/static-parser-host-ownership.json'; sha256 = 'efc5b764f59802dc4399a68b4698603bcd8adfe5cdb6d945dee9422ae17e7bc1' }
            @{ path = 'docs/standards/trust-anchors/human-approval-public-key.xml'; sha256 = '1e46153b72d02f3ce2fb26becd449df4f1590d8e5cb441b1954006a5602bbd9b' }
            @{ path = 'docs/standards/trust-anchors/trusted-supervisor-public-key.xml'; sha256 = '4d550851f43405920156f40c9fc648d99a69dd73efc200f6968d8a837e7fbf27' }
            @{ path = 'docs/standards/upstream-adapter.json'; sha256 = 'c4f5133b24841bb9c66182dc3d5a027596f864ec28e410d47249a67b3b97ad31' }
            @{ path = 'docs/standards/upstream-interoperability.md'; sha256 = '4329e8586e88713027bcd95c7537331e050a89b004f2361223efdc01bf44370e' }
            @{ path = 'docs/standards/validation-security-gate.json'; sha256 = 'd0437b7aae41a78b8f53f5a052396941350ea90d352a109391ea5d7c6140febc' }
            @{ path = 'docs/standards/validation-toolchain.json'; sha256 = '1dddbf4c5736e22e56f6ecb298542f41d39e116ab00ca24ad18beb7a3eab40ed' }
            @{ path = 'scripts/Get-StandardPowerShellSyntaxProof.ps1'; sha256 = '29104bd061d5e43540a0586c29830b28fd6f16367f3a7ffbf960980576d559cd' }
            @{ path = 'scripts/Invoke-StandardAuthorityGate.ps1'; sha256 = 'fd5cc1500f8bcb7d3d5dd707f5426fbb996d00bf048d3bdbb4b510cfc0ff2591' }
            @{ path = 'scripts/Invoke-StandardStaticScan.ps1'; sha256 = 'ffc8316da010737b4c91e411308f4ad5a2a8af70b8586ca3cdcd1fc46e7a541e' }
            @{ path = 'scripts/Invoke-StandardValidation.ps1'; sha256 = 'e19d34f6bc4287f19b53ab377c7574c7403ba4f3e240f4107fba17fcc9d36051' }
            @{ path = 'scripts/Resolve-PythonWheelClosure.py'; sha256 = 'f9fcd99c408849f98564fbc4c30f3d7e6ad8148b60cb4d8f58fc29b040c4519c' }
            @{ path = 'scripts/Resolve-StandardValidationTool.ps1'; sha256 = '71e6d5b191b74202e96f34a856d3317efb18662e17c8368d112d89b7d6795b15' }
            @{ path = 'scripts/StandardSemanticBridge.psm1'; sha256 = 'daf90f703898cc56fc3310e1eec462bafa6552edcac0de4f08a3cd4b9f63a429' }
            @{ path = 'scripts/Validate-UpstreamAdapter.ps1'; sha256 = '3b6e6474690b1ae9f9486544b68f50ca29b96f5dbe6aa8d6c6cd8570afad500b' }
            @{ path = 'scripts/standard_static_powershell.py'; sha256 = '53f25cbbebcaabd98e92c3c42c2e3914d59ef35185a4a0806e56ba44e206c95a' }
        )
    }

    It 'UnitT10_UsesTheCanonicalSchemaV2SourceInventoryAndSourceRoot' {
        # Scenario: The repository is checked out as a clean Standard v1 source repository.
        # Purpose: Keep all seven transitional Atlassian Skills bound to one exact catalog contract.
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot 'skills') -PathType Container | Should -BeTrue
        if (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.git')) {
            $trackedRuntimeSkills = @(& git -C $script:RepositoryRoot ls-files -- '.agents/skills')
            $LASTEXITCODE | Should -Be 0
            $trackedRuntimeSkills.Count | Should -Be 0
        }
        else {
            Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.agents/skills') | Should -BeFalse
        }
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
            'manage-confluence-docs-as-code',
            'publish-requirements-to-confluence',
            'review-bitbucket-pull-request',
            'work-with-jira'
        )
    }

    It 'UnitT15_BindsOneImmutableCentralAuthoritySnapshotWithoutLocalSecurityPolicy' {
        # Scenario: The repository adapter is loaded before any validation tool is resolved.
        # Purpose: Prevent an Atlassian-specific policy fork from silently replacing Standard v1.
        $adapter = Get-Content -LiteralPath $script:AdapterPath -Raw | ConvertFrom-Json -Depth 20
        $adapter.schemaVersion | Should -Be 1
        $adapter.standardVersion | Should -Be 'v1'
        $adapter.authority.repository | Should -Be 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
        $adapter.authority.commit | Should -Be $script:ExpectedAuthorityCommit
        $adapter.authority.archiveUrl | Should -Be "https://codeload.github.com/SyuanTsai/SyuanTsai-AI-Instructions/zip/$($script:ExpectedAuthorityCommit)"
        $adapter.authority.archiveSha256 | Should -Be $script:ExpectedAuthorityArchiveSha256
        @($adapter.authority.files).Count | Should -Be $script:ExpectedAuthorityFiles.Count
        for ($index = 0; $index -lt $script:ExpectedAuthorityFiles.Count; $index++) {
            $adapter.authority.files[$index].path | Should -Be $script:ExpectedAuthorityFiles[$index].path
            $adapter.authority.files[$index].sha256 | Should -Be $script:ExpectedAuthorityFiles[$index].sha256
        }
        @($adapter.PSObject.Properties.Name) | Should -Be @('schemaVersion', 'standardVersion', 'authority', 'deviations', 'centralRunner')
        @($adapter.PSObject.Properties.Name) | Should -Not -Contain 'security'
        @($adapter.authority.files.path) | Should -Contain 'docs/standards/skill-repository-standard.md'
        @($adapter.authority.files.path) | Should -Contain 'docs/standards/validation-security-gate.json'
        @($adapter.authority.files.path) | Should -Contain 'scripts/Resolve-StandardValidationTool.ps1'
        $adapter.deviations | Should -Be 'None'
        $adapter.centralRunner.runnerPath | Should -Be 'scripts/Invoke-StandardValidation.ps1'
        $adapter.centralRunner.runnerSha256 | Should -Be 'e19d34f6bc4287f19b53ab377c7574c7403ba4f3e240f4107fba17fcc9d36051'
        $adapter.centralRunner.contractPath | Should -Be 'docs/standards/standard-validation-contract-v1.json'
        $adapter.centralRunner.evidenceSchemaPath | Should -Be 'docs/standards/schemas/standard-validation-evidence-v1.schema.json'
        $adapter.centralRunner.adapterSource | Should -Be 'trusted-supervisor-generated-from-resolver-receipts'
        $adapter.centralRunner.adapterMode | Should -Be 'production'
        @($adapter.centralRunner.requiredEvidence) | Should -Be @('launchBinding', 'signedResolverReceipt', 'candidateBinding', 'semanticConsent', 'semanticProvider', 'semanticPurpose', 'semanticScope', 'semanticAttestation')
    }

    It 'binds the exact authority file inventory in both validators' {
        $validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
        $repositoryValidator = Get-Content -LiteralPath $script:RepositoryValidatorPath -Raw
        foreach ($file in $script:ExpectedAuthorityFiles) {
            $quotedPath = [regex]::Escape("'$($file.path)'")
            $validator | Should -Match $quotedPath
            $repositoryValidator | Should -Match $quotedPath
        }
    }

    It 'pins source adapter hashes to the immutable authority inventory' {
        $adapter = Get-Content -LiteralPath $script:AdapterPath -Raw | ConvertFrom-Json -Depth 20
        $sourceEntry = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1') -Raw
        foreach ($path in @(
            'scripts/Invoke-StandardValidation.ps1',
            'docs/standards/standard-validation-contract-v1.json',
            'docs/standards/schemas/standard-validation-evidence-v1.schema.json'
        )) {
            $entry = @($adapter.authority.files | Where-Object { $_.path -ceq $path })
            $entry.Count | Should -Be 1
            $sourceEntry | Should -Match ([regex]::Escape("'$path' = '$($entry[0].sha256)'"))
        }
    }

    It 'exposes the canonical validator and preserves the existing API contract suite' {
        # Scenario: A local, pre-push, or CI caller invokes the Standard v1 validator.
        # Purpose: Ensure the existing Atlassian-specific checks remain inside the canonical gate.
        $validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
        $validator | Should -Match 'Test-Repository\.ps1'
        $validator | Should -Match 'if \(\$SourceConformance -or \(-not \$ProtectedPesterServerProxy -and -not \$ProtectedPesterSupervisor\)\)'
        $validator | Should -Match 'skillspector'
        $validator | Should -Match 'skill-validator'
        $validator | Should -Match 'skill-tools'
        $validator | Should -Match 'Invoke-Pester'
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot 'tests/RepositoryValidation.Tests.ps1') | Should -BeTrue
        $validator | Should -Match '\[string\] \$BaseCommit'
    }

    It 'runs one read-only source workflow for pull requests and main pushes' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml') -Raw
        $workflow | Should -Match '(?m)^  pull_request:'
        $workflow | Should -Match '(?m)^  push:'
        $workflow | Should -Match '(?m)^  contents: read\r?$'
        $workflow | Should -Match 'persist-credentials:\s*false'
        $workflow | Should -Match 'scripts/Validate\.ps1 -SourceConformance'
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot 'tests/validate-windows-powershell.ps1') | Should -BeTrue
        $workflow | Should -Match 'Route source conformance from canonical evidence'
        $workflow | Should -Match 'Require source conformance'
        $workflow | Should -Not -Match 'pull_request_target|checks:\s*write|STANDARD_V1_SUPERVISOR_LAUNCH_BINDING_PATH|publish-head-required-checks'
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml') | Should -BeFalse
    }

    It 'keeps the Git-backed Atlassian domain contract in the central source adapter' {
        $sourceEntry = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1') -Raw
        $sourceEntry | Should -Match "mode = 'development-harness'"
        $sourceEntry | Should -Match "id = 'repository-test-atlassian'; kind = 'general'"
        $sourceEntry | Should -Match 'SourceCheckoutRoot'
        $sourceEntry | Should -Match 'Test-Repository\.ps1'
        $sourceEntry | Should -Match 'Git checkout context is not the clean candidate revision'
        $sourceEntry | Should -Match "'-Mode', 'repository-atlassian'"
        $sourceEntry | Should -Match "kind = 'pester'"
        $sourceEntry | Should -Match "'-DevelopmentHarness'"
        $sourceEntry | Should -Not -Match "'-SupervisorLaunchBindingPath'"
    }

    # Scenario: Source validation reaches the repository-tests stage for the reviewed Bitbucket Skill package.
    # Purpose: Require the real consumer to call the pinned central approval reader and retain its bounded decision.
    It 'consumes the central internal Skill use decision as a source gate' {
        $sourceEntry = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1') -Raw
        $sourceEntry | Should -Match "id = 'repository-test-internal-skill-use'; kind = 'general'"
        $sourceEntry | Should -Match "'-Mode', 'internal-skill-use'"
        $sourceEntry | Should -Match 'Resolve-StandardValidationInternalSkillUse'
        $sourceEntry | Should -Match "approvalId = 'atlassian-bitbucket-review-7e8228c'"
        $sourceEntry | Should -Match "reviewedSourceRevision = '7e8228c393579d5d21ac9c0ad729c7b5d219bab6'"
        $sourceEntry | Should -Match "skillId = 'review-bitbucket-pull-request'"
        $sourceEntry | Should -Match "contentSha256 = '056b8e520460e6612b10c8c9248fd7c217c6e4708ca65f3bc6c05b98ee84dec9'"
        $sourceEntry | Should -Match "purpose = 'local-pr-review'"
        $sourceEntry | Should -Match "retainedFindingId = 'finding-1279bfce3ac3466f888a7b9f396e67c5'"
        $sourceEntry | Should -Match 'Central reader returned an unsafe internal Skill use decision'
    }
}
