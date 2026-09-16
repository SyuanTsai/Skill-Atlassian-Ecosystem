# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Canonical Standard v1 validation adapter' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $script:Validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
        $script:Adapter = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'config/standard-v1.json') -Raw |
            ConvertFrom-Json -Depth 20
        $script:ExpectedAuthorityCommit = 'a403abdf038a3346d775431a6908a71cc3d35a5b'
        $script:ExpectedAuthorityArchiveSha256 = '17154929fadfa63487263db1efcb78f4948195af9c11c25a66432eff3411b2d3'
    }

    It 'UnitT10_pins_the_exact_merged_P02_authority_snapshot' {
        @($script:Adapter.PSObject.Properties.Name) | Should -Be @('schemaVersion', 'standardVersion', 'authority')
        $script:Adapter.authority.commit | Should -Be $script:ExpectedAuthorityCommit
        $script:Adapter.authority.archiveUrl | Should -Be "https://codeload.github.com/SyuanTsai/SyuanTsai-AI-Instructions/zip/$($script:ExpectedAuthorityCommit)"
        $script:Adapter.authority.archiveSha256 | Should -Be $script:ExpectedAuthorityArchiveSha256
        @($script:Adapter.authority.files).Count | Should -BeGreaterThan 10
        $script:Validator | Should -Match 'Authority archive SHA-256 does not match'
    }

    It 'UnitT20_verifies_authority_before_resolving_or_executing_any_validation_tool' {
        $archiveIndex = $script:Validator.IndexOf('Expand-Archive')
        $archiveHashIndex = $script:Validator.IndexOf('Authority archive SHA-256 does not match')
        $fileHashIndex = $script:Validator.IndexOf('Authority file identity mismatch')
        $resolverIndex = $script:Validator.LastIndexOf('resolverPath = Join-Path')
        $centralIndex = $script:Validator.LastIndexOf('centralRunnerPath = Join-Path')
        $archiveIndex | Should -BeGreaterThan -1
        $archiveHashIndex | Should -BeGreaterThan $archiveIndex
        $fileHashIndex | Should -BeGreaterThan $archiveHashIndex
        $resolverIndex | Should -BeGreaterThan $fileHashIndex
        $centralIndex | Should -BeGreaterThan $resolverIndex
    }

    It 'UnitT30_passes_resolver_named_arguments_through_the_trusted_PowerShell_host' {
        $script:Validator | Should -Match '& \$PowerShellPath -NoProfile -NonInteractive -File \$ResolverPath @Arguments'
        $script:Validator | Should -Match 'Invoke-Resolver -PowerShellPath \$pwshPath'
    }

    It 'UnitT40_keeps_the_central_runner_as_the_only_stage_and_severity_orchestrator' {
        $script:Validator | Should -Match 'Invoke-StandardValidation\.ps1'
        $script:Validator | Should -Match '-DevelopmentHarness'
        $script:Validator | Should -Match '& \$pwshPath -NoProfile -NonInteractive -File \$centralRunnerPath @centralRunnerArgs'
        $script:Validator | Should -Match 'standard-validation-adapter\.json'
        $script:Validator | Should -Match 'packageAdapter'
        $script:Validator | Should -Match 'skillValidator'
        $script:Validator | Should -Match 'skillTools'
        $script:Validator | Should -Match 'staticAnalyzer'
        $script:Validator | Should -Match 'repositoryTests'
        $script:Validator | Should -Not -Match 'ConvertTo-ValidationSecurityFinding'
        $script:Validator | Should -Not -Match 'deviations\s*='
        $script:Validator | Should -Not -Match 'Get-ValidationSecurityAction'
    }

    It 'UnitT50_dispatches_the_Atlassian_repository_contract_and_all_domain_components_after_static' {
        $script:Validator | Should -Match 'repository-test-atlassian'
        $script:Validator | Should -Match 'scripts[/\\]Test-Repository\.ps1'
        foreach ($component in @(
            'validate-repository.ps1',
            'validate-repository-standalone.ps1',
            'validate-api-access.ps1'
        )) {
            $script:Validator | Should -Match ([regex]::Escape($component))
        }
        $static = $script:Validator.IndexOf('staticAnalyzer')
        $repository = $script:Validator.IndexOf('repositoryTests')
        $static | Should -BeGreaterThan -1
        $repository | Should -BeGreaterThan $static
        $script:Validator | Should -Not -Match 'Test-SkillGeneral\.ps1'
    }

    It 'UnitT60_keeps_repository_test_output_create_only_and_candidate_bound' {
        $testPath = Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1'
        $testText = Get-Content -LiteralPath $testPath -Raw
        $testText | Should -Match 'FileMode\]::CreateNew'
        $testText | Should -Match 'FileAccess\]::Write'
        $testText | Should -Match 'FileShare\]::None'
        $testText | Should -Match 'UTF8Encoding'
        $script:Validator | Should -Match 'trustedRoot'
        $script:Validator | Should -Match 'Assert-OutsideRoot'
        $script:Validator | Should -Match 'Assert-PathWithinRoot'
    }

    It 'UnitT70_binds_an_immutable_distinct_base_ancestor_before_invoking_the_central_runner' {
        $script:Validator | Should -Match 'rev-parse --verify --end-of-options'
        $script:Validator | Should -Match 'merge-base --is-ancestor'
        $script:Validator | Should -Match 'Base commit must be a distinct ancestor'
        $script:Validator | Should -Match 'BaseRevision'
        $script:Validator | Should -Match '--prefix=candidate-\$candidateCommit/'
    }

    It 'UnitT80_does_not_execute_a_candidate_domain_test_before_the_central_runner' {
        $childRunnerMarker = '$childRunnerText = @' + [char]39
        $entryPoint = $script:Validator.Substring(0, $script:Validator.IndexOf($childRunnerMarker))
        $entryPoint | Should -Not -Match 'Import-Module.*Pester'
        $entryPoint | Should -Not -Match '& \(Join-Path \$repoRoot ''scripts/Test-Repository\.ps1''\)'
    }
}
