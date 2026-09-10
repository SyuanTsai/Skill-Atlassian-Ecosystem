# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Canonical Standard v1 validation adapter' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $script:Validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
        $script:Adapter = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'config/standard-v1.json') -Raw |
            ConvertFrom-Json -Depth 20
    }

    It 'pins the approved authority and exact archive boundary' {
        # Scenario: The validator obtains the normative Standard v1 snapshot.
        # Purpose: Reject mutable branches, broad archive URLs, or an unbound authority.
        $script:Adapter.authority.archiveUrl | Should -Match '/zip/[0-9a-f]{40}$'
        $script:Adapter.authority.files.Count | Should -BeGreaterThan 10
        $script:Validator | Should -Match 'Artifacts root must be outside the candidate repository'
        $script:Validator | Should -Match 'baseCommit = \$resolvedBaseCommit'
    }

    It 'scans the complete candidate tree when comparison base is absent' {
        # Scenario: A push or manual run has no trusted event base.
        # Purpose: Check every committed candidate path instead of only HEAD's parent.
        $script:Validator | Should -Match 'emptyTreeObject = ''4b825dc642cb6eb9a060e54bf8d69288fbee4904'''
        $script:Validator | Should -Match ([regex]::Escape("'diff'") + '.*' + [regex]::Escape("'--check'") + '.*' + [regex]::Escape('$emptyTreeObject') + '.*' + [regex]::Escape("'HEAD'"))
        $script:Validator | Should -Not -Match 'diff-tree.*--root.*HEAD'
    }

    It 'uses isolated receipts and candidate-bound tool identities' {
        # Scenario: The canonical gate resolves its external toolchain for one run.
        # Purpose: Prevent persistent installs or unbound tool output from entering release evidence.
        $script:Validator | Should -Match ([regex]::Escape("Assert-ExternalReceiptFile -Receipt `$receipts.'skill-tools' -PathProperty 'nodePath'"))
        $script:Validator | Should -Match ([regex]::Escape("Assert-ReceiptFile -Receipt `$receipts.'skill-tools' -PathProperty 'entryPointPath'"))
        $script:Validator | Should -Match "'skillspector' = 'NVIDIA/SkillSpector'"
        $script:Validator | Should -Match "'skill-validator' = 'github.com/agent-ecosystem/skill-validator/cmd/skill-validator'"
        $script:Validator | Should -Match "'skill-tools' = 'npm:skill-tools'"
    }

    It 'UnitT32_CompletesSkillToolsPackageCheckBeforeStaticScanning' {
        # Scenario: The canonical adapter schedules the required formal tools.
        # Purpose: Enforce authority section 8.3 package validation before Static Scan.
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:ValidatorPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $calls = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-NativeChecked'
        }, $true))
        $packageCheck = @($calls | Where-Object { $_.Extent.Text.Contains('$skillToolsEntryPoint') -and $_.Extent.Text.Contains("'check'") })
        $staticScan = @($calls | Where-Object { $_.Extent.Text.Contains("'--no-llm'") })
        $packageCheck.Count | Should -Be 1
        $staticScan.Count | Should -Be 1
        $packageCheck[0].Extent.StartOffset | Should -BeLessThan $staticScan[0].Extent.StartOffset
    }

    # Scenario: A central semantic trigger is true or false with no opt-in switch.
    # Purpose: Execute required semantic review whenever the authority requires it.
    It 'UnitT35_UsesTheCentralSemanticTriggerWithoutAnOptInSwitch' -ForEach @(
        @{ Trigger = $true },
        @{ Trigger = $false }
    ) {
        $parseErrors = $null
        $tokens = $null
        $validatorAst = [Management.Automation.Language.Parser]::ParseFile($script:ValidatorPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $assignments = @($validatorAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -ceq '$semanticTriggered'
        }, $true))
        $assignments.Count | Should -Be 1
        $result = & {
            param($assignmentText, $triggerValue)
            $semanticTriggerCandidate = $triggerValue
            $EnableSemanticScan = $false
            . ([scriptblock]::Create($assignmentText))
            return $semanticTriggered
        } $assignments[0].Extent.Text $Trigger
        $result | Should -Be $Trigger
    }

    It 'UnitT40_KeepsValidationStageOrderingFailClosed' {
        $tokens = $null
        $parseErrors = $null
        $validatorAst = [Management.Automation.Language.Parser]::ParseFile(
            $script:ValidatorPath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        @($parseErrors).Count | Should -Be 0
        $semanticAssignments = @($validatorAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left.Extent.Text -ceq '$semanticTriggered'
                }, $true))
        $semanticAssignments.Count | Should -Be 1
        $semanticAssignments[0].Right.Extent.Text.Trim() | Should -Be '$semanticTriggerCandidate'
        $script:Validator | Should -Not -Match '\[switch\]\s+\$EnableSemanticScan'

        $script:Validator | Should -Match 'Test-SecurityRelevantSkillChange'
        $script:Validator | Should -Match '\$staticFindingCount -gt 0'
        $script:Validator | Should -Match 'Triggered SkillSpector semantic scan did not complete'
        $script:Validator | Should -Match 'repository-validation-post-pester'
        $script:Validator | Should -Match 'Invoke-ProtectedPesterRunspace'
        $script:Validator | Should -Match 'CreateOutOfProcessRunspace'
        $script:Validator | Should -Match '\$trustedPesterSupervisorMarker'
        $script:Validator | Should -Match '\$completionAttestationNonce'
        $script:Validator | Should -Match "completionAttestation = 'trusted-parent-post-exit'"
        $script:Validator | Should -Not -Match 'NamedPipeServerStream|NamedPipeClientStream|CompletionPipeName|CompletionToken|workerResultMarker'
        $script:Validator | Should -Match "ValidateSet\('Offline', 'TrustedSemantic'\)"
        $script:Validator | Should -Match '\[string\] \$NetworkProfile = ''Offline'''
        $script:Validator | Should -Match '-NetworkProfile TrustedSemantic'
        $script:Validator | Should -Match 'IsolateRunnerCommandFiles'
        $script:Validator | Should -Match 'TerminateProcessTree'
        $script:Validator | Should -Match 'ProtectRunnerCommandFiles'
        $script:Validator | Should -Match 'function New-ContainedProcessEnvironment'
        $script:Validator | Should -Match 'function Protect-ProcessCredentialEnvironment'
        $script:Validator | Should -Match 'SemanticCredentialNames'
        $script:Validator | Should -Match 'AdditionalEnvironmentVariables'
        $script:Validator | Should -Match 'EnvironmentVariables\.Clear\(\)'
        $script:Validator | Should -Match 'ACTIONS_RUNTIME_TOKEN'
        $script:Validator | Should -Match 'Assert-RunnerCommandFilesUnchanged'
        $script:Validator | Should -Match 'standard_v1_evidence_sha256'
        $script:Validator | Should -Not -Match 'pesterResultPath'
        $script:Validator | Should -Not -Match ([regex]::Escape("'-OutputPath', `$pesterResultPath"))
        $script:Validator | Should -Match 'postPesterCandidateCommit'
        $script:Validator | Should -Match 'postPesterTree'
        $script:Validator | Should -Match 'prePesterGitIndexSha256'
        $script:Validator | Should -Match 'Get-RepositoryRawSnapshot'
        $script:Validator | Should -Match 'Assert-RepositoryRawSnapshotUnchanged'
        $script:Validator | Should -Match 'postPesterRepositoryRawSnapshot'
        $script:Validator | Should -Match 'SkillSpector semantic scanner'
        $script:Validator | Should -Match 'Assert-ReceiptFile -Receipt \$receipts\.skillspector'
        $script:Validator | Should -Match 'Assert-ReceiptInstalledClosure'
        $script:Validator | Should -Match 'installedClosureSha256'
        $script:Validator | Should -Match 'installed closure contains a reparse-backed entry'
        $script:Validator | Should -Match 'Get-ChildItem -LiteralPath \$root -Recurse -Force'
        $script:Validator | Should -Match 'GIT_CONFIG_NOSYSTEM'
        $script:Validator | Should -Match 'core\.hooksPath'
        $script:Validator | Should -Match '\$repositoryValidatorPath'
        $script:Validator | Should -Match 'pesterRunnerPath'
        $script:Validator | Should -Match 'Invoke-TrustedPowerShellProcess -Command \$powerShellPath'
        $script:Validator | Should -Match "'-NoProfile'"
        $script:Validator | Should -Match "'route'"
        $script:Validator | Should -Match 'skill-tools route did not return exactly one result'
        $script:Validator | Should -Match '\$routeResults = @\(Read-JsonFile'
        $script:Validator | Should -Not -Match '\$routeResults -isnot \[array\]'
        $script:Validator | Should -Not -Match 'semantic.*continue|continue.*semantic'
        $postPesterInventoryIndex = $script:Validator.IndexOf('$postPesterRepositoryRawSnapshot')
        $semanticScanIndex = $script:Validator.IndexOf('Post-Pester SkillSpector semantic scan')
        $postPesterInventoryIndex | Should -BeGreaterThan -1
        $semanticAssignments[0].Extent.StartOffset | Should -BeGreaterThan $postPesterInventoryIndex
        $semanticScanIndex | Should -BeGreaterThan $postPesterInventoryIndex
    }

    It 'UnitT50_RequiresExplicitCredentialsAndCompleteValidation' {
        # Scenario: GitHub Actions invokes the same canonical validator as a local caller.
        # Purpose: Keep credentials explicit while preserving mandatory semantic and test gates.
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml') -Raw
        $workflow | Should -Not -Match 'EnableSemanticScan'
        $script:Validator | Should -Match '\[string\[\]\] \$SemanticCredentialNames = @\(\)'
        $script:Validator | Should -Not -Match '\[switch\]\s+\$EnableSemanticScan'
        $script:Validator | Should -Match 'SkippedCount -ne 0'
        $script:Validator | Should -Match 'security-preflight\.json'
        $script:Validator | Should -Match 'candidate-executing repository tests are not started'
    }

    It 'fails closed when base-commit evidence is absent for a security-relevant change' {
        # Scenario: A caller omits BaseCommit while validating a candidate that may change a Skill.
        # Purpose: Prevent conditional semantic scanning from being skipped by an incomplete invocation.
        $detector = $script:Validator.Substring($script:Validator.IndexOf('function Test-SecurityRelevantSkillChange'))
        $detector | Should -Match 'IsNullOrWhiteSpace\(\$BaseCommit\)'
    }

    It 'preserves the Atlassian access-path and credential boundaries' {
        # Scenario: A user selects a connector or REST path and validates credentials.
        # Purpose: Keep migration focused on contract hardening without weakening the product Skill rules.
        $jiraSkill = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'skills/work-with-jira/SKILL.md') -Raw
        $jiraSkill | Should -Match 'After resolving the target site, use only the access path selected by the user'
        $jiraSkill | Should -Match 'Never print, log, persist'
        $jiraSkill | Should -Match 'JIRA_API_BASE_URL'
    }

    It 'rejects reparse points before binding installed Atlassian helpers' {
        # Scenario: A writable installed Skill tree redirects a helper through a symlink.
        # Purpose: Keep hidden credentials inside the host-resolved helper root.
        foreach ($skillId in @('configure-jira-api-access', 'configure-bitbucket-api-access', 'configure-confluence-api-access')) {
            $skill = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot "skills/$skillId/SKILL.md") -Raw
            $skill | Should -Match 'Assert-NoReparseAncestors'
            $skill | Should -Match 'scripts/Configure-'
            $skill | Should -Match 'scripts/Test-'
        }
    }

    It 'uses Unicode-aware case-insensitive inventory collision detection' {
        $repositoryValidator = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1') -Raw
        $repositoryValidator | Should -Match 'StringComparer\]::OrdinalIgnoreCase'
        $repositoryValidator | Should -Match 'Unicode case-insensitive path collision'
        $repositoryValidator | Should -Not -Match 'ConvertTo-AsciiLowerInvariant'
    }
}
