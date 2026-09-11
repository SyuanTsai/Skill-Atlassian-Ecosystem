# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Atlassian protected runner contracts' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $script:Validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
        $tokens = $null
        $parseErrors = $null
        $script:ValidatorAst = [Management.Automation.Language.Parser]::ParseFile($script:ValidatorPath, [ref]$tokens, [ref]$parseErrors)
        if (@($parseErrors).Count -ne 0) { throw 'Validator does not parse.' }
    }

    # Scenario: The validator declares the immutable test files required for every run.
    # Purpose: A newly added repository test cannot silently be excluded from formal evidence.
    It 'UnitT10_RequiresEveryActualAtlassianPesterTestFileExactlyOnce' {
        $definitions = @($script:ValidatorAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-RequiredPesterTests'
        }, $false))
        $definitions.Count | Should -Be 1
        . ([scriptblock]::Create($definitions[0].Extent.Text))
        $required = @(Get-RequiredPesterTests)
        @($required | Sort-Object -Unique).Count | Should -Be $required.Count
        $actual = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File | Select-Object -ExpandProperty Name | Sort-Object)
        @($required | Sort-Object) | Should -Be $actual
    }

    # Scenario: A candidate is evaluated through a materialized trusted test tree.
    # Purpose: Keep event-bound tests and completion proof outside candidate-controlled output.
    It 'UnitT20_BindsTestsAndCompletionToTheTrustedSupervisor' {
        $script:Validator | Should -Match 'Invoke-ProtectedPesterRunspace'
        $script:Validator | Should -Match 'CreateOutOfProcessRunspace'
        $script:Validator | Should -Match "completionAttestation = 'trusted-parent-post-exit'"
        $script:Validator | Should -Match '\$declaredTrustedSupervisorCommit = \[string\]\$env:TRUSTED_SUPERVISOR_COMMIT'
        $script:Validator | Should -Match '\$trustedPesterCommit = if \(\$isGitHubActions\)'
        $script:Validator | Should -Match '\[string\]\$env:GITHUB_SHA'
        $script:Validator | Should -Match 'Assert-TrustedGitTreeFile'
        $script:Validator | Should -Not -Match 'NamedPipeServerStream|NamedPipeClientStream|CompletionPipeName|CompletionToken'
        $script:Validator | Should -Match '\$pesterConfiguration.Run.Path = \$requiredPesterPaths'
        $script:Validator | Should -Match '\$pesterConfiguration.Run.PassThru = \$true'
        $script:Validator | Should -Match '\$pesterConfiguration.TestRegistry.Enabled = \$false'
        $script:Validator | Should -Match 'Invoke-Pester -Configuration \$pesterConfiguration'
    }

    # Scenario: The same canonical adapter runs on supported Windows and Linux hosts.
    # Purpose: Require kernel resource limits and offline execution for candidate code.
    It 'UnitT30_RequiresKernelLimitsAndOfflineCandidateExecution' {
        $script:Validator | Should -Match 'New-LinuxPesterCgroup'
        $script:Validator | Should -Match 'memory.max'
        $script:Validator | Should -Match 'pids.max'
        $script:Validator | Should -Match 'Get-LinuxCgroupCpuUsage'
        $script:Validator | Should -Match 'CreateRestrictedToken'
        $script:Validator | Should -Match 'SetInformationJobObject'
        $script:Validator | Should -Match '\[string\] \$NetworkProfile = ''Offline'''
        $script:Validator | Should -Match '-NetworkProfile TrustedSemantic'
    }
}
