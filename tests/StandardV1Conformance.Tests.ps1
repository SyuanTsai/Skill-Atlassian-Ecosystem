# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Atlassian Ecosystem Standard v1 conformance' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:SourcePath = Join-Path $script:RepositoryRoot 'catalog/source.json'
        $script:AdapterPath = Join-Path $script:RepositoryRoot 'config/standard-v1.json'
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $script:RepositoryValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1'
        $script:ExpectedAuthorityCommit = '472cbd6f533d3f6d0a5381862128ebcc87618a7c'
        $script:ExpectedAuthorityArchiveSha256 = '357def24360566e9351af5c7b3bb8b8a7989f9ccb1eaf6f2401fa33e4069d8bf'
        $script:ExpectedAuthorityFiles = @(
            @{ path = 'docs/standards/README.md'; sha256 = '8aef64a9e69848c82d0ceba43f14c2876e3816cbc4761bac26a35e6f62aaf884' }
            @{ path = 'docs/standards/examples/third-party-raw-skill-source-v1.json'; sha256 = 'decbf276cbeea33c60d8b36b7b16838babe951cd84d13ae4a8a7a8261dc6d9c8' }
            @{ path = 'docs/standards/internal-source-continuation.json'; sha256 = '793019c1e3d6ebee607a017b4b8ca813a84a1b8c5371302e19c8431870d02066' }
            @{ path = 'docs/standards/managed-skill-lifecycle.md'; sha256 = '4e3f8595072d663f51d18aa28f42293fda5456362b49c0ea3f0157ae3dcf56dd' }
            @{ path = 'docs/standards/pr12-source-merge-adoption.json'; sha256 = '4c5262f2a11d228195230c15fa4faaf9614af6b59f110e5d9c08f242ce809175' }
            @{ path = 'docs/standards/schemas/internal-source-continuation-v1.schema.json'; sha256 = '559aaa9f7ec44f347ad9c431f57caaed017824bc7949a480658aa1f3af07f01c' }
            @{ path = 'docs/standards/schemas/internal-source-review-assessment-v1.schema.json'; sha256 = 'c25f810e1c6b7b8848c6deda87e8ad2c6b5df8f1073da9bfb9d078a2966fbd60' }
            @{ path = 'docs/standards/schemas/managed-skill-lifecycle-v1.schema.json'; sha256 = '9a7f4c02588d2b88194e953a41766a72a9426fa89d4c3781c5750dcc22d35863' }
            @{ path = 'docs/standards/schemas/openai-agent-metadata.schema.json'; sha256 = '23c1aaee28a54fea1946a61d6122a2097906ffa5bdd66c8014fc6b1625c9062a' }
            @{ path = 'docs/standards/schemas/source-inventory-v2.schema.json'; sha256 = '084550944b4141ab5535f58fb6e99730a5c34b56103f6b59fd5a352679caa98e' }
            @{ path = 'docs/standards/schemas/standard-core-adapter-v2.schema.json'; sha256 = '7399980e8765528b759a3734a133447eb9581ac24a9c4780dc8faadd6af0c1c5' }
            @{ path = 'docs/standards/schemas/standard-core-evidence-v2.schema.json'; sha256 = '7c083b9603b75518220e7e70e5704728a7e3dee0d5b5cf09dc9c755f49d64153' }
            @{ path = 'docs/standards/schemas/standard-semantic-consent-evidence-v2.schema.json'; sha256 = '109091979d0a47e2035d3d8b20963fcdb85680e5da737bf1f27121608115d430' }
            @{ path = 'docs/standards/schemas/standard-validation-adapter-v1.schema.json'; sha256 = '11aa88fc25716d748bd4f514f1a44f02390ad1745dd5a5c5beee07f642fd5639' }
            @{ path = 'docs/standards/schemas/standard-validation-evidence-v1.schema.json'; sha256 = 'e177a6832d055b51a440615fec65d01941b1b0c32bf468b962c8eb79750db924' }
            @{ path = 'docs/standards/schemas/skillspector-approved-sources-v1.schema.json'; sha256 = '20fa8516c9dcb7c9ae15f4682092dc583411db3149fac2641fef7b5182c3d12b' }
            @{ path = 'docs/standards/schemas/static-native-profile-execution-v1.schema.json'; sha256 = 'efca31987080d8ae213d32f51195de482802ccb3ca1b720991c75ce474dc264a' }
            @{ path = 'docs/standards/schemas/static-parser-host-ownership-v1.schema.json'; sha256 = 'f3184acc41597286be9440a41cbadb46f89a37ee84a0224c27c1adcef78e7591' }
            @{ path = 'docs/standards/schemas/static-parser-profile-execution-v1.schema.json'; sha256 = '7774f346293e6e7ff64ffffed527b7f6ef4012a1cfcb2f9ae0d4ad760c540077' }
            @{ path = 'docs/standards/schemas/third-party-raw-skill-source-v1.schema.json'; sha256 = '9d8585d95c606486f947a3f89e39341af840335376e86910eb7f4ed25bdc16ed' }
            @{ path = 'docs/standards/schemas/upstream-adapter-v1.schema.json'; sha256 = '3cff6246463188a91cc54c6a46315a949314767a759c6214e5b28e4db95ac8d7' }
            @{ path = 'docs/standards/schemas/validation-security-gate-v1.schema.json'; sha256 = 'b924b28a791f4d6eedcc0aa1c01fb62687ec863c0c17048093bfdd99aaa55b74' }
            @{ path = 'docs/standards/skill-repository-review-matrix.md'; sha256 = 'db0f898b2e59e0600abe3ec93684e561db339c82547d9035b18285f0285672ab' }
            @{ path = 'docs/standards/skill-repository-standard.md'; sha256 = 'a831a4151f8ea31e90709487af7823256ca4b119784823216a89ee8fcc85da35' }
            @{ path = 'docs/standards/skillspector-approved-sources.json'; sha256 = 'baaaf2a66e98f2c28a48fddd04051f09cf5498ef6c7978cbf45f5d415b69a330' }
            @{ path = 'docs/standards/standard-core-validation-v2.json'; sha256 = 'dd3c3d1bb83a439895ed35a949ff376b9d59d25e69063c86714eb42edaad84df' }
            @{ path = 'docs/standards/standard-validation-contract-v1.json'; sha256 = '2fa394ee48f940cdc2272c64199b90d95dea3665e1496df49cd0bd695cbdbe15' }
            @{ path = 'docs/standards/static-parser-host-ownership.json'; sha256 = '994acd989327d094d22ce2c68ca20eceec609f4e494f4e5d252cfcdef742de2c' }
            @{ path = 'docs/standards/third-party-raw-skill-sources.md'; sha256 = '18649fd56eada4a94a5d47de778669b0ebcecfb85b84f5c581d283b21979f7ac' }
            @{ path = 'docs/standards/trust-anchors/human-approval-public-key.xml'; sha256 = '1e46153b72d02f3ce2fb26becd449df4f1590d8e5cb441b1954006a5602bbd9b' }
            @{ path = 'docs/standards/trust-anchors/trusted-supervisor-public-key.xml'; sha256 = '4d550851f43405920156f40c9fc648d99a69dd73efc200f6968d8a837e7fbf27' }
            @{ path = 'docs/standards/upstream-adapter.json'; sha256 = 'c4f5133b24841bb9c66182dc3d5a027596f864ec28e410d47249a67b3b97ad31' }
            @{ path = 'docs/standards/upstream-interoperability.md'; sha256 = '8e48cc4831d151ffa4665433d79ad88e8871cb1d694861908dd0206406dcefe5' }
            @{ path = 'docs/standards/validation-security-gate.json'; sha256 = '1ab4c1208885a3aeb74654d8133426367134446e2b7519f06e63de3a53b16067' }
            @{ path = 'docs/standards/validation-toolchain.json'; sha256 = '001054854960563201d969a826db990f01ab93a2e87120ccc5ee42be8f8417d7' }
            @{ path = 'scripts/Get-StandardPowerShellSyntaxProof.ps1'; sha256 = '29104bd061d5e43540a0586c29830b28fd6f16367f3a7ffbf960980576d559cd' }
            @{ path = 'scripts/Invoke-StandardAuthorityGate.ps1'; sha256 = 'b4972681e79f788485e3925b737a7b0faac38a63c617450472758f2cc33798ef' }
            @{ path = 'scripts/Invoke-StandardStaticScan.ps1'; sha256 = '62686b6e8cab6bda6e6fa7164b03b76fd97aeb508c3f6fdc7643f4190ee9517f' }
            @{ path = 'scripts/Invoke-StandardValidation.ps1'; sha256 = '242b9e856d11dffffc512d03b60a7bd1f8ebad101d99cd97556488201b504350' }
            @{ path = 'scripts/Resolve-PythonWheelClosure.py'; sha256 = '45bd49b13acaee461ac38cbdd303016d74f516ae494d77cbd127366603c90681' }
            @{ path = 'scripts/Resolve-StandardValidationTool.ps1'; sha256 = 'c0d68b227fc04e19d710a89c4559fe45e0cc979eead846006261dc2dc5bfa14f' }
            @{ path = 'scripts/StandardSemanticBridge.psm1'; sha256 = '92595bdbb98ae77bdb2cc4dd7605ecc29f54e0a6746c9ee7d7636655f65665ef' }
            @{ path = 'scripts/Validate-UpstreamAdapter.ps1'; sha256 = '3b6e6474690b1ae9f9486544b68f50ca29b96f5dbe6aa8d6c6cd8570afad500b' }
            @{ path = 'scripts/WindowsDacl.psm1'; sha256 = 'ffa1f85d94bb6bce9bf8353f8c7733bdbe59880a3d0d075191938cc28aebb5f6' }
            @{ path = 'scripts/installer-safe-mutation.psm1'; sha256 = 'dc031edcc2f48968df83cd68ad52eacb7f7b05d3ca6a0cc622658cf6151c8293' }
            @{ path = 'scripts/platform-runtime.psd1'; sha256 = '7f112390d2995a105b9e9a916876df1779485dec6df21d7516243e2dcd1c4dca' }
            @{ path = 'scripts/platform-runtime.psm1'; sha256 = 'ad051b2794ce4dc10108404201735d02f7b032ed0e633c5f22f73c884fb10370' }
            @{ path = 'scripts/platform/Linux.psm1'; sha256 = '52c261d577ee7b3946771d1112030996896fdd119e06ac3849e430a3d56fb38c' }
            @{ path = 'scripts/platform/MacOS.psm1'; sha256 = '8f25edfbee5ab36b5e1c42eb55c6dbab44db0bc29896c180612b1248920c7c47' }
            @{ path = 'scripts/platform/OwnedProcess.cs'; sha256 = '097061ad5902f896ff74b3f60b0ecaf63f3d58f357aed8fdbf80a8586564de58' }
            @{ path = 'scripts/platform/PlatformNative.cs'; sha256 = 'f9da23bf3e6e3c8960b26d534e14873f6b4fc98b3d13f5b6cdfdd5f7716a4514' }
            @{ path = 'scripts/platform/RuntimePreparation.psm1'; sha256 = 'dc254c04e7e2caf280726e66f67434776bc7df12a210a38c80596e41344fd077' }
            @{ path = 'scripts/platform/Unix.psm1'; sha256 = 'ec3b3bb0b39e1ce84d4c8f60a78c44fb40cb9d58c13ed88a6b9d9db978fcc147' }
            @{ path = 'scripts/platform/UnixNative.cs'; sha256 = '996a8e4cc1c795f4732a9d7368e597b838c801d0710e32629cafcbba89f8c004' }
            @{ path = 'scripts/platform/UnixProcess.cs'; sha256 = '125d2b3eecdad6a6c201d5f5d61a6efd0ad55ba93822c7b83a679a5397005db1' }
            @{ path = 'scripts/platform/Windows.psm1'; sha256 = '9b7442178083a9b165ed3bf53367d5c3ce1b1f09d56f0f6efe964b524e17be0b' }
            @{ path = 'scripts/platform/WindowsInstallerMutation.cs'; sha256 = 'b88b4b09c7bb5c3e71b762ddc6ebe72007ed0cca99977ab7a7272529c3ff9218' }
            @{ path = 'scripts/platform/WindowsNative.cs'; sha256 = '6eea8ca2701b6a6de88ee4a3348f053d07a0543d607832e667335c838bb7d433' }
            @{ path = 'scripts/platform/WindowsProcess.cs'; sha256 = '7b8a0cddd3b9809b861801fe1d6a618684e2ca6fa13f9334825c5c9da5b2d8d6' }
            @{ path = 'scripts/standard_static_powershell.py'; sha256 = '53d807123ef21d7f89e46947d8e7eb5b6bafe39f55fdfa0c36c99bf7c6a74dca' }
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
        $adapter.centralRunner.runnerSha256 | Should -Be '242b9e856d11dffffc512d03b60a7bd1f8ebad101d99cd97556488201b504350'
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

    # Scenario: The source workflow initializes Pester before concurrent canonical tests.
    # Purpose: Preserve workflow gates and keep the shared Pester registry initialization ahead of source tool preparation.
    It 'InterT25_OrdersTheSharedPesterParentInitializationBeforeTheReadOnlySourceWorkflow' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml') -Raw
        $workflow | Should -Match '(?m)^  pull_request:'
        $workflow | Should -Match '(?m)^  push:'
        $workflow | Should -Match '(?m)^  contents: read\r?$'
        $workflow | Should -Match 'persist-credentials:\s*false'
        $workflow | Should -Match ([regex]::Escape('-File (Join-Path $baseRoot ''scripts/Validate.ps1'')'))
        ([regex]::Matches($workflow, '-PrepareSourceTools\b')).Count | Should -Be 1
        ([regex]::Matches($workflow, '-SourceValidation\b')).Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot 'tests/validate-windows-powershell.ps1') | Should -BeTrue
        $workflow | Should -Match '-RepositoryRoot \$candidateRoot -AdapterVersion 2'
        $workflow | Should -Not -Match '-SourceConformance|source_conformance:'
        $workflow | Should -Not -Match 'pull_request_target|checks:\s*write|STANDARD_V1_SUPERVISOR_LAUNCH_BINDING_PATH|publish-head-required-checks'
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml') | Should -BeFalse

        $initialization = [regex]::Match($workflow, '(?ms)^      - name: Initialize shared Pester registry parent\r?\n        shell: pwsh\r?\n        run: \|\r?\n(?<script>(?:          [^\r\n]*\r?\n)+)')
        $initialization.Success | Should -BeTrue
        $initialization.Index | Should -BeLessThan $workflow.IndexOf('      - name: Prepare source tools once with protected base driver and verify receipt', [StringComparison]::Ordinal)
        $initialization.Groups['script'].Value | Should -Match ([regex]::Escape("'Software\Pester'"))
    }

    # Registered only on the native Windows host: the initialization step writes the HKCU registry hive.
    if ($IsWindows) {
        # Scenario: The workflow's Pester initialization step runs concurrently against a fresh registry parent.
        # Purpose: Avoid first-use registry races without replacing existing test keys.
        It 'InterT30_InitializesTheSharedPesterParentConcurrentlyWithoutReplacingExistingKeys' {
            $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml') -Raw
            $initialization = [regex]::Match($workflow, '(?ms)^      - name: Initialize shared Pester registry parent\r?\n        shell: pwsh\r?\n        run: \|\r?\n(?<script>(?:          [^\r\n]*\r?\n)+)')
            $initialization.Success | Should -BeTrue
            $registrySubkey = 'Software\Pester\workflow-initialization-' + [guid]::NewGuid().ToString('N')
            $scriptText = $initialization.Groups['script'].Value.Replace("'Software\Pester'", "'$registrySubkey'")
            $scriptText | Should -Match ([regex]::Escape($registrySubkey))
            try {
                foreach ($wave in 1..2) {
                    $initialized = @(1..16 | ForEach-Object -Parallel {
                        $ErrorActionPreference = 'Stop'
                        & ([scriptblock]::Create($using:scriptText))
                        'initialized'
                    } -ThrottleLimit 8)
                    $initialized.Count | Should -Be 16
                    @($initialized | Where-Object { $_ -cne 'initialized' }).Count | Should -Be 0
                    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registrySubkey, $true)
                    try {
                        $key | Should -Not -BeNullOrEmpty
                        if ($wave -eq 1) {
                            $child = $key.CreateSubKey('existing-test-key')
                            try { $child.SetValue('sentinel', 'preserved') }
                            finally { $child.Dispose() }
                        }
                        else {
                            $child = $key.OpenSubKey('existing-test-key')
                            try { $child.GetValue('sentinel') | Should -Be 'preserved' }
                            finally { if ($null -ne $child) { $child.Dispose() } }
                        }
                    }
                    finally { if ($null -ne $key) { $key.Dispose() } }
                }
            }
            finally {
                [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($registrySubkey, $false)
            }
        }
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
        $sourceEntry | Should -Match "approvalId = 'atlassian-bitbucket-review-f2a12c6'"
        $sourceEntry | Should -Match "reviewedSourceRevision = 'f2a12c6338e9a76dc807c84329ffaae1aaf5bef4'"
        $sourceEntry | Should -Match "skillId = 'review-bitbucket-pull-request'"
        $sourceEntry | Should -Match "contentSha256 = 'b373f844d8c0a268f39fc1e613704cb22d3ce05136109d55c52096a9b6322e5c'"
        $sourceEntry | Should -Match "purpose = 'local-pr-review'"
        $sourceEntry | Should -Match "retainedFindingId = 'finding-1279bfce3ac3466f888a7b9f396e67c5'"
        $sourceEntry | Should -Match 'Central reader returned an unsafe internal Skill use decision'
    }

    # Scenario: Windows core.autocrlf is enabled while the internal-use registry binds Git blob bytes.
    # Purpose: Ensure the immutable candidate archive preserves the exact reviewed package identity.
    It 'UnitT20_PreservesApprovedBitbucketSkillBytesInGitArchive' {
        $attributes = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.gitattributes') -Raw
        # Every Skill keeps committed LF bytes on checkout so exact SkillSpector fingerprints match on Windows.
        $attributes | Should -Match '(?m)^/skills/\*\* text eol=lf\r?$'

        $expected = [ordered]@{
            'SKILL.md' = '4c04e978525da05658b4f3d5832c93c247e67e84c2386de852a6cd633be3f131'
            'agents/openai.yaml' = '7e47144aaa1256f09d9ddba009633299cf7323666369852dbf4bf05151e41fb0'
            'references/bitbucket-cloud-api.md' = 'b2f0de462e3bcc7ccfc13ccc7bf293441d808254bbc61a4eaab44cd38fee6f4d'
            'references/review-actions.md' = '6719f2b1991221c8eab71dbd919ff99a082afdd4b05c7dd882e7a391af8b5363'
            'scripts/Invoke-BitbucketReviewActions.ps1' = '6f2ef0ff6522e1736c8ca960ee7d01e2bb952ba36dd0a247dc31f7bd65b411ee'
        }
        $actualHashes = [ordered]@{}
        if (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.git')) {
            $archivePath = Join-Path $TestDrive 'approved-bitbucket-skill.zip'
            & git -C $script:RepositoryRoot archive --format=zip "--output=$archivePath" HEAD -- 'skills/review-bitbucket-pull-request'
            $LASTEXITCODE | Should -Be 0
            Test-Path -LiteralPath $archivePath -PathType Leaf | Should -BeTrue

            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
            try {
                foreach ($item in $expected.GetEnumerator()) {
                    $memberPath = "skills/review-bitbucket-pull-request/$($item.Key)"
                    $matches = @($archive.Entries | Where-Object { $_.FullName -ceq $memberPath })
                    $matches.Count | Should -Be 1
                    $stream = $matches[0].Open()
                    $sha = [Security.Cryptography.SHA256]::Create()
                    try { $actualHashes[$item.Key] = [Convert]::ToHexString($sha.ComputeHash($stream)).ToLowerInvariant() }
                    finally { $sha.Dispose(); $stream.Dispose() }
                }
            }
            finally { $archive.Dispose() }
        }
        else {
            # Formal source validation runs Pester from the immutable candidate archive,
            # where these are already the exact post-archive bytes and no .git exists.
            foreach ($item in $expected.GetEnumerator()) {
                $path = Join-Path $script:RepositoryRoot "skills/review-bitbucket-pull-request/$($item.Key)"
                Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
                $actualHashes[$item.Key] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }

        foreach ($item in $expected.GetEnumerator()) {
            $actualHashes[$item.Key] | Should -Be $item.Value
        }
    }

    # Scenario: Three independent Pester files are scheduled with a concurrency limit of two.
    # Purpose: Preserve the complete test-file inventory while proving that repository tests can overlap safely.
    It 'UnitT30_RunsEveryPesterFileOnceWithBoundedConcurrency' {
        $helperPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-ShardedPester.ps1'
        Test-Path -LiteralPath $helperPath -PathType Leaf | Should -BeTrue

        $fixtureRoot = Join-Path $TestDrive 'successful-shards'
        $testsRoot = Join-Path $fixtureRoot 'tests'
        $workingRoot = Join-Path $fixtureRoot 'work'
        $resultPath = Join-Path $fixtureRoot 'result.json'
        [void](New-Item -ItemType Directory -Path $testsRoot -Force)
        foreach ($name in @('a', 'b', 'c')) {
            $source = @"
Describe '$name shard' {
    It 'UnitT10_CompletesThe$name shard' {
        Start-Sleep -Milliseconds 600
        1 | Should -Be 1
    }
}
"@
            [IO.File]::WriteAllText((Join-Path $testsRoot "$name.Tests.ps1"), $source, [Text.UTF8Encoding]::new($false))
        }

        $pester = Get-Module Pester | Select-Object -First 1
        $pesterManifest = Join-Path $pester.ModuleBase 'Pester.psd1'
        $powerShellPath = (Get-Process -Id $PID).Path
        & $powerShellPath -NoProfile -NonInteractive -File $helperPath `
            -PesterModulePath $pesterManifest `
            -ExpectedPesterVersion ([string]$pester.Version) `
            -TestsRoot $testsRoot `
            -WorkingRoot $workingRoot `
            -ResultPath $resultPath `
            -MaxConcurrency 2
        $LASTEXITCODE | Should -Be 0

        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -Depth 20
        $result.marker | Should -Be 'atlassian-pester-result-v3'
        $result.testFileCount | Should -Be 3
        @($result.testFiles) | Should -Be @('a.Tests.ps1', 'b.Tests.ps1', 'c.Tests.ps1')
        $result.TotalCount | Should -Be 3
        $result.PassedCount | Should -Be 3
        $result.FailedCount | Should -Be 0
        $result.FailedContainersCount | Should -Be 0
        $result.maxObservedConcurrency | Should -Be 2
    }

    # Scenario: A worker's moved claim path can disappear before the worker reopens it on the host filesystem.
    # Purpose: Capture the immutable queue payload before the atomic move so a successful claim never depends on reopening its destination path.
    It 'UnitT35_CapturesTheQueuePayloadBeforePublishingTheAtomicClaim' {
        $helperPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-ShardedPester.ps1'
        $source = Get-Content -LiteralPath $helperPath -Raw
        $readIndex = $source.IndexOf('$taskJson = [IO.File]::ReadAllText($sourcePath', [StringComparison]::Ordinal)
        $moveIndex = $source.IndexOf('[IO.File]::Move($sourcePath, $destinationPath)', [StringComparison]::Ordinal)
        $parseIndex = $source.IndexOf('$task = $taskJson |', [StringComparison]::Ordinal)
        $readIndex | Should -BeGreaterThan -1
        $moveIndex | Should -BeGreaterThan $readIndex
        $parseIndex | Should -BeGreaterThan $moveIndex
        $source | Should -Not -Match '\[IO\.File\]::ReadAllText\(\$claimedPath'
    }

    # Scenario: A two-shard file and a one-shard file share a single worker, so queue order is directly observable.
    # Purpose: Start every shard from the largest discovered-definition inventory before smaller files can leave an expensive tail shard on the critical path.
    It 'UnitT37_ClaimsEveryShardFromTheLargestDefinitionInventoryFirst' {
        $helperPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-ShardedPester.ps1'
        $fixtureRoot = Join-Path $TestDrive 'largest-inventory-first'
        $testsRoot = Join-Path $fixtureRoot 'tests'
        $workingRoot = Join-Path $fixtureRoot 'work'
        $resultPath = Join-Path $fixtureRoot 'result.json'
        $markerPath = Join-Path $fixtureRoot 'claim-order.txt'
        [void](New-Item -ItemType Directory -Path $testsRoot -Force)
        $markerLiteral = $markerPath.Replace("'", "''")
        [IO.File]::WriteAllText((Join-Path $testsRoot 'large.Tests.ps1'), @'
Describe 'large inventory' {
    It 'UnitT10_CompletesTheFirstLargeShard' {
        [IO.File]::AppendAllText('__MARKER__', "large-1`n")
        1 | Should -Be 1
    }
    It 'UnitT20_CompletesTheSecondLargeShard' {
        [IO.File]::AppendAllText('__MARKER__', "large-2`n")
        2 | Should -Be 2
    }
}
'@.Replace('__MARKER__', $markerLiteral), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $testsRoot 'small.Tests.ps1'), @'
Describe 'small inventory' {
    It 'UnitT10_CompletesTheSmallShard' {
        [IO.File]::AppendAllText('__MARKER__', "small`n")
        3 | Should -Be 3
    }
}
'@.Replace('__MARKER__', $markerLiteral), [Text.UTF8Encoding]::new($false))

        $pester = Get-Module Pester | Select-Object -First 1
        $pesterManifest = Join-Path $pester.ModuleBase 'Pester.psd1'
        $powerShellPath = (Get-Process -Id $PID).Path
        & $powerShellPath -NoProfile -NonInteractive -File $helperPath `
            -PesterModulePath $pesterManifest `
            -ExpectedPesterVersion ([string]$pester.Version) `
            -TestsRoot $testsRoot `
            -WorkingRoot $workingRoot `
            -ResultPath $resultPath `
            -MaxConcurrency 1 `
            -MaxCasesPerShard 1
        $LASTEXITCODE | Should -Be 0

        @(Get-Content -LiteralPath $markerPath) | Should -Be @('large-1', 'large-2', 'small')
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -Depth 20
        $result.TotalCount | Should -Be 3
        $result.PassedCount | Should -Be 3
        $result.shardCount | Should -Be 3
    }

    # Scenario: Four definitions have selector names whose ordinal order differs from their source-line order.
    # Purpose: Use source order for round-robin grouping so adjacent boundary cases are distributed across shards instead of clustering by selector text.
    It 'UnitT38_DistributesDefinitionsBySourceOrderBeforeSharding' {
        $helperPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-ShardedPester.ps1'
        $fixtureRoot = Join-Path $TestDrive 'source-ordered-shards'
        $testsRoot = Join-Path $fixtureRoot 'tests'
        $workingRoot = Join-Path $fixtureRoot 'work'
        $resultPath = Join-Path $fixtureRoot 'result.json'
        $markerPath = Join-Path $fixtureRoot 'execution-order.txt'
        [void](New-Item -ItemType Directory -Path $testsRoot -Force)
        $markerLiteral = $markerPath.Replace("'", "''")
        [IO.File]::WriteAllText((Join-Path $testsRoot 'ordered.Tests.ps1'), @'
Describe 'source order' {
    It 'UnitT90_Zeta' { [IO.File]::AppendAllText('__MARKER__', "zeta`n"); 1 | Should -Be 1 }
    It 'UnitT10_Alpha' { [IO.File]::AppendAllText('__MARKER__', "alpha`n"); 2 | Should -Be 2 }
    It 'UnitT80_Yankee' { [IO.File]::AppendAllText('__MARKER__', "yankee`n"); 3 | Should -Be 3 }
    It 'UnitT20_Beta' { [IO.File]::AppendAllText('__MARKER__', "beta`n"); 4 | Should -Be 4 }
}
'@.Replace('__MARKER__', $markerLiteral), [Text.UTF8Encoding]::new($false))

        $pester = Get-Module Pester | Select-Object -First 1
        $pesterManifest = Join-Path $pester.ModuleBase 'Pester.psd1'
        $powerShellPath = (Get-Process -Id $PID).Path
        & $powerShellPath -NoProfile -NonInteractive -File $helperPath `
            -PesterModulePath $pesterManifest `
            -ExpectedPesterVersion ([string]$pester.Version) `
            -TestsRoot $testsRoot `
            -WorkingRoot $workingRoot `
            -ResultPath $resultPath `
            -MaxConcurrency 1 `
            -MaxCasesPerShard 2
        $LASTEXITCODE | Should -Be 0

        @(Get-Content -LiteralPath $markerPath) | Should -Be @('zeta', 'yankee', 'alpha', 'beta')
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -Depth 20
        $result.discoveredDefinitionCount | Should -Be 4
        $result.TotalCount | Should -Be 4
        $result.shardCount | Should -Be 2
    }

    # Scenario: Two priority shards must both finish before a regular shard records its marker.
    # Purpose: Put expensive inventory at the front of one bounded queue without reserving or stranding worker capacity.
    It 'UnitT39_SchedulesPriorityShardsAtTheFrontOfOneBoundedQueue' {
        $helperPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-ShardedPester.ps1'
        $fixtureRoot = Join-Path $TestDrive 'priority-shards'
        $testsRoot = Join-Path $fixtureRoot 'tests'
        $workingRoot = Join-Path $fixtureRoot 'work'
        $resultPath = Join-Path $fixtureRoot 'result.json'
        [void](New-Item -ItemType Directory -Path $testsRoot -Force)
        $firstStart = Join-Path $fixtureRoot 'priority-first-start.txt'
        $secondStart = Join-Path $fixtureRoot 'priority-second-start.txt'
        $firstDone = Join-Path $fixtureRoot 'priority-first-done.txt'
        $secondDone = Join-Path $fixtureRoot 'priority-second-done.txt'
        $normalDone = Join-Path $fixtureRoot 'normal-done.txt'
        $pidRoot = Join-Path $fixtureRoot 'priority-pids'
        [void](New-Item -ItemType Directory -Path $pidRoot)
        $prioritySource = @'
Describe 'priority inventory' {
    It 'UnitT10_UsesTheFirstPriorityWorker' {
        [IO.File]::WriteAllText('__FIRST_START__', 'started')
        [IO.File]::WriteAllText((Join-Path '__PID_ROOT__' 'first.txt'), [string]$PID)
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        while (-not (Test-Path -LiteralPath '__SECOND_START__') -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
        Test-Path -LiteralPath '__SECOND_START__' | Should -BeTrue
        [IO.File]::WriteAllText('__FIRST_DONE__', 'done')
    }
    It 'UnitT20_UsesTheSecondPriorityWorker' {
        [IO.File]::WriteAllText('__SECOND_START__', 'started')
        [IO.File]::WriteAllText((Join-Path '__PID_ROOT__' 'second.txt'), [string]$PID)
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        while (-not (Test-Path -LiteralPath '__FIRST_START__') -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
        Test-Path -LiteralPath '__FIRST_START__' | Should -BeTrue
        [IO.File]::WriteAllText('__SECOND_DONE__', 'done')
    }
}
'@
        $pathTokens = [ordered]@{
            '__FIRST_START__' = $firstStart; '__SECOND_START__' = $secondStart
            '__FIRST_DONE__' = $firstDone; '__SECOND_DONE__' = $secondDone
            '__PID_ROOT__' = $pidRoot
        }
        foreach ($entry in $pathTokens.GetEnumerator()) { $prioritySource = $prioritySource.Replace($entry.Key, $entry.Value.Replace("'", "''")) }
        [IO.File]::WriteAllText((Join-Path $testsRoot 'priority.Tests.ps1'), $prioritySource, [Text.UTF8Encoding]::new($false))
        $normalSource = @'
Describe 'normal inventory' {
    It 'UnitT10_RunsAfterPriorityInventory' {
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        while ((-not (Test-Path -LiteralPath '__FIRST_DONE__') -or -not (Test-Path -LiteralPath '__SECOND_DONE__')) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
        @(Test-Path -LiteralPath '__FIRST_DONE__', '__SECOND_DONE__') | Should -Not -Contain $false
        [IO.File]::WriteAllText('__NORMAL_DONE__', 'done')
    }
}
'@
        $normalSource = $normalSource.Replace('__FIRST_DONE__', $firstDone.Replace("'", "''")).Replace('__SECOND_DONE__', $secondDone.Replace("'", "''")).Replace('__NORMAL_DONE__', $normalDone.Replace("'", "''"))
        [IO.File]::WriteAllText((Join-Path $testsRoot 'normal.Tests.ps1'), $normalSource, [Text.UTF8Encoding]::new($false))

        $pester = Get-Module Pester | Select-Object -First 1
        $pesterManifest = Join-Path $pester.ModuleBase 'Pester.psd1'
        $powerShellPath = (Get-Process -Id $PID).Path
        & $powerShellPath -NoProfile -NonInteractive -File $helperPath `
            -PesterModulePath $pesterManifest `
            -ExpectedPesterVersion ([string]$pester.Version) `
            -TestsRoot $testsRoot `
            -WorkingRoot $workingRoot `
            -ResultPath $resultPath `
            -MaxConcurrency 2 `
            -MaxCasesPerShard 6 `
            -PriorityTestFilesJson '["priority.Tests.ps1"]' `
            -FineGrainedTestFilesJson '["priority.Tests.ps1"]'
        $LASTEXITCODE | Should -Be 0

        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -Depth 20
        @($result.priorityTestFiles) | Should -Be @('priority.Tests.ps1')
        $result.priorityShardCount | Should -Be 2
        $result.priorityScheduling | Should -Be 'queue-front'
        @($result.fineGrainedTestFiles) | Should -Be @('priority.Tests.ps1')
        $result.shardCount | Should -Be 3
        $result.workerCount | Should -Be 2
        $result.maxObservedConcurrency | Should -Be 2
        $result.TotalCount | Should -Be 3
        $result.PassedCount | Should -Be 3
        $result.FailedCount | Should -Be 0
        Test-Path -LiteralPath $normalDone -PathType Leaf | Should -BeTrue
        $pids = @(Get-ChildItem -LiteralPath $pidRoot -File | Sort-Object Name | ForEach-Object { (Get-Content -LiteralPath $_.FullName -Raw).Trim() })
        @($pids | Select-Object -Unique).Count | Should -Be 2
    }

    # Scenario: One Pester file fails while a second file passes in a separate worker.
    # Purpose: Require complete aggregation so sharding cannot hide a failed file or discard the passing inventory.
    It 'UnitT40_AggregatesFailedAndPassingPesterFiles' {
        $helperPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-ShardedPester.ps1'
        Test-Path -LiteralPath $helperPath -PathType Leaf | Should -BeTrue

        $fixtureRoot = Join-Path $TestDrive 'failed-shards'
        $testsRoot = Join-Path $fixtureRoot 'tests'
        $workingRoot = Join-Path $fixtureRoot 'work'
        $resultPath = Join-Path $fixtureRoot 'result.json'
        [void](New-Item -ItemType Directory -Path $testsRoot -Force)
        [IO.File]::WriteAllText((Join-Path $testsRoot 'pass.Tests.ps1'), @'
Describe 'passing shard' {
    It 'UnitT10_Passes' { 1 | Should -Be 1 }
}
'@, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $testsRoot 'fail.Tests.ps1'), @'
Describe 'failing shard' {
    It 'UnitT10_Fails' { 1 | Should -Be 2 }
}
'@, [Text.UTF8Encoding]::new($false))

        $pester = Get-Module Pester | Select-Object -First 1
        $pesterManifest = Join-Path $pester.ModuleBase 'Pester.psd1'
        $powerShellPath = (Get-Process -Id $PID).Path
        & $powerShellPath -NoProfile -NonInteractive -File $helperPath `
            -PesterModulePath $pesterManifest `
            -ExpectedPesterVersion ([string]$pester.Version) `
            -TestsRoot $testsRoot `
            -WorkingRoot $workingRoot `
            -ResultPath $resultPath `
            -MaxConcurrency 2
        $LASTEXITCODE | Should -Be 0

        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -Depth 20
        $result.testFileCount | Should -Be 2
        @($result.testFiles) | Should -Be @('fail.Tests.ps1', 'pass.Tests.ps1')
        $result.TotalCount | Should -Be 2
        $result.PassedCount | Should -Be 1
        $result.FailedCount | Should -Be 1
        @($result.failures).Count | Should -BeGreaterThan 0
    }

    # Scenario: Six discovered cases span three files, including one file that requires two case shards.
    # Purpose: Preserve every case exactly once and run workers from the candidate root expected by repository tests.
    It 'UnitT45_SplitsDiscoveredCasesAndUsesTheCandidateWorkingDirectory' {
        $helperPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-ShardedPester.ps1'
        Test-Path -LiteralPath $helperPath -PathType Leaf | Should -BeTrue

        $fixtureRoot = Join-Path $TestDrive 'case-and-exclusive-shards'
        $testsRoot = Join-Path $fixtureRoot 'tests'
        $workingRoot = Join-Path $fixtureRoot 'work'
        $resultPath = Join-Path $fixtureRoot 'result.json'
        [void](New-Item -ItemType Directory -Path $testsRoot -Force)
        $fixtureRootLiteral = $fixtureRoot.Replace("'", "''")
        $parallelSource = @'
Describe 'parallel file' {
    It 'UnitT10_UsesTheCandidateRoot' {
        (Get-Location).Path | Should -Be '__CANDIDATE_ROOT__'
        ([pscustomobject]@{}).MissingProperty | Should -BeNullOrEmpty
        Start-Sleep -Milliseconds 300
    }
}
'@.Replace('__CANDIDATE_ROOT__', $fixtureRootLiteral)
        [IO.File]::WriteAllText((Join-Path $testsRoot 'parallel.Tests.ps1'), $parallelSource, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $testsRoot 'capture.Tests.ps1'), @'
Describe 'capture cases' {
    It 'UnitT10_CapturesFirst' { Start-Sleep -Milliseconds 150; 1 | Should -Be 1 }
    It 'UnitT20_CapturesSecond' { Start-Sleep -Milliseconds 150; 1 | Should -Be 1 }
    It 'UnitT30_CapturesThird' { Start-Sleep -Milliseconds 150; 1 | Should -Be 1 }
    It 'UnitT40_CapturesFourth' { Start-Sleep -Milliseconds 150; 1 | Should -Be 1 }
}
'@, [Text.UTF8Encoding]::new($false))
        $singleSource = @'
Describe 'single case file' {
    It 'UnitT10_Completes' {
        1 | Should -Be 1
    }
}
'@
        [IO.File]::WriteAllText((Join-Path $testsRoot 'single.Tests.ps1'), $singleSource, [Text.UTF8Encoding]::new($false))

        $pester = Get-Module Pester | Select-Object -First 1
        $pesterManifest = Join-Path $pester.ModuleBase 'Pester.psd1'
        $powerShellPath = (Get-Process -Id $PID).Path
        & $powerShellPath -NoProfile -NonInteractive -File $helperPath `
            -PesterModulePath $pesterManifest `
            -ExpectedPesterVersion ([string]$pester.Version) `
            -TestsRoot $testsRoot `
            -WorkingRoot $workingRoot `
            -ResultPath $resultPath `
            -MaxConcurrency 2 `
            -MaxCasesPerShard 2
        $LASTEXITCODE | Should -Be 0

        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -Depth 20
        $result.marker | Should -Be 'atlassian-pester-result-v3'
        $result.testFileCount | Should -Be 3
        $result.shardCount | Should -Be 4
        $result.workerCount | Should -Be 2
        $result.schedulerMode | Should -Be 'persistent-work-stealing'
        $result.discoveredDefinitionCount | Should -Be 6
        $result.shardedFileCount | Should -Be 1
        $result.maxCasesPerShard | Should -Be 2
        $result.TotalCount | Should -Be 6
        $result.PassedCount | Should -Be 6
        $result.FailedCount | Should -Be 0
    }

    # Scenario: Two data-driven cases expose the same expanded Pester identity.
    # Purpose: Run the ambiguous file once without a filter while preserving both discovered case instances.
    It 'UnitT47_RunsDuplicateCaseIdentitiesAsOneUnfilteredFileShard' {
        $helperPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-ShardedPester.ps1'
        $fixtureRoot = Join-Path $TestDrive 'duplicate-case-identities'
        $testsRoot = Join-Path $fixtureRoot 'tests'
        $workingRoot = Join-Path $fixtureRoot 'work'
        $resultPath = Join-Path $fixtureRoot 'result.json'
        [void](New-Item -ItemType Directory -Path $testsRoot -Force)
        [IO.File]::WriteAllText((Join-Path $testsRoot 'duplicate.Tests.ps1'), @'
Describe 'duplicate identities' {
    It 'UnitT10_Completes' { 1 | Should -Be 1 }
    It 'UnitT10_Completes' { 2 | Should -Be 2 }
}
'@, [Text.UTF8Encoding]::new($false))

        $pester = Get-Module Pester | Select-Object -First 1
        $pesterManifest = Join-Path $pester.ModuleBase 'Pester.psd1'
        $powerShellPath = (Get-Process -Id $PID).Path
        & $powerShellPath -NoProfile -NonInteractive -File $helperPath `
            -PesterModulePath $pesterManifest `
            -ExpectedPesterVersion ([string]$pester.Version) `
            -TestsRoot $testsRoot `
            -WorkingRoot $workingRoot `
            -ResultPath $resultPath `
            -MaxConcurrency 2 `
            -MaxCasesPerShard 1
        $LASTEXITCODE | Should -Be 0

        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -Depth 20
        $result.marker | Should -Be 'atlassian-pester-result-v3'
        $result.testFileCount | Should -Be 1
        $result.discoveredDefinitionCount | Should -Be 2
        $result.duplicateSelectorFileCount | Should -Be 1
        $result.workerCount | Should -Be 1
        $result.TotalCount | Should -Be 2
        $result.PassedCount | Should -Be 2
        $result.FailedCount | Should -Be 0
    }

    # Scenario: One data-driven definition expands to two runtime cases beside one ordinary definition.
    # Purpose: Validate each definition exactly once while retaining every expanded case in aggregate counts.
    It 'UnitT48_MapsExpandedDataRowsBackToTheirAssignedDefinition' {
        $helperPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-ShardedPester.ps1'
        $fixtureRoot = Join-Path $TestDrive 'data-driven-definitions'
        $testsRoot = Join-Path $fixtureRoot 'tests'
        $workingRoot = Join-Path $fixtureRoot 'work'
        $resultPath = Join-Path $fixtureRoot 'result.json'
        [void](New-Item -ItemType Directory -Path $testsRoot -Force)
        [IO.File]::WriteAllText((Join-Path $testsRoot 'data.Tests.ps1'), @'
Describe 'data rows' {
    It 'UnitT10_Expands_<Value>' -TestCases @(@{ Value = 1 }, @{ Value = 2 }) {
        $Value | Should -BeIn @(1, 2)
    }
    It 'UnitT20_Completes' { 3 | Should -Be 3 }
}
'@, [Text.UTF8Encoding]::new($false))

        $pester = Get-Module Pester | Select-Object -First 1
        $pesterManifest = Join-Path $pester.ModuleBase 'Pester.psd1'
        $powerShellPath = (Get-Process -Id $PID).Path
        & $powerShellPath -NoProfile -NonInteractive -File $helperPath `
            -PesterModulePath $pesterManifest `
            -ExpectedPesterVersion ([string]$pester.Version) `
            -TestsRoot $testsRoot `
            -WorkingRoot $workingRoot `
            -ResultPath $resultPath `
            -MaxConcurrency 2 `
            -MaxCasesPerShard 1
        $LASTEXITCODE | Should -Be 0

        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -Depth 20
        $result.discoveredDefinitionCount | Should -Be 2
        $result.duplicateSelectorFileCount | Should -Be 0
        $result.workerCount | Should -Be 2
        $result.TotalCount | Should -Be 3
        $result.PassedCount | Should -Be 3
        $result.FailedCount | Should -Be 0
    }

    # Scenario: Two priority shards fill a two-worker bound before a queue-boundary recycle token releases one slot for exclusive work.
    # Purpose: Start the exclusive whole-file shard in a fresh process after priority work while preserving overlap and exact regular coverage.
    It 'UnitT49_ReplenishesTheDedicatedWorkerWithoutReusingIt' {
        $helperPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-ShardedPester.ps1'
        $fixtureRoot = Join-Path $TestDrive 'whole-file-lifecycle'
        $testsRoot = Join-Path $fixtureRoot 'tests'
        $workingRoot = Join-Path $fixtureRoot 'work'
        $resultPath = Join-Path $fixtureRoot 'result.json'
        $lifecycleStartPath = Join-Path $fixtureRoot 'lifecycle-start.txt'
        $regularStartPath = Join-Path $fixtureRoot 'regular-start.txt'
        $lifecyclePidPath = Join-Path $fixtureRoot 'lifecycle-pid.txt'
        $regularPidPath = Join-Path $fixtureRoot 'regular-pids.txt'
        $regularSecondStartPath = Join-Path $fixtureRoot 'regular-second-start.txt'
        [void](New-Item -ItemType Directory -Path $testsRoot -Force)
        $lifecycleSource = @'
Describe 'whole file lifecycle' {
    It 'UnitT10_OverlapsRegularWork' {
        [IO.File]::WriteAllText('__LIFECYCLE_PID__', [string]$PID)
        [IO.File]::WriteAllText('__LIFECYCLE_START__', 'started')
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        while (-not (Test-Path -LiteralPath '__REGULAR_START__') -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
        Test-Path -LiteralPath '__REGULAR_START__' | Should -BeTrue
    }
}
'@
        $lifecycleSource = $lifecycleSource.Replace('__LIFECYCLE_PID__', $lifecyclePidPath.Replace("'", "''")).Replace('__LIFECYCLE_START__', $lifecycleStartPath.Replace("'", "''")).Replace('__REGULAR_START__', $regularStartPath.Replace("'", "''"))
        [IO.File]::WriteAllText((Join-Path $testsRoot 'lifecycle.Tests.ps1'), $lifecycleSource, [Text.UTF8Encoding]::new($false))
        $regularSource = @'
Describe 'regular file' {
    It 'UnitT10_OverlapsLifecycleWork' {
        [IO.File]::AppendAllText('__REGULAR_PIDS__', [string]$PID + [Environment]::NewLine)
        [IO.File]::WriteAllText('__REGULAR_START__', 'started')
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        while ((-not (Test-Path -LiteralPath '__LIFECYCLE_START__') -or -not (Test-Path -LiteralPath '__REGULAR_SECOND_START__')) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 25
        }
        Test-Path -LiteralPath '__LIFECYCLE_START__' | Should -BeTrue
        Test-Path -LiteralPath '__REGULAR_SECOND_START__' | Should -BeTrue
    }
    It 'UnitT20_ReusesTheRegularWorker' {
        [IO.File]::AppendAllText('__REGULAR_PIDS__', [string]$PID + [Environment]::NewLine)
        [IO.File]::WriteAllText('__REGULAR_SECOND_START__', 'started')
        2 | Should -Be 2
    }
}
'@
        $regularSource = $regularSource.Replace('__REGULAR_PIDS__', $regularPidPath.Replace("'", "''")).Replace('__REGULAR_START__', $regularStartPath.Replace("'", "''")).Replace('__REGULAR_SECOND_START__', $regularSecondStartPath.Replace("'", "''")).Replace('__LIFECYCLE_START__', $lifecycleStartPath.Replace("'", "''"))
        [IO.File]::WriteAllText((Join-Path $testsRoot 'regular.Tests.ps1'), $regularSource, [Text.UTF8Encoding]::new($false))

        $pester = Get-Module Pester | Select-Object -First 1
        $pesterManifest = Join-Path $pester.ModuleBase 'Pester.psd1'
        $powerShellPath = (Get-Process -Id $PID).Path
        & $powerShellPath -NoProfile -NonInteractive -File $helperPath `
            -PesterModulePath $pesterManifest `
            -ExpectedPesterVersion ([string]$pester.Version) `
            -TestsRoot $testsRoot `
            -WorkingRoot $workingRoot `
            -ResultPath $resultPath `
            -MaxConcurrency 2 `
            -MaxCasesPerShard 1 `
            -PriorityTestFilesJson '["regular.Tests.ps1"]' `
            -ExclusiveTestFilesJson '["lifecycle.Tests.ps1"]'
        $LASTEXITCODE | Should -Be 0

        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -Depth 20
        @($result.exclusiveTestFiles) | Should -Be @('lifecycle.Tests.ps1')
        $result.exclusiveShardCount | Should -Be 1
        @($result.priorityTestFiles) | Should -Be @('regular.Tests.ps1')
        $result.priorityShardCount | Should -Be 2
        $result.shardCount | Should -Be 3
        $result.workerCount | Should -Be 3
        $result.maxObservedConcurrency | Should -Be 2
        $result.TotalCount | Should -Be 3
        $result.PassedCount | Should -Be 3
        $result.FailedCount | Should -Be 0
        $lifecyclePid = (Get-Content -LiteralPath $lifecyclePidPath -Raw).Trim()
        $regularPids = @(Get-Content -LiteralPath $regularPidPath)
        $regularPids.Count | Should -Be 2
        @($regularPids | Select-Object -Unique).Count | Should -Be 2
        $regularPids | Should -Not -Contain $lifecyclePid
    }

    # Scenario: Source validation executes the full repository suite after package and internal-use checks.
    # Purpose: Bind the production adapter to bounded sharding instead of one 900-second Pester process.
    It 'UnitT51_UsesTheBoundedPesterHelperForRepositoryTests' {
        $sourceEntry = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1') -Raw
        $sourceEntry | Should -Match 'Invoke-ShardedPester\.ps1'
        $sourceEntry | Should -Match "'-MaxConcurrency', '12'"
        $sourceEntry | Should -Match "'-MaxCasesPerShard', '6'"
        $sourceEntry | Should -Not -Match "'-PriorityConcurrency'"
        $sourceEntry | Should -Match "'-PriorityTestFilesJson'"
        foreach ($priorityFile in @(
            'AtomicOutput.Tests.ps1',
            'ConfluenceDocs.CodeBinding.Tests.ps1',
            'ConfluenceDocs.MarkdownPreview.Tests.ps1',
            'ConfluenceDocs.MarkdownPushCli.Tests.ps1',
            'RepositoryValidation.Tests.ps1',
            'Test-Repository.Tests.ps1',
            'ConfluenceDocs.MarkdownCli.Tests.ps1',
            'SourceStaticBridge.Tests.ps1',
            'CentralRunner.Tests.ps1',
            'ConfluenceDocs.AttachmentBatch.Tests.ps1',
            'ConfluenceDocs.Publish.MultiPage.Tests.ps1',
            'ConfluenceDocs.CreatePublish.Tests.ps1',
            'ConfluenceDocs.AttachmentPreview.Tests.ps1',
            'ConfluenceDocs.MarkdownPlan.Tests.ps1',
            'ConfluenceDocs.ApiBaseStructure.Tests.ps1',
            'ConfluenceDocs.Sync.Tests.ps1',
            'ConfluenceDocs.ApiBaseIdentity.Tests.ps1',
            'ConfluenceDocs.AttachmentCreate.Tests.ps1'
        )) {
            $sourceEntry | Should -Match ([regex]::Escape($priorityFile))
        }
        $sourceEntry | Should -Match "'-FineGrainedTestFilesJson'"
        $sourceEntry | Should -Match '\["ConfluenceDocs\.MarkdownPushCli\.Tests\.ps1"\]'
        $sourceEntry | Should -Match "'-ExclusiveTestFilesJson'"
        $sourceEntry | Should -Match '\["CanonicalValidation\.Tests\.ps1","ProtectedRunner\.Tests\.ps1"\]'
        $sourceEntry | Should -Not -Match '\$run = Invoke-Pester -Path \$env:AEV1_PESTER_TESTS'
    }

    # Scenario: Four independent fake resolvers run concurrently while the parent carries repository-token sentinels.
    # Purpose: Preserve token access for SkillSpector acquisition while preventing the other downloaded tools from inheriting GitHub credentials.
    It 'UnitT55_ResolvesTheFourValidationToolsConcurrentlyWithScopedRepositoryCredentials' {
        $helperPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-ParallelToolResolution.ps1'
        Test-Path -LiteralPath $helperPath -PathType Leaf | Should -BeTrue

        $fixtureRoot = Join-Path $TestDrive 'parallel-resolver-success'
        $resolverPath = Join-Path $fixtureRoot 'fake-resolver.ps1'
        $policyPath = Join-Path $fixtureRoot 'policy.json'
        $installRoot = Join-Path $fixtureRoot 'installs'
        $outputRoot = Join-Path $fixtureRoot 'outputs'
        $summaryPath = Join-Path $fixtureRoot 'summary.json'
        [void](New-Item -ItemType Directory -Path $fixtureRoot -Force)
        [IO.File]::WriteAllText($policyPath, '{}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($resolverPath, @'
param([string]$PolicyPath,[string]$ToolName,[switch]$Install,[string]$InstallRoot,[string]$ExpectedGoRuntimeVersion,[string]$RunId,[string]$OutputPath)
Start-Sleep -Seconds 2
$receipt=[ordered]@{
    toolName=$ToolName;channel='latest-stable';frozenForRun=$true;resolutionRunId=$RunId
    resolvedVersion='1.0.0';resolvedIdentity="fixture:$ToolName"
    githubTokenPresent=-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)
    ghTokenPresent=-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)
}
[IO.File]::WriteAllText($OutputPath,($receipt|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
$receipt|ConvertTo-Json -Compress
'@, [Text.UTF8Encoding]::new($false))

        $powerShellPath = (Get-Process -Id $PID).Path
        $runId = '0123456789abcdef0123456789abcdef'
        $previousGithubToken = [Environment]::GetEnvironmentVariable('GITHUB_TOKEN', 'Process')
        $previousGhToken = [Environment]::GetEnvironmentVariable('GH_TOKEN', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('GITHUB_TOKEN', 'resolver-token-sentinel', 'Process')
            [Environment]::SetEnvironmentVariable('GH_TOKEN', 'cli-token-sentinel', 'Process')
            & $powerShellPath -NoProfile -NonInteractive -File $helperPath `
                -PowerShellPath $powerShellPath `
                -ResolverPath $resolverPath `
                -PolicyPath $policyPath `
                -InstallRoot $installRoot `
                -ExpectedGoRuntimeVersion '1.2.3' `
                -RunId $runId `
                -OutputRoot $outputRoot `
                -SummaryPath $summaryPath 1>$null
            $exitCode = $LASTEXITCODE
        }
        finally {
            [Environment]::SetEnvironmentVariable('GITHUB_TOKEN', $previousGithubToken, 'Process')
            [Environment]::SetEnvironmentVariable('GH_TOKEN', $previousGhToken, 'Process')
        }

        $exitCode | Should -Be 0
        $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 10
        $summary.marker | Should -Be 'atlassian-parallel-resolver-v1'
        $summary.resolutionRunId | Should -Be $runId
        @($summary.toolNames) | Should -Be @('skillspector', 'skill-validator', 'skill-tools', 'pester')
        $summary.processCount | Should -Be 4
        $summary.maxObservedConcurrency | Should -Be 4
        foreach ($toolName in @($summary.toolNames)) {
            $receiptPath = Join-Path $outputRoot "receipt-$toolName.json"
            Test-Path -LiteralPath $receiptPath -PathType Leaf | Should -BeTrue
            $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
            $receipt.toolName | Should -Be $toolName
            $receipt.resolutionRunId | Should -Be $runId
            $receipt.githubTokenPresent | Should -Be ($toolName -ceq 'skillspector')
            $receipt.ghTokenPresent | Should -Be ($toolName -ceq 'skillspector')
        }
    }

    # Scenario: One fake resolver exits immediately while its three siblings would otherwise sleep for fifteen seconds.
    # Purpose: Require fail-fast process-tree cleanup and forbid a successful summary after partial acquisition.
    It 'UnitT56_StopsSiblingResolversWhenOneResolverFails' {
        $helperPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-ParallelToolResolution.ps1'
        $fixtureRoot = Join-Path $TestDrive 'parallel-resolver-failure'
        $resolverPath = Join-Path $fixtureRoot 'fake-resolver.ps1'
        $policyPath = Join-Path $fixtureRoot 'policy.json'
        $installRoot = Join-Path $fixtureRoot 'installs'
        $outputRoot = Join-Path $fixtureRoot 'outputs'
        $summaryPath = Join-Path $fixtureRoot 'summary.json'
        [void](New-Item -ItemType Directory -Path $fixtureRoot -Force)
        [IO.File]::WriteAllText($policyPath, '{}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($resolverPath, @'
param([string]$PolicyPath,[string]$ToolName,[switch]$Install,[string]$InstallRoot,[string]$ExpectedGoRuntimeVersion,[string]$RunId,[string]$OutputPath)
[IO.File]::WriteAllText((Join-Path (Split-Path -Parent $OutputPath) "pid-$ToolName.txt"),$PID.ToString(),[Text.UTF8Encoding]::new($false))
if($ToolName -ceq 'skillspector'){[Console]::Error.WriteLine('fixture resolver failure');exit 13}
Start-Sleep -Seconds 15
[IO.File]::WriteAllText($OutputPath,'{}',[Text.UTF8Encoding]::new($false))
'@, [Text.UTF8Encoding]::new($false))

        $powerShellPath = (Get-Process -Id $PID).Path
        & $powerShellPath -NoProfile -NonInteractive -File $helperPath `
            -PowerShellPath $powerShellPath `
            -ResolverPath $resolverPath `
            -PolicyPath $policyPath `
            -InstallRoot $installRoot `
            -ExpectedGoRuntimeVersion '1.2.3' `
            -RunId 'fedcba9876543210fedcba9876543210' `
            -OutputRoot $outputRoot `
            -SummaryPath $summaryPath 1>$null 2>$null
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Not -Be 0
        Test-Path -LiteralPath $summaryPath | Should -BeFalse
        foreach ($pidPath in @(Get-ChildItem -LiteralPath $outputRoot -Filter 'pid-*.txt' -File)) {
            $childId = [int](Get-Content -LiteralPath $pidPath -Raw)
            Get-Process -Id $childId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }

    # Scenario: Production source validation prepares the four frozen tool receipts before building its toolchain.
    # Purpose: Bind the formal path to the tested parallel helper while retaining parent-side exact receipt checks.
    It 'UnitT57_UsesParallelToolResolutionBeforeValidatingEveryReceipt' {
        $sourceEntry = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1') -Raw
        $sourceEntry | Should -Match 'Invoke-ParallelToolResolution\.ps1'
        $sourceEntry | Should -Match 'atlassian-parallel-resolver-v1'
        $sourceEntry | Should -Match '\[string\]\$receipt\.resolutionRunId -cne \$runId'
        $sourceEntry | Should -Not -Match 'maxObservedConcurrency\s*-ne' -Because 'observed peak parallelism is diagnostic and complete receipt/report identities are authoritative'
        $sourceEntry | Should -Not -Match 'foreach \(\$toolName in @\(''skillspector'', ''skill-validator'', ''skill-tools'', ''pester''\)\) \{\s*\$receiptPath = Join-Path \$runRoot.+?Invoke-Resolver'
        $sourceEntry | Should -Match 'Join-Path \(\[IO\.Path\]::GetTempPath\(\)\) "rt-\$runId"'

        $member = 'anthropic\types\beta\organization\claude_tag\bundles\beta_claude_tag_slack_channel_bundle_target_create_param.py'
        $maximumHostedPath = Join-Path 'D:\a\_temp' ("rt-{0}\skillspector-{0}\venv\Lib\site-packages\{1}" -f ('0' * 32), $member)
        $maximumHostedPath.Length | Should -Be 228
        $maximumHostedPath.Length | Should -BeLessThan 248
    }

    It 'UnitT58_UsesCreateOnlyStdoutReportsForEveryDirectSkillSpectorScan' {
        $authorityGate = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardAuthorityGate.ps1') -Raw
        $validator = Get-Content -LiteralPath $script:ValidatorPath -Raw

        $authorityGate | Should -Match '-StandardOutputPath \$skillSpectorReportPath'
        $authorityGate | Should -Match '-StandardErrorPath \$skillSpectorStderrPath'
        $authorityGate | Should -Not -Match '@\(''scan'', \$upstreamAdapterSkillRoot, ''--no-llm'', ''--format'', ''json'', ''--output'''
        $validator | Should -Match '-StandardOutputPath \$reportPath -StandardErrorPath \$stderrPath'
        $validator | Should -Match '-StandardOutputPath \$semanticPath -StandardErrorPath \$semanticStderrPath'
        $validator | Should -Not -Match '@\(''scan'', \$skillRoot, ''--no-llm'', ''--format'', ''json'', ''--output'''
        $validator | Should -Not -Match '@\(''scan'', \$skillRoot, ''--format'', ''json'', ''--output'''
    }

    It 'UnitT59_CleansTheCompactRunOwnedResolverRootAfterARun' {
        $sourcePath = Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1'
        $tokens = $null
        $errors = $null
        $sourceAst = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $cleanupFunctions = @($sourceAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -ceq 'Remove-SourceOwnedTemporaryRoots'
                }, $true))
        $cleanupFunctions.Count | Should -Be 1
        . ([scriptblock]::Create($cleanupFunctions[0].Extent.Text))
        function Assert-NoReparseAncestors {
            param([string] $Path, [string] $Context)
            Test-Path -LiteralPath $Path -PathType Container | Should -BeTrue -Because $Context
        }

        $runId = [guid]::NewGuid().ToString('N')
        $root = Join-Path ([IO.Path]::GetTempPath()) "rt-$runId"
        try {
            [void](New-Item -ItemType Directory -Path $root -ErrorAction Stop)
            [IO.File]::WriteAllText((Join-Path $root 'owned.txt'), 'owned', [Text.UTF8Encoding]::new($false))
            Remove-SourceOwnedTemporaryRoots -OwnedRoots @($root)
            Test-Path -LiteralPath $root | Should -BeFalse
            (Get-Content -LiteralPath $sourcePath -Raw) | Should -Match "if \(\`$ExecutionMode -eq 'Run'\) \{\s*Remove-SourceOwnedTemporaryRoots -OwnedRoots \`$ownedTempRoots"
        }
        finally {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }

    It 'UnitT59B_RejectsAnUnrecognizedTemporaryRootName' {
        $sourcePath = Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1'
        $tokens = $null
        $errors = $null
        $sourceAst = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $cleanupFunctions = @($sourceAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -ceq 'Remove-SourceOwnedTemporaryRoots'
                }, $true))
        $cleanupFunctions.Count | Should -Be 1
        . ([scriptblock]::Create($cleanupFunctions[0].Extent.Text))
        function Assert-NoReparseAncestors { throw 'The path guard must reject the leaf before reparse inspection.' }

        $runId = [guid]::NewGuid().ToString('N')
        $root = Join-Path ([IO.Path]::GetTempPath()) "unexpected-$runId"
        try {
            [void](New-Item -ItemType Directory -Path $root -ErrorAction Stop)
            { Remove-SourceOwnedTemporaryRoots -OwnedRoots @($root) } |
                Should -Throw -ExpectedMessage '*Refusing to clean an unrecognized temporary validation root*'
            Test-Path -LiteralPath $root -PathType Container | Should -BeTrue
        }
        finally {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }

    # Scenario: Seven fake Skill roots are scanned by independent one-second processes.
    # Purpose: Prove the Stage 4 scheduler overlaps every initial scan, preserves the frozen Python closure, and binds one create-only report to each Skill.
    It 'UnitT60_ScansEveryActiveSkillConcurrentlyWithoutWritingPythonBytecode' {
        $helperPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-ParallelSkillSpector.ps1'
        Test-Path -LiteralPath $helperPath -PathType Leaf | Should -BeTrue

        $fixtureRoot = Join-Path $TestDrive 'parallel-static-success'
        $skillsRoot = Join-Path $fixtureRoot 'skills'
        $outputRoot = Join-Path $fixtureRoot 'outputs'
        $summaryPath = Join-Path $fixtureRoot 'summary.json'
        $scannerPath = Join-Path $fixtureRoot 'fake-scanner.ps1'
        [void](New-Item -ItemType Directory -Path $skillsRoot -Force)
        $skillIds = @(1..7 | ForEach-Object { "skill-$_" })
        foreach ($skillId in $skillIds) { [void](New-Item -ItemType Directory -Path (Join-Path $skillsRoot $skillId)) }
        $baselinePath = Join-Path $fixtureRoot 'skill-1.baseline.json'
        [IO.File]::WriteAllText($baselinePath, '{}', [Text.UTF8Encoding]::new($false))
        $baselineMapJson = @{ 'skill-1' = $baselinePath } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($scannerPath, @'
$scanIndex=[Array]::IndexOf($args,'scan')
if($scanIndex -lt 0 -or [Array]::IndexOf($args,'--output') -ge 0){[Console]::Error.Write('unexpected scanner arguments');exit 11}
$skillRoot=[string]$args[$scanIndex+1]
Start-Sleep -Seconds 1
$value=[ordered]@{
    skill=[IO.Path]::GetFileName($skillRoot)
    pythonDontWriteBytecode=$env:PYTHONDONTWRITEBYTECODE
    arguments=@($args[$scanIndex..($args.Count-1)])
    issues=@()
}
[Console]::Out.Write(($value|ConvertTo-Json -Compress))
'@, [Text.UTF8Encoding]::new($false))

        $powerShellPath = (Get-Process -Id $PID).Path
        $prefixJson = @('-NoProfile', '-NonInteractive', '-File', $scannerPath) | ConvertTo-Json -Compress
        $skillIdsJson = $skillIds | ConvertTo-Json -Compress
        & $powerShellPath -NoProfile -NonInteractive -File $helperPath `
            -ExecutablePath $powerShellPath `
            -ExecutablePrefixArgumentsJson $prefixJson `
            -SkillsRoot $skillsRoot `
            -SkillIdsJson $skillIdsJson `
            -BaselineMapJson $baselineMapJson `
            -OutputRoot $outputRoot `
            -SummaryPath $summaryPath 1>$null
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0
        $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 10
        $summary.marker | Should -Be 'atlassian-parallel-skillspector-v1'
        @($summary.skillIds) | Should -Be $skillIds
        $summary.processCount | Should -Be 7
        $summary.maxObservedConcurrency | Should -Be 7
        for ($index = 0; $index -lt $skillIds.Count; $index++) {
            $skillId = $skillIds[$index]
            $reportPath = Join-Path $outputRoot "skillspector-$skillId.json"
            Test-Path -LiteralPath $reportPath -PathType Leaf | Should -BeTrue
            $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
            $report.skill | Should -Be $skillId
            $report.pythonDontWriteBytecode | Should -Be '1'
            $expectedArguments = @('scan', (Join-Path $skillsRoot $skillId), '--no-llm', '--format', 'json')
            if ($skillId -ceq 'skill-1') { $expectedArguments += @('--baseline', $baselinePath) }
            @($summary.reports[$index].arguments) | Should -Be $expectedArguments
            @($report.arguments) | Should -Be $expectedArguments
            @($summary.reports[$index].arguments) | Should -Not -Contain '--output'
            $stderrText = [IO.File]::ReadAllText([string]$summary.reports[$index].stderrPath)
            [string]::IsNullOrEmpty($stderrText) | Should -BeTrue
        }
    }

    # Scenario: All seven fake scanners publish their PIDs before one fails while six siblings sleep for fifteen seconds.
    # Purpose: Require fail-fast process-tree cleanup and forbid a successful summary after incomplete Static coverage.
    It 'UnitT61_StopsSiblingScannersWhenOneSkillScanFails' {
        $helperPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-ParallelSkillSpector.ps1'
        $fixtureRoot = Join-Path $TestDrive 'parallel-static-failure'
        $skillsRoot = Join-Path $fixtureRoot 'skills'
        $outputRoot = Join-Path $fixtureRoot 'outputs'
        $summaryPath = Join-Path $fixtureRoot 'summary.json'
        $scannerPath = Join-Path $fixtureRoot 'fake-scanner.ps1'
        $stderrCapturePath = Join-Path $fixtureRoot 'helper-stderr.txt'
        [void](New-Item -ItemType Directory -Path $skillsRoot -Force)
        $skillIds = @('fail', 'skill-2', 'skill-3', 'skill-4', 'skill-5', 'skill-6', 'skill-7')
        foreach ($skillId in $skillIds) { [void](New-Item -ItemType Directory -Path (Join-Path $skillsRoot $skillId)) }
        [IO.File]::WriteAllText($scannerPath, @'
$fixtureRoot=[string]$args[0]
$scanIndex=[Array]::IndexOf($args,'scan')
if($scanIndex -lt 0 -or [Array]::IndexOf($args,'--output') -ge 0){exit 11}
$skillRoot=[string]$args[$scanIndex+1]
$skillId=[IO.Path]::GetFileName($skillRoot)
$outputRoot=Join-Path $fixtureRoot 'outputs'
$pidPath=Join-Path $outputRoot "pid-$skillId.txt"
# Publish only complete PID evidence; cleanup may interrupt any scanner instruction.
[IO.File]::WriteAllText("$pidPath.tmp",$PID.ToString(),[Text.UTF8Encoding]::new($false))
[IO.File]::Move("$pidPath.tmp",$pidPath)
$readyWatch=[Diagnostics.Stopwatch]::StartNew()
while(@(Get-ChildItem -LiteralPath $outputRoot -Filter 'pid-*.txt' -File).Count -ne 7){
    if($readyWatch.Elapsed.TotalSeconds -gt 10){throw 'Fixture scanners did not all become ready.'}
    Start-Sleep -Milliseconds 10
}
if($skillId -ceq 'fail'){[Console]::Error.Write('fixture scan failure');exit 14}
Start-Sleep -Seconds 15
[IO.File]::WriteAllText((Join-Path $outputRoot "finished-$skillId.txt"),'finished',[Text.UTF8Encoding]::new($false))
'@, [Text.UTF8Encoding]::new($false))

        $powerShellPath = (Get-Process -Id $PID).Path
        $prefixJson = @('-NoProfile', '-NonInteractive', '-File', $scannerPath, $fixtureRoot) | ConvertTo-Json -Compress
        $skillIdsJson = $skillIds | ConvertTo-Json -Compress
        & $powerShellPath -NoProfile -NonInteractive -File $helperPath `
            -ExecutablePath $powerShellPath `
            -ExecutablePrefixArgumentsJson $prefixJson `
            -SkillsRoot $skillsRoot `
            -SkillIdsJson $skillIdsJson `
            -OutputRoot $outputRoot `
            -SummaryPath $summaryPath 1>$null 2>$stderrCapturePath
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Not -Be 0
        [IO.File]::ReadAllText($stderrCapturePath) | Should -Match 'fixture scan failure'
        Test-Path -LiteralPath $summaryPath | Should -BeFalse
        $pidPaths = @(Get-ChildItem -LiteralPath $outputRoot -Filter 'pid-*.txt' -File)
        $pidPaths.Count | Should -Be 7
        @(Get-ChildItem -LiteralPath $outputRoot -Filter 'finished-*.txt' -File).Count | Should -Be 0
        foreach ($pidPath in $pidPaths) {
            $pidText = Get-Content -LiteralPath $pidPath -Raw
            $pidText | Should -Match '^[1-9][0-9]*$'
            $childId = [int]$pidText
            Get-Process -Id $childId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }

    # Scenario: A native scanner emits malformed stdout and a diagnostic on stderr.
    # Purpose: Keep JSON parsing fail-closed while retaining a bounded scanner diagnostic.
    It 'UnitT61B_ReportsScannerStderrWhenStdoutIsInvalidJson' {
        $helperPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-ParallelSkillSpector.ps1'
        $fixtureRoot = Join-Path $TestDrive 'parallel-static-invalid-json'
        $skillsRoot = Join-Path $fixtureRoot 'skills'
        $outputRoot = Join-Path $fixtureRoot 'outputs'
        $summaryPath = Join-Path $fixtureRoot 'summary.json'
        $scannerPath = Join-Path $fixtureRoot 'fake-scanner.ps1'
        $stderrCapturePath = Join-Path $fixtureRoot 'helper-stderr.txt'
        [void](New-Item -ItemType Directory -Path (Join-Path $skillsRoot 'skill-1') -Force)
        [IO.File]::WriteAllText($scannerPath, @'
if([Array]::IndexOf($args,'--output') -ge 0){exit 11}
[Console]::Out.Write('{not-json')
[Console]::Error.Write('invalid-json-diagnostic')
'@, [Text.UTF8Encoding]::new($false))

        $powerShellPath = (Get-Process -Id $PID).Path
        $prefixJson = @('-NoProfile', '-NonInteractive', '-File', $scannerPath) | ConvertTo-Json -Compress
        & $powerShellPath -NoProfile -NonInteractive -File $helperPath `
            -ExecutablePath $powerShellPath `
            -ExecutablePrefixArgumentsJson $prefixJson `
            -SkillsRoot $skillsRoot `
            -SkillIdsJson '["skill-1"]' `
            -OutputRoot $outputRoot `
            -SummaryPath $summaryPath 1>$null 2>$stderrCapturePath
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Not -Be 0
        [IO.File]::ReadAllText($stderrCapturePath) | Should -Match 'invalid-json-diagnostic'
        [IO.File]::ReadAllText((Join-Path $outputRoot 'skillspector-skill-1.json')) | Should -Be '{not-json'
        Test-Path -LiteralPath $summaryPath | Should -BeFalse
    }

    # Scenario: The production Static child receives all active Skills and retains its existing report/correction aggregation loop.
    # Purpose: Bind only initial scan process execution to the helper while preserving ordinal findings and central correction evidence.
    It 'UnitT62_UsesParallelInitialScansBeforeStaticReportAggregation' {
        $sourceEntry = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1') -Raw
        $sourceEntry | Should -Match 'Invoke-ParallelSkillSpector\.ps1'
        $sourceEntry | Should -Match 'atlassian-parallel-skillspector-v1'
        $sourceEntry | Should -Match 'Test-SupportedStaticParseLimit -Report \$report'
        $sourceEntry | Should -Match 'central Static correction'
        $sourceEntry | Should -Not -Match 'foreach \(\$skillId in \$activeSkills\) \{\s*\$skillRoot = Get-SkillRoot[\s\S]+?& \(\[string\]\$toolchain\.skillSpectorPath\) scan'
    }

    # Scenario: A baseline is inside the target, missing, or a directory.
    # Purpose: Reject unsafe baseline inputs before starting the scanner.
    It 'UnitT63_RejectsBaselinesInsideTheSkillOrWithoutARegularFile' {
        $helperPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-ParallelSkillSpector.ps1'
        $fixtureRoot = Join-Path $TestDrive 'parallel-static-baseline-invalid'
        $skillRoot = Join-Path $fixtureRoot 'skills/skill-1'
        [void](New-Item -ItemType Directory -Path $skillRoot -Force)
        $internalBaseline = Join-Path $skillRoot 'baseline.json'
        [IO.File]::WriteAllText($internalBaseline, '{}', [Text.UTF8Encoding]::new($false))
        $powerShellPath = (Get-Process -Id $PID).Path
        $case = 0
        foreach ($baselinePath in @($internalBaseline, (Join-Path $fixtureRoot 'missing.json'), $fixtureRoot)) {
            $case++
            $outputRoot = Join-Path $fixtureRoot "output-$case"
            $summaryPath = Join-Path $fixtureRoot "summary-$case.json"
            $expectedMessage = if ($case -eq 1) { '*outside the scan target*' } else { '*existing regular file*' }
            { & $helperPath -ExecutablePath $powerShellPath -SkillsRoot (Split-Path -Parent $skillRoot) -SkillIdsJson '["skill-1"]' -BaselineMapJson (@{ 'skill-1' = $baselinePath } | ConvertTo-Json -Compress) -OutputRoot $outputRoot -SummaryPath $summaryPath } | Should -Throw -ExpectedMessage $expectedMessage
            Test-Path -LiteralPath $summaryPath | Should -BeFalse
        }
    }

    It 'UnitT64_CombinesExceptionCandidateAndAnalyzerSemanticTriggers' {
        $sourceEntry = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1') -Raw
        $sourceEntry | Should -Not -Match '\$changedPath -like ''skills/\*'''
        $sourceEntry | Should -Match '\$semanticRequired = Test-SkillSpectorExceptionCandidateChange -GitPath \$gitPath -RepositoryRoot \$repoRoot -BaseRevision \$baseRevision -CandidateRevision \$candidateCommit'
        $sourceEntry | Should -Match '\$semantic = \(\$SemanticRequired -ceq ''true''\) -or \$findings.Count -gt 0'
        $sourceEntry | Should -Match 'suppressedFindings = @\(\$suppressedFindings\)'
    }

}

Describe 'SkillSpector exception candidate changes' {
    BeforeAll {
        $sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/SkillSpectorExceptionCandidates.psm1'
        $tokens = $null
        $parseErrors = $null
        $sourceAst = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
        if (@($parseErrors).Count -ne 0) { throw 'Source conformance script has syntax errors.' }
        $definitions = @($sourceAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -ceq 'Test-SkillSpectorExceptionCandidateChange'
                }, $false))
        if ($definitions.Count -ne 1) { throw 'Expected exactly one exception candidate detector.' }
        . ([scriptblock]::Create($definitions[0].Extent.Text))
        $script:ExceptionGitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path

        function Invoke-ExceptionFixtureGit {
            param([string] $Root, [string[]] $Arguments)
            $output = @(& $script:ExceptionGitPath -C $Root @Arguments 2>&1)
            if ($LASTEXITCODE -ne 0) { throw "Fixture git failed: $($output -join '`n')" }
            return $output
        }

        function New-ExceptionChangeFixture {
            param([string] $Root, [switch] $WithoutRegistry)
            [void](New-Item -ItemType Directory -Path (Join-Path $Root 'config/skillspector-exceptions') -Force)
            $null = Invoke-ExceptionFixtureGit -Root $Root -Arguments @('init', '--quiet')
            $null = Invoke-ExceptionFixtureGit -Root $Root -Arguments @('config', '--local', 'user.name', 'Exception Test')
            $null = Invoke-ExceptionFixtureGit -Root $Root -Arguments @('config', '--local', 'user.email', 'exception-test@example.invalid')
            $registryPath = Join-Path $Root 'config/skillspector-exceptions.json'
            if (-not $WithoutRegistry) {
                [IO.File]::WriteAllText($registryPath, '{"gateEffect":"original","exceptions":[{"owner":"reviewer"}]}', [Text.UTF8Encoding]::new($false))
            }
            [IO.File]::WriteAllText((Join-Path $Root 'config/skillspector-exceptions/existing.baseline.json'), '{}', [Text.UTF8Encoding]::new($false))
            $null = Invoke-ExceptionFixtureGit -Root $Root -Arguments @('add', '.')
            $null = Invoke-ExceptionFixtureGit -Root $Root -Arguments @('commit', '--quiet', '--no-gpg-sign', '-m', 'base')
            $baseRevision = [string](Invoke-ExceptionFixtureGit -Root $Root -Arguments @('rev-parse', 'HEAD'))
            return [pscustomobject]@{ root = $Root; registryPath = $registryPath; baseRevision = $baseRevision }
        }

        function Complete-ExceptionChangeFixture {
            param($Fixture)
            $null = Invoke-ExceptionFixtureGit -Root $Fixture.root -Arguments @('add', '.')
            $null = Invoke-ExceptionFixtureGit -Root $Fixture.root -Arguments @('commit', '--quiet', '--no-gpg-sign', '--allow-empty', '-m', 'candidate')
            return [string](Invoke-ExceptionFixtureGit -Root $Fixture.root -Arguments @('rev-parse', 'HEAD'))
        }
    }

    # Scenario: Candidate commits preserve or edit exception context and baseline files.
    # Purpose: Require semantic review for every exception candidate except gateEffect-only edits.
    It 'UnitT65_DetectsExceptionCandidateChanges_<Change>' -TestCases @(
        @{ Change = 'unchanged'; Expected = $false }
        @{ Change = 'gateEffect'; Expected = $false }
        @{ Change = 'exception'; Expected = $true }
        @{ Change = 'baseline-added'; Expected = $true }
        @{ Change = 'baseline-modified'; Expected = $true }
        @{ Change = 'baseline-deleted'; Expected = $true }
        @{ Change = 'baseline-renamed'; Expected = $true }
        @{ Change = 'registry-added'; Expected = $true }
        @{ Change = 'registry-deleted'; Expected = $true }
        @{ Change = 'registry-absent'; Expected = $false }
    ) {
        param($Change, $Expected)
        $fixture = New-ExceptionChangeFixture -Root (Join-Path $TestDrive $Change) -WithoutRegistry:($Change -in @('registry-added', 'registry-absent'))
        switch ($Change) {
            'unchanged' {
                [IO.File]::WriteAllText((Join-Path $fixture.root 'unrelated.txt'), 'unrelated change')
            }
            'gateEffect' {
                [IO.File]::WriteAllText($fixture.registryPath, '{"gateEffect":"reworded","exceptions":[{"owner":"reviewer"}]}')
            }
            'exception' {
                [IO.File]::WriteAllText($fixture.registryPath, '{"gateEffect":"original","exceptions":[{"owner":"candidate"}]}')
            }
            'baseline-added' {
                [IO.File]::WriteAllText((Join-Path $fixture.root 'config/skillspector-exceptions/new.baseline.json'), '{}')
            }
            'baseline-modified' {
                [IO.File]::WriteAllText((Join-Path $fixture.root 'config/skillspector-exceptions/existing.baseline.json'), '{"changed":true}')
            }
            'baseline-deleted' {
                Remove-Item -LiteralPath (Join-Path $fixture.root 'config/skillspector-exceptions/existing.baseline.json')
            }
            'baseline-renamed' {
                Move-Item -LiteralPath (Join-Path $fixture.root 'config/skillspector-exceptions/existing.baseline.json') -Destination (Join-Path $fixture.root 'config/skillspector-exceptions/renamed.baseline.json')
            }
            'registry-added' {
                [IO.File]::WriteAllText($fixture.registryPath, '{"exceptions":[]}')
            }
            'registry-deleted' {
                Remove-Item -LiteralPath $fixture.registryPath
            }
        }
        $candidateRevision = Complete-ExceptionChangeFixture -Fixture $fixture
        Test-SkillSpectorExceptionCandidateChange -GitPath $script:ExceptionGitPath -RepositoryRoot $fixture.root -BaseRevision $fixture.baseRevision -CandidateRevision $candidateRevision | Should -Be $Expected
    }

    It 'UnitT66_RejectsInvalidExceptionRegistryJson' {
        $fixture = New-ExceptionChangeFixture -Root (Join-Path $TestDrive 'invalid-registry')
        [IO.File]::WriteAllText($fixture.registryPath, '{invalid-json')
        $candidateRevision = Complete-ExceptionChangeFixture -Fixture $fixture
        { Test-SkillSpectorExceptionCandidateChange -GitPath $script:ExceptionGitPath -RepositoryRoot $fixture.root -BaseRevision $fixture.baseRevision -CandidateRevision $candidateRevision } | Should -Throw
    }

    It 'UnitT67_RejectsFailedExceptionGitComparison' {
        $fixture = New-ExceptionChangeFixture -Root (Join-Path $TestDrive 'invalid-revision')
        { Test-SkillSpectorExceptionCandidateChange -GitPath $script:ExceptionGitPath -RepositoryRoot $fixture.root -BaseRevision 'missing-revision' -CandidateRevision $fixture.baseRevision } | Should -Throw '*Could not compare*'
    }
}
