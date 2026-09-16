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

    It 'UnitT10_delegates_security_and_stage_orchestration_to_the_pinned_central_runner' {
        $script:Validator | Should -Match 'Invoke-StandardValidation\.ps1'
        $script:Validator | Should -Match 'standard-validation-adapter\.json'
        $script:Validator | Should -Match 'ToolchainSha256'
        $script:Validator | Should -Match 'repository-test-atlassian'
        $script:Validator | Should -Match 'repository-test-pester'
        $script:Validator | Should -Match '\$trustedRoot'
        $script:Validator | Should -Match 'Assert-FileIdentity'
        $script:Validator | Should -Not -Match 'function Invoke-NativeChecked'
        $script:Validator | Should -Not -Match 'function New-LinuxPesterCgroup'
    }

    It 'UnitT20_materializes_candidate_and_tool_inputs_outside_the_candidate_root' {
        $script:Validator | Should -Match 'Assert-OutsideRoot -Path \$artifactsRootPath -Root \$repoRoot'
        $script:Validator | Should -Match 'Assert-NoReparseAncestors -Path \$resolvedToolsRoot'
        $script:Validator | Should -Match 'Assert-NoReparseAncestors -Path \$candidateExtractRoot'
        $script:Validator | Should -Match 'candidateArchivePath'
        $script:Validator | Should -Match 'candidateArchiveSha256'
        $script:Validator | Should -Match 'frozenForRun'
        $script:Validator | Should -Match 'receipt'
    }

    It 'UnitT30_keeps_the_Atlassian_domain_adapter_inside_repository_tests' {
        $childRunnerMarker = '$childRunnerText = @' + [char]39
        $childText = $script:Validator.Substring($script:Validator.IndexOf($childRunnerMarker))
        $childText | Should -Match "'repository-atlassian'"
        $childText | Should -Match 'scripts[/\\]Test-Repository\.ps1'
        $childText | Should -Match 'tests[/\\]validate-repository\.ps1'
        $childText | Should -Match 'tests[/\\]validate-repository-standalone\.ps1'
        $childText | Should -Match 'tests[/\\]validate-api-access\.ps1'
        $childText | Should -Match 'testInventory'
        $childText | Should -Match 'domainAdapterResult'
    }

    It 'UnitT40_requires_the_protected_adapter_for_pull_requests' {
        $workflowPath = Join-Path $script:RepositoryRoot '.github/workflows/validate.yml'
        $workflow = Get-Content -LiteralPath $workflowPath -Raw -Encoding UTF8
        $workflow | Should -Match '(?m)^on:\s*$'
        $workflow | Should -Match '(?m)^\s+pull_request_target:\s*$'
        $workflow | Should -Not -Match '(?m)^\s+pull_request:\s*$'
        $workflow | Should -Match '(?m)^\s+push:\s*$'
        $workflow | Should -Match '(?m)^\s+- main\s*$'
        $workflow | Should -Match 'github\.event_name == ''pull_request_target'' && github\.event\.pull_request\.head\.sha'
        $workflow | Should -Match '(?m)^\s+TRUSTED_SUPERVISOR_COMMIT: \$\{\{ github\.sha \}\}\s*$'
        $workflow | Should -Match 'PULL_REQUEST_BASE_SHA'
        $workflow | Should -Match 'event-bound pull-request base commit'
        $workflow | Should -Match '\$env:GITHUB_EVENT_NAME -eq ''pull_request_target'''
        $workflow | Should -Match 'persist-credentials: false'
        $workflow | Should -Match 'TRUSTED_SUPERVISOR_ROOT'
    }
}
