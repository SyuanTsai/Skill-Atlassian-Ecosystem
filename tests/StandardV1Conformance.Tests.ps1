# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Atlassian Ecosystem Standard v1 conformance' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:SourcePath = Join-Path $script:RepositoryRoot 'catalog/source.json'
        $script:AdapterPath = Join-Path $script:RepositoryRoot 'config/standard-v1.json'
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $script:RepositoryValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1'
        $script:ExpectedAuthorityCommit = '8aabd22694a05771f98639f6d726cc9a620eb94b'
        $script:ExpectedAuthorityArchiveSha256 = 'd92df1a8f0aa342970dc9c66a77b6211955b4708de12119cb7f9a360fd265311'
        $script:ExpectedAuthorityFiles = @(
            @{ path = 'docs/standards/README.md'; sha256 = '5e1ddd737d26a5ec1ff1ebd08e158376ddaf1ea21008bb987fc7f51376923f7c' }
            @{ path = 'docs/standards/managed-skill-lifecycle.md'; sha256 = '70950cf8bdd02819efae6f6e06ac5be1da3e70f809c23e3c6f8d3b217797416c' }
            @{ path = 'docs/standards/schemas/managed-skill-lifecycle-v1.schema.json'; sha256 = '9a7f4c02588d2b88194e953a41766a72a9426fa89d4c3781c5750dcc22d35863' }
            @{ path = 'docs/standards/schemas/openai-agent-metadata.schema.json'; sha256 = '23c1aaee28a54fea1946a61d6122a2097906ffa5bdd66c8014fc6b1625c9062a' }
            @{ path = 'docs/standards/schemas/source-inventory-v2.schema.json'; sha256 = '084550944b4141ab5535f58fb6e99730a5c34b56103f6b59fd5a352679caa98e' }
            @{ path = 'docs/standards/schemas/standard-semantic-consent-evidence-v2.schema.json'; sha256 = '109091979d0a47e2035d3d8b20963fcdb85680e5da737bf1f27121608115d430' }
            @{ path = 'docs/standards/schemas/validation-security-gate-v1.schema.json'; sha256 = '32aee32858cdb0f8fa7b01462af05ad2300cb247cd2e3ca769fa36ed1ac205a9' }
            @{ path = 'docs/standards/skill-repository-review-matrix.md'; sha256 = '315204afe428bb51cab5e815b2c40f6d0cbd55c81a3532ad59b686ae5e4c166c' }
            @{ path = 'docs/standards/skill-repository-standard.md'; sha256 = 'c85562f017a09b4f4daa8dd3a1fcbd1d34714eb711ed9c011642247c8d3be61e' }
            @{ path = 'docs/standards/upstream-interoperability.md'; sha256 = '9c544fbfb6b77a589514f1926aa1488882e932786a303a42ce6c6c9b2ba80c7e' }
            @{ path = 'docs/standards/validation-security-gate.json'; sha256 = '2d4ac30449981083d3f3eab850789e7115684f9dfecad48234bc91ffb678e674' }
            @{ path = 'docs/standards/validation-toolchain.json'; sha256 = '1dddbf4c5736e22e56f6ecb298542f41d39e116ab00ca24ad18beb7a3eab40ed' }
            @{ path = 'scripts/Invoke-StandardAuthorityGate.ps1'; sha256 = 'e5e8050df56dd60af7d9eec04fda2e05e331fded18bc69257431c2a11f39a9e9' }
            @{ path = 'scripts/Resolve-PythonWheelClosure.py'; sha256 = 'd209c973f331fdbb82a4d546bda18b1d485bcd1e446dd446b6d8bc4360b5ce35' }
            @{ path = 'scripts/Resolve-StandardValidationTool.ps1'; sha256 = '86540ff07e1b73177d179ae6a9ee2f0fef8029e27286604d68a9a98d0d205ec2' }
            @{ path = 'docs/standards/schemas/standard-validation-adapter-v1.schema.json'; sha256 = '11aa88fc25716d748bd4f514f1a44f02390ad1745dd5a5c5beee07f642fd5639' }
            @{ path = 'docs/standards/schemas/standard-validation-evidence-v1.schema.json'; sha256 = '8ed4a9d7158273d7a1e9d898acf07f57e9170822cb7cbb70f1e2eec7195867ee' }
            @{ path = 'docs/standards/standard-validation-contract-v1.json'; sha256 = '6fa3233e86ec7918aebf1413d41a6d1712f55eb2d1b09262fe18e53ddfbcb8cf' }
            @{ path = 'docs/standards/trust-anchors/human-approval-public-key.xml'; sha256 = '1e46153b72d02f3ce2fb26becd449df4f1590d8e5cb441b1954006a5602bbd9b' }
            @{ path = 'docs/standards/trust-anchors/trusted-supervisor-public-key.xml'; sha256 = '4d550851f43405920156f40c9fc648d99a69dd73efc200f6968d8a837e7fbf27' }
            @{ path = 'scripts/Invoke-StandardValidation.ps1'; sha256 = 'c127309958226417291b512d633caa2120bbd12a663c98fff1d63106cf5a2677' }
            @{ path = 'docs/standards/schemas/upstream-adapter-v1.schema.json'; sha256 = '3cff6246463188a91cc54c6a46315a949314767a759c6214e5b28e4db95ac8d7' }
            @{ path = 'docs/standards/upstream-adapter.json'; sha256 = 'c4f5133b24841bb9c66182dc3d5a027596f864ec28e410d47249a67b3b97ad31' }
            @{ path = 'scripts/Validate-UpstreamAdapter.ps1'; sha256 = '3b6e6474690b1ae9f9486544b68f50ca29b96f5dbe6aa8d6c6cd8570afad500b' }
            @{ path = 'docs/standards/pr12-source-merge-adoption.json'; sha256 = '4c5262f2a11d228195230c15fa4faaf9614af6b59f110e5d9c08f242ce809175' }
            @{ path = 'scripts/StandardSemanticBridge.psm1'; sha256 = 'daf90f703898cc56fc3310e1eec462bafa6552edcac0de4f08a3cd4b9f63a429' }
        )

        $script:SourceEntryPath=Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1'
        $sourceTokens=$null;$sourceErrors=$null
        $sourceAst=[Management.Automation.Language.Parser]::ParseFile($script:SourceEntryPath,[ref]$sourceTokens,[ref]$sourceErrors)
        if(@($sourceErrors).Count) {throw 'Source entry parse failure.'}
        foreach($statement in $sourceAst.EndBlock.Statements) {
            if($statement -is [Management.Automation.Language.AssignmentStatementAst] -and $statement.Left.Extent.Text -cin @('$script:AuthorityRepository','$script:AuthorityCommit','$script:AuthorityArchiveSha256','$script:AuthorityFiles')) {
                . ([scriptblock]::Create($statement.Extent.Text))
            }
        }
        foreach($name in @('Assert-ExactPropertySet','Assert-Sha256','Assert-AuthorityConfig','Invoke-Resolver','Test-PathWithinOrEqual','Assert-PathWithinRoot')) {
            $definition=@($sourceAst.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq $name})
            if($definition.Count -ne 1) {throw 'Required source verifier absent.'}
            . ([scriptblock]::Create($definition[0].Extent.Text))
        }
        $script:CandidateConfig=Get-Content -LiteralPath $script:AdapterPath -Raw | ConvertFrom-Json -Depth 40
        $script:CandidateConfig.authority.commit=$script:ExpectedAuthorityCommit
        $script:CandidateConfig.authority.archiveUrl="https://codeload.github.com/SyuanTsai/SyuanTsai-AI-Instructions/zip/$($script:ExpectedAuthorityCommit)"
        $script:CandidateConfig.authority.archiveSha256=$script:ExpectedAuthorityArchiveSha256
        $script:CandidateConfig.authority.files=@($script:ExpectedAuthorityFiles | ForEach-Object {[pscustomobject]$_})
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

    It 'UnitT20_BindsTheImmutable8aAuthorityWithoutLocalPolicy' {
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
        $adapter.centralRunner.runnerSha256 | Should -Be 'c127309958226417291b512d633caa2120bbd12a663c98fff1d63106cf5a2677'
        $adapter.centralRunner.contractPath | Should -Be 'docs/standards/standard-validation-contract-v1.json'
        $adapter.centralRunner.evidenceSchemaPath | Should -Be 'docs/standards/schemas/standard-validation-evidence-v1.schema.json'
        $adapter.centralRunner.adapterSource | Should -Be 'trusted-supervisor-generated-from-resolver-receipts'
        $adapter.centralRunner.adapterMode | Should -Be 'production'
        @($adapter.centralRunner.requiredEvidence) | Should -Be @('launchBinding', 'signedResolverReceipt', 'candidateBinding', 'semanticConsent', 'semanticProvider', 'semanticPurpose', 'semanticScope', 'semanticAttestation')
    }

    # Scenario: Both validators check the same complete immutable dependencies. Purpose: Prevent an unbound semantic bridge or adoption document.
    It 'UnitT30_BindsTheCompleteAuthorityClosureInBothValidators' {
        $validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
        $repositoryValidator = Get-Content -LiteralPath $script:RepositoryValidatorPath -Raw
        foreach ($file in $script:ExpectedAuthorityFiles) {
            $quotedPath = [regex]::Escape("'$($file.path)'")
            $validator | Should -Match $quotedPath
            $repositoryValidator | Should -Match $quotedPath
        }
    }

    # Scenario: The source adapter and config declare the new runner/schema hashes. Purpose: Reject a stale or mismatched authority member.
    It 'UnitT40_PinsSourceAdapterHashesToTheImmutableAuthorityInventory' {
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

    # Scenario: The exact planned 8a config reaches the real source verifier. Purpose: Accept the approved immutable snapshot without executing acquisition.
    It 'UnitT80_Accepts8aWithTheActualAuthorityConfigVerifier' {
        {Assert-AuthorityConfig -Config $script:CandidateConfig} | Should -Not -Throw
    }
    # Scenario: A caller supplies the old immutable authority binding. Purpose: Reject the prior pin before considering member content.
    It 'UnitT81_RejectsThePriorAuthorityPin' {
        $prior=$script:CandidateConfig | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
        $prior.authority.commit='1caf12a9d1659f3697fb90e8883d3aa8e67678de'
        $prior.authority.archiveUrl='https://codeload.github.com/SyuanTsai/SyuanTsai-AI-Instructions/zip/1caf12a9d1659f3697fb90e8883d3aa8e67678de'
        $prior.authority.archiveSha256='1e19c09c9cd5a8c5d60d205a6f9b7d8a0e96390f288d4a6cb14e2a54b2a6fad9'
        {Assert-AuthorityConfig -Config $prior} | Should -Throw '*exact approved P02 authority snapshot*'
    }
    # Scenario: Each required member hash is forged in turn. Purpose: Validate the complete closure using the actual fixed source verifier.
    It 'UnitT82_RejectsForgedHashesForEveryRequiredMember' {
        foreach($index in 0..25) {
            $forged=$script:CandidateConfig | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
            $forged.authority.files[$index].sha256='0'*64
            {Assert-AuthorityConfig -Config $forged} | Should -Throw '*authority file identity mismatch*'
        }
    }
    # Scenario: A new direct runner dependency is omitted. Purpose: Reject incomplete archive capability closure.
    It 'UnitT83_RejectsMissingDirectRunnerDependencies' {
        foreach($name in @('docs/standards/pr12-source-merge-adoption.json','scripts/StandardSemanticBridge.psm1')) {
            $missing=$script:CandidateConfig | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
            $missing.authority.files=@($missing.authority.files | Where-Object {$_.path -cne $name})
            {Assert-AuthorityConfig -Config $missing} | Should -Throw '*inventory is incomplete*'
        }
    }
    # Scenario: The owned resolver wrapper calls an offline callee. Purpose: Verify the explicit 900 acquisition budget reaches the child independently of the runner timeout.
    It 'UnitT84_PropagatesTheAcquisitionBudgetToAnOfflineCallee' {
        $callee=Join-Path $TestDrive 'offline-resolver.ps1';$result=Join-Path $TestDrive 'offline-budget.txt'
        [IO.File]::WriteAllText($callee,'param([int]$AcquisitionTimeoutSeconds,[string]$OutputPath) [IO.File]::WriteAllText($OutputPath,[string]$AcquisitionTimeoutSeconds);exit 0')
        Invoke-Resolver -PowerShellPath (Get-Command pwsh -CommandType Application | Select-Object -First 1).Path -ResolverPath $callee -Arguments @('-OutputPath',$result)
        [IO.File]::ReadAllText($result) | Should -Be '900'
    }
    # Scenario: The actual path helper receives an escaped or contained authority path. Purpose: Preserve its existing file capability boundary during pin adoption.
    It 'UnitT85_PreservesTheAuthorityPathCapabilityBoundary' {
        $inside=Join-Path $TestDrive 'inside/member.json'
        Assert-PathWithinRoot -Path $inside -Root $TestDrive -Context 'Fixture' | Should -Be ([IO.Path]::GetFullPath($inside))
        {Assert-PathWithinRoot -Path (Join-Path $TestDrive '../outside.json') -Root $TestDrive -Context 'Fixture'} | Should -Throw '*must stay within*'
    }

}
