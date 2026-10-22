# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Atlassian Ecosystem Standard v1 conformance' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:SourcePath = Join-Path $script:RepositoryRoot 'catalog/source.json'
        $script:AdapterPath = Join-Path $script:RepositoryRoot 'config/standard-v1.json'
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $script:RepositoryValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1'
        $script:ExpectedAuthorityCommit = '098e40d26de585e5565a031d9b826454e6a34720'
        $script:ExpectedAuthorityArchiveSha256 = 'de7b7ca64c2ff3ddd12a94f9ca39d01981ff903a64ca624c70b336679790a8e8'
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
            @{ path = 'docs/standards/schemas/static-parser-host-ownership-v1.schema.json'; sha256 = '7f8d766b7e36052b68d924c5886157734e9969c198b03b2dadf3a63bebc95bb3' }
            @{ path = 'docs/standards/schemas/static-parser-profile-execution-v1.schema.json'; sha256 = '6353bcd130093ffcdb7b6f979f8d115c02a31efae41e63f8a956e82935ab8887' }
            @{ path = 'docs/standards/schemas/upstream-adapter-v1.schema.json'; sha256 = '3cff6246463188a91cc54c6a46315a949314767a759c6214e5b28e4db95ac8d7' }
            @{ path = 'docs/standards/schemas/validation-security-gate-v1.schema.json'; sha256 = '9b186773b85b242c216942cac5fe8dc4eaa231ac7edac0e194c790c94e4bf9dc' }
            @{ path = 'docs/standards/skill-repository-review-matrix.md'; sha256 = '299925aabe3cab360827baad9bdeb1f0f56fc320dad967e49fe0b6bf9cdf8f8a' }
            @{ path = 'docs/standards/skill-repository-standard.md'; sha256 = 'ae21cafb99601a1fb50ca2a97a834a642c93f04a0693a792bbe6491b113f273a' }
            @{ path = 'docs/standards/standard-validation-contract-v1.json'; sha256 = 'ba2f36ef113eb2937f39819099e339eb13731ef0036bb731037dbc0720d8e12e' }
            @{ path = 'docs/standards/static-parser-host-ownership.json'; sha256 = '994acd989327d094d22ce2c68ca20eceec609f4e494f4e5d252cfcdef742de2c' }
            @{ path = 'docs/standards/trust-anchors/human-approval-public-key.xml'; sha256 = '1e46153b72d02f3ce2fb26becd449df4f1590d8e5cb441b1954006a5602bbd9b' }
            @{ path = 'docs/standards/trust-anchors/trusted-supervisor-public-key.xml'; sha256 = '4d550851f43405920156f40c9fc648d99a69dd73efc200f6968d8a837e7fbf27' }
            @{ path = 'docs/standards/upstream-adapter.json'; sha256 = 'c4f5133b24841bb9c66182dc3d5a027596f864ec28e410d47249a67b3b97ad31' }
            @{ path = 'docs/standards/upstream-interoperability.md'; sha256 = '4329e8586e88713027bcd95c7537331e050a89b004f2361223efdc01bf44370e' }
            @{ path = 'docs/standards/validation-security-gate.json'; sha256 = 'd0437b7aae41a78b8f53f5a052396941350ea90d352a109391ea5d7c6140febc' }
            @{ path = 'docs/standards/validation-toolchain.json'; sha256 = '1dddbf4c5736e22e56f6ecb298542f41d39e116ab00ca24ad18beb7a3eab40ed' }
            @{ path = 'scripts/Get-StandardPowerShellSyntaxProof.ps1'; sha256 = '29104bd061d5e43540a0586c29830b28fd6f16367f3a7ffbf960980576d559cd' }
            @{ path = 'scripts/Invoke-StandardAuthorityGate.ps1'; sha256 = 'fd5cc1500f8bcb7d3d5dd707f5426fbb996d00bf048d3bdbb4b510cfc0ff2591' }
            @{ path = 'scripts/Invoke-StandardStaticScan.ps1'; sha256 = '7cd196468debe0baf36266f98fa5441d98eb351985adbc07a74123a6c5b510a1' }
            @{ path = 'scripts/Invoke-StandardValidation.ps1'; sha256 = 'e19d34f6bc4287f19b53ab377c7574c7403ba4f3e240f4107fba17fcc9d36051' }
            @{ path = 'scripts/Resolve-PythonWheelClosure.py'; sha256 = 'a17989f409f8394af2c851db4d33e9a5b003d0dc17a9689de8de0542c0862ca8' }
            @{ path = 'scripts/Resolve-StandardValidationTool.ps1'; sha256 = 'fbbc258b12ed24f257bc068399b76f9e58de4a02bd9d12301c01842a77c960c1' }
            @{ path = 'scripts/StandardSemanticBridge.psm1'; sha256 = 'daf90f703898cc56fc3310e1eec462bafa6552edcac0de4f08a3cd4b9f63a429' }
            @{ path = 'scripts/Validate-UpstreamAdapter.ps1'; sha256 = '3b6e6474690b1ae9f9486544b68f50ca29b96f5dbe6aa8d6c6cd8570afad500b' }
            @{ path = 'scripts/standard_static_powershell.py'; sha256 = '75ec4fd598bde589e4e6cb16f94d78bf36cf5e465e3547670b592cb37c47d4a9' }
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

    # Scenario: The source workflow initializes Pester before concurrent canonical tests.
    # Purpose: Preserve workflow gates and avoid first-use registry races without replacing existing test keys.
    It 'InterT25_InitializesTheSharedPesterParentBeforeTheReadOnlySourceWorkflow' {
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

        $initialization = [regex]::Match($workflow, '(?ms)^      - name: Initialize shared Pester registry parent\r?\n        shell: pwsh\r?\n        run: \|\r?\n(?<script>(?:          [^\r\n]*\r?\n)+)')
        $initialization.Success | Should -BeTrue
        $initialization.Index | Should -BeLessThan $workflow.IndexOf('      - name: Run canonical Standard v1 validation', [StringComparison]::Ordinal)
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

    # Scenario: Windows core.autocrlf is enabled while the internal-use registry binds Git blob bytes.
    # Purpose: Ensure the immutable candidate archive preserves the exact reviewed package identity.
    It 'UnitT20_PreservesApprovedBitbucketSkillBytesInGitArchive' {
        $attributes = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.gitattributes') -Raw
        $attributes | Should -Match '(?m)^/skills/review-bitbucket-pull-request/\*\* text eol=lf\r?$'

        $expected = [ordered]@{
            'SKILL.md' = 'c4ba49ab8db0c0f84b51b49b78db1833e8101cd1bfafe6a534cef8744e223b71'
            'agents/openai.yaml' = '7e47144aaa1256f09d9ddba009633299cf7323666369852dbf4bf05151e41fb0'
            'references/bitbucket-cloud-api.md' = '0a9437d3ddba5bda6f766d7328064c023fd60dbff517d90dbf1c8746ad7a1730'
            'references/review-actions.md' = 'af5e4d744cff938b9bf8cdfcfb481e9975edec3cb049939b18950da3d178f4f0'
            'scripts/Invoke-BitbucketReviewActions.ps1' = 'fe875d18375ef8872054040e6ad34b0f649b4fac22ae53ae9f75a4d3471dd301'
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
        $sourceEntry | Should -Not -Match "foreach \(\$toolName in @\('skillspector', 'skill-validator', 'skill-tools', 'pester'\)\) \{\s*\$receiptPath = Join-Path \$runRoot.+?Invoke-Resolver"
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
        [IO.File]::WriteAllText($scannerPath, @'
$skillRoot=[string]$args[1]
$outputIndex=[Array]::IndexOf($args,'--output')
if($args[0] -cne 'scan' -or $outputIndex -lt 0){exit 11}
Start-Sleep -Seconds 1
$value=[ordered]@{
    skill=[IO.Path]::GetFileName($skillRoot)
    pythonDontWriteBytecode=$env:PYTHONDONTWRITEBYTECODE
    issues=@()
}
[IO.File]::WriteAllText([string]$args[$outputIndex+1],($value|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
'@, [Text.UTF8Encoding]::new($false))

        $powerShellPath = (Get-Process -Id $PID).Path
        $prefixJson = @('-NoProfile', '-NonInteractive', '-File', $scannerPath) | ConvertTo-Json -Compress
        $skillIdsJson = $skillIds | ConvertTo-Json -Compress
        & $powerShellPath -NoProfile -NonInteractive -File $helperPath `
            -ExecutablePath $powerShellPath `
            -ExecutablePrefixArgumentsJson $prefixJson `
            -SkillsRoot $skillsRoot `
            -SkillIdsJson $skillIdsJson `
            -OutputRoot $outputRoot `
            -SummaryPath $summaryPath 1>$null
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0
        $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 10
        $summary.marker | Should -Be 'atlassian-parallel-skillspector-v1'
        @($summary.skillIds) | Should -Be $skillIds
        $summary.processCount | Should -Be 7
        $summary.maxObservedConcurrency | Should -Be 7
        foreach ($skillId in $skillIds) {
            $reportPath = Join-Path $outputRoot "skillspector-$skillId.json"
            Test-Path -LiteralPath $reportPath -PathType Leaf | Should -BeTrue
            $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
            $report.skill | Should -Be $skillId
            $report.pythonDontWriteBytecode | Should -Be '1'
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
        [void](New-Item -ItemType Directory -Path $skillsRoot -Force)
        $skillIds = @('fail', 'skill-2', 'skill-3', 'skill-4', 'skill-5', 'skill-6', 'skill-7')
        foreach ($skillId in $skillIds) { [void](New-Item -ItemType Directory -Path (Join-Path $skillsRoot $skillId)) }
        [IO.File]::WriteAllText($scannerPath, @'
$skillRoot=[string]$args[1]
$reportPath=[string]$args[-1]
$skillId=[IO.Path]::GetFileName($skillRoot)
$outputRoot=Split-Path -Parent $reportPath
$pidPath=Join-Path $outputRoot "pid-$skillId.txt"
# Publish only complete PID evidence; cleanup may interrupt any scanner instruction.
[IO.File]::WriteAllText("$pidPath.tmp",$PID.ToString(),[Text.UTF8Encoding]::new($false))
[IO.File]::Move("$pidPath.tmp",$pidPath)
$readyWatch=[Diagnostics.Stopwatch]::StartNew()
while(@(Get-ChildItem -LiteralPath $outputRoot -Filter 'pid-*.txt' -File).Count -ne 7){
    if($readyWatch.Elapsed.TotalSeconds -gt 10){throw 'Fixture scanners did not all become ready.'}
    Start-Sleep -Milliseconds 10
}
if($skillId -ceq 'fail'){[Console]::Error.WriteLine('fixture scan failure');exit 14}
Start-Sleep -Seconds 15
[IO.File]::WriteAllText((Join-Path $outputRoot "finished-$skillId.txt"),'finished',[Text.UTF8Encoding]::new($false))
'@, [Text.UTF8Encoding]::new($false))

        $powerShellPath = (Get-Process -Id $PID).Path
        $prefixJson = @('-NoProfile', '-NonInteractive', '-File', $scannerPath) | ConvertTo-Json -Compress
        $skillIdsJson = $skillIds | ConvertTo-Json -Compress
        & $powerShellPath -NoProfile -NonInteractive -File $helperPath `
            -ExecutablePath $powerShellPath `
            -ExecutablePrefixArgumentsJson $prefixJson `
            -SkillsRoot $skillsRoot `
            -SkillIdsJson $skillIdsJson `
            -OutputRoot $outputRoot `
            -SummaryPath $summaryPath 1>$null 2>$null
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Not -Be 0
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
}
