# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Atlassian Ecosystem Standard v1 conformance' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:SourcePath = Join-Path $script:RepositoryRoot 'catalog/source.json'
        $script:AdapterPath = Join-Path $script:RepositoryRoot 'config/standard-v1.json'
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $script:RepositoryValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1'
        $script:ExpectedAuthorityCommit = 'a403abdf038a3346d775431a6908a71cc3d35a5b'
        $script:ExpectedAuthorityArchiveSha256 = '17154929fadfa63487263db1efcb78f4948195af9c11c25a66432eff3411b2d3'
        $script:ExpectedAuthorityFiles = @(
            @{ path = 'docs/standards/README.md'; sha256 = '5e1ddd737d26a5ec1ff1ebd08e158376ddaf1ea21008bb987fc7f51376923f7c' }
            @{ path = 'docs/standards/managed-skill-lifecycle.md'; sha256 = '70950cf8bdd02819efae6f6e06ac5be1da3e70f809c23e3c6f8d3b217797416c' }
            @{ path = 'docs/standards/schemas/managed-skill-lifecycle-v1.schema.json'; sha256 = '9a7f4c02588d2b88194e953a41766a72a9426fa89d4c3781c5750dcc22d35863' }
            @{ path = 'docs/standards/schemas/openai-agent-metadata.schema.json'; sha256 = '23c1aaee28a54fea1946a61d6122a2097906ffa5bdd66c8014fc6b1625c9062a' }
            @{ path = 'docs/standards/schemas/source-inventory-v2.schema.json'; sha256 = '084550944b4141ab5535f58fb6e99730a5c34b56103f6b59fd5a352679caa98e' }
            @{ path = 'docs/standards/schemas/validation-security-gate-v1.schema.json'; sha256 = '56979baa08f3ec5534e3a17f925d53e69accd4cdc500872e92ca56b694044ea6' }
            @{ path = 'docs/standards/skill-repository-review-matrix.md'; sha256 = 'c345ad3ec32d1941df5c5757ce96b4430c0223b3f8ed99f2a4de7dc9923410f2' }
            @{ path = 'docs/standards/skill-repository-standard.md'; sha256 = '78a72aa8214acd5a5e202df34bbb20f8cfd841ab3d181de10645a777267cfd5d' }
            @{ path = 'docs/standards/upstream-interoperability.md'; sha256 = '9c544fbfb6b77a589514f1926aa1488882e932786a303a42ce6c6c9b2ba80c7e' }
            @{ path = 'docs/standards/validation-security-gate.json'; sha256 = 'e303e8c3d484012022f5c4da694c3fe21ff02395b0b9b7e973a4234d4182f485' }
            @{ path = 'docs/standards/validation-toolchain.json'; sha256 = '5925dcb1aea1e545b9787a29825e7a0cc03a04c777cd68ab44c9bdd7482ff579' }
            @{ path = 'scripts/Invoke-StandardAuthorityGate.ps1'; sha256 = 'c98d3f1b181ba0e7d3894729a8f1636984407c20454a27e0e383799c2f90425f' }
            @{ path = 'scripts/Resolve-PythonWheelClosure.py'; sha256 = '7fa1511a3e3ba257c6d9e37f929f68e5684184a3a2756a3f9e765ccc6e69d208' }
            @{ path = 'scripts/Resolve-StandardValidationTool.ps1'; sha256 = '3744bc4549612e5997361315a8fd5e1ea803ade26052cf4eaf2ccdc1776fcf6e' }
            @{ path = 'docs/standards/schemas/standard-validation-adapter-v1.schema.json'; sha256 = '1b45052712450d40df278937d381018b9ce2ded2cbf42845db65f8028e56df44' }
            @{ path = 'docs/standards/schemas/standard-validation-evidence-v1.schema.json'; sha256 = '24d8b0f29f9bddd8af1bee02943fb46c72ca5d4a874727cb107ff68a39af12b9' }
            @{ path = 'docs/standards/standard-validation-contract-v1.json'; sha256 = '2b3d6da1c97c5542a9761445da9de5f101ada53e83cb1f17ee90c8b0d4929356' }
            @{ path = 'docs/standards/trust-anchors/human-approval-public-key.xml'; sha256 = '1e46153b72d02f3ce2fb26becd449df4f1590d8e5cb441b1954006a5602bbd9b' }
            @{ path = 'docs/standards/trust-anchors/trusted-supervisor-public-key.xml'; sha256 = '4d550851f43405920156f40c9fc648d99a69dd73efc200f6968d8a837e7fbf27' }
            @{ path = 'scripts/Invoke-StandardValidation.ps1'; sha256 = '3cee28379d5612e4592f1755d8732e6b869018402b7d82efacd89fa10bcafd57' }
            @{ path = 'docs/standards/schemas/upstream-adapter-v1.schema.json'; sha256 = '3cff6246463188a91cc54c6a46315a949314767a759c6214e5b28e4db95ac8d7' }
            @{ path = 'docs/standards/upstream-adapter.json'; sha256 = 'c4f5133b24841bb9c66182dc3d5a027596f864ec28e410d47249a67b3b97ad31' }
            @{ path = 'scripts/Validate-UpstreamAdapter.ps1'; sha256 = '7fd3c2c34544b21b769ebfa9238c379e094e022381b7ebe11f3e196e623fd376' }
        )
    }

    It 'UnitT10_UsesTheCanonicalSchemaV2SourceInventoryAndSourceRoot' {
        # Scenario: The repository is checked out as a clean Standard v1 source repository.
        # Purpose: Keep all six Atlassian Skills bound to one exact catalog contract.
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
        $adapter.centralRunner.runnerSha256 | Should -Be '3cee28379d5612e4592f1755d8732e6b869018402b7d82efacd89fa10bcafd57'
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

    It 'UnitT40_RoutesAllRequiredChecksThroughTheCanonicalWorkflowAndTrustedTests' {
        # Scenario: GitHub runs base-owned pull-request-target validation on the current candidate head.
        # Purpose: Keep local, pre-push, and required bridge checks on identical pass/block semantics.
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml') -Raw
        $workflow | Should -Match 'scripts/Validate\.ps1'
        $workflow | Should -Match 'pull_request_target:'
        $workflow | Should -Match '(?ms)^\s+pull_request_target:\s*\r?\n\s+branches:\s*\r?\n\s+-\s+main\s*$'
        $workflow | Should -Not -Match '(?m)^\s+workflow_dispatch\s*:'
        $workflow | Should -Not -Match '(?m)^\s+push\s*:'
        $workflow | Should -Match 'Invoke-StandardValidation\.ps1'
        $workflow | Should -Match 'STANDARD_V1_SUPERVISOR_LAUNCH_BINDING_PATH'
        $workflow | Should -Match 'exit 10'
        $workflow | Should -Match 'TRUSTED_SUPERVISOR_COMMIT: \$\{\{ github\.sha \}\}'
        $workflow | Should -Match 'persist-credentials:\s*false'
        $workflow | Should -Match 'actions/checkout@[0-9a-f]{40}'
        $workflow | Should -Match 'actions/setup-go@[0-9a-f]{40}'
        $workflow | Should -Not -Match 'approvedTransitionWorkflowSha256|bootstrap_skip|STANDARD_V1_BOOTSTRAP_SKIP'
        $workflow | Should -Match 'Delegate Linux cgroup v2 subtree for protected Pester'
        $workflow | Should -Match 'CODEX_PESTER_CGROUP_ROOT'
        $workflow | Should -Match 'CODEX_PESTER_VALIDATOR_CGROUP'
        $workflow | Should -Match 'Remove delegated Linux cgroup subtree'
        $workflow | Should -Match 'Export canonical evidence for clean upload'
        $workflow | Should -Match 'upload-canonical-validation-evidence'
        $workflow | Should -Match 'evidence_base64'
        $workflow | Should -Not -Match '(?m)^\s*(Install-Module|npm install|go install|pip install)\b'
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/skill-validator.yml') | Should -BeFalse

        $publisherJob = [regex]::Match($workflow, '(?ms)^\s+publish-head-required-checks:.*\z').Value
        $publisherJob | Should -Not -BeNullOrEmpty
        $publisherJob | Should -Match '(?ms)^\s+needs:\s*\r?\n\s+-\s+repository-contract-windows-powershell\s*\r?\n\s+-\s+canonical-validation\s*\r?\n\s+-\s+github-copilot-agent-skills\s*\r?\n\s+-\s+upload-canonical-validation-evidence\s*$'
        $workflow | Should -Match 'HEAD_SHA'
        $workflow | Should -Match "needs\['canonical-validation'\]\.result"
        $workflow | Should -Match "needs\['repository-contract-windows-powershell'\]\.result"
        $publisherJob | Should -Match "EVIDENCE_UPLOAD_RESULT: \$\{\{ needs\['upload-canonical-validation-evidence'\]\.result \}\}"
        $publisherJob | Should -Match '(?s)EVIDENCE_UPLOAD_RESULT.*success'
        foreach ($bridge in @('validate-repository.ps1', 'validate-repository-standalone.ps1', 'validate-api-access.ps1')) {
            $bridgeText = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot "tests/$bridge") -Raw
            $bridgeText | Should -Not -Match '\$CompletionMarker'
            $bridgeText | Should -Not -Match 'CompletionMarkerFromInput'
            $bridgeText | Should -Not -Match 'Publish-TrustedBridgeCompletion|NamedPipeClientStream|CompletionPipeName|CompletionToken'
            $bridgeText | Should -Not -Match 'SGV1-Bridge-Completed'
        }
        $readme = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'README.md') -Raw
        $readme | Should -Match 'complete six-file Pester\s+inventory'
        $readme | Should -Not -Match 'complete five-file Pester inventory'
    }

    # Scenario: The validator is cancelled while native children still own
    # nested cgroup directories. Purpose: cleanup must kill and drain every
    # run-bound descendant before removing the delegated root.
    It 'UnitT41_CleansNestedLinuxCgroupsBeforePublishingHeadChecks' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml') -Raw
        $cleanup = [regex]::Match($workflow, '(?ms)Remove delegated Linux cgroup subtree.*?\n\s+- name:').Value
        $cleanup | Should -Match 'cgroup\.kill'
        $cleanup | Should -Match 'cgroup\.events'
        $cleanup | Should -Match 'populated'
        $cleanup | Should -Match 'rmdir'
        $cleanup | Should -Match 'sort.*reverse|depth|inner|descendant'
        $workflow | Should -Match 'EVIDENCE_UPLOAD_RESULT'
        $workflow | Should -Match 'CGROUP_CLEANUP_RESULT'
        $workflow | Should -Match 'CANONICAL_RESULT.*success.*EVIDENCE_UPLOAD_RESULT.*success'
        $workflow | Should -Match 'EVIDENCE_UPLOAD_RESULT.*success.*CGROUP_CLEANUP_RESULT.*success'
    }

    # Scenario: The candidate checkout may contribute writable directories to
    # the runner's ambient PATH before the validator joins its cgroup.
    # Purpose: Resolve every cgroup setup/cleanup helper from runner-owned
    # system paths so a same-named candidate executable cannot run first.
    It 'UnitT42_UsesTrustedPathsForLinuxCgroupHelpers' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml') -Raw
        $delegation = [regex]::Match($workflow, '(?ms)Delegate Linux cgroup v2 subtree.*?^\s+run:\s*\|\r?\n(?<body>.*?)^\s+- name: Run canonical Standard v1 validation').Groups['body'].Value
        $cleanup = [regex]::Match($workflow, '(?ms)Remove delegated Linux cgroup subtree.*?^\s+run:\s*\|\r?\n(?<body>.*?)^\s+- name: Verify canonical validation evidence').Groups['body'].Value
        $delegation | Should -Not -BeNullOrEmpty
        $cleanup | Should -Not -BeNullOrEmpty

        foreach ($block in @($delegation, $cleanup)) {
            $block | Should -Match "(?m)^\s+export PATH='/usr/sbin:/usr/bin:/sbin:/bin'\s*$"
        }

        $cgroupShell = @($delegation, $cleanup) -join "`n"
        foreach ($helper in @('sudo', 'tee', 'mkdir', 'rmdir', 'chown', 'chmod', 'id', 'seq', 'grep', 'sleep', 'find', 'sort')) {
            $cgroupShell | Should -Match ("/usr/bin/{0}\b" -f [regex]::Escape($helper))
        }
        $cgroupShell | Should -Not -Match '(?m)^\s*(sudo|tee|mkdir|rmdir|chown|chmod|id|seq|grep|sleep|find|sort)\b'
    }
}
