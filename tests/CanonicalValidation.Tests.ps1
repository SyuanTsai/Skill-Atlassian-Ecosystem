# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Canonical Standard v1 validation adapter' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $script:Validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
        $script:Adapter = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'config/standard-v1.json') -Raw |
            ConvertFrom-Json -Depth 20
        $script:GitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
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

    It 'UnitT20_UsesTrustedMergeBaseAndRecordsSafeFallbackSource' {
        # Scenario: The protected workflow receives an event base and validates the candidate head.
        # Purpose: Compare from the actual Git merge-base and make a no-merge-base full-tree fallback auditable.
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml') -Raw
        $workflow | Should -Match 'merge-base \$baseCandidate \$candidateHead'
        $workflow | Should -Not -Match 'merge-base --is-ancestor \$baseCandidate \$candidateHead'
        $workflow | Should -Match "baseCommitSource = 'trusted-event-merge-base'"
        $workflow | Should -Match "baseCommitSource = 'safe-full-tree-no-merge-base'"
        $workflow | Should -Match ([regex]::Escape("'-BaseCommitSource', `$baseCommitSource"))
        $script:Validator | Should -Match '\[ValidateSet\('
        $script:Validator | Should -Match 'safe-full-tree-no-merge-base'
        $script:Validator | Should -Match 'baseCommitSource = \$resolvedBaseCommitSource'
        $script:Validator | Should -Match 'baseCommitInput = \$BaseCommitInput'
    }

    It 'UnitT21_RejectsAValidAncestorThatIsNotTheTrustedEventMergeBase' {
        # Scenario: The event base and candidate branch diverged, then the candidate gained a second commit.
        # Purpose: Bind trusted evidence to the actual unique merge-base instead of accepting any candidate ancestor.
        $tokens = $null
        $parseErrors = $null
        $validatorAst = [Management.Automation.Language.Parser]::ParseFile($script:ValidatorPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $definitions = @($validatorAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                        $node.Name -ceq 'Resolve-BaseCommitEvidence'
                }, $false))
        $definitions.Count | Should -Be 1
        . ([scriptblock]::Create($definitions[0].Extent.Text))

        $root = Join-Path $TestDrive 'merge-base-evidence-fixture'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $gitArguments = @('-c', "safe.directory=$root", '-c', "core.worktree=$root", '-C', $root)
        $invokeGit = {
            param([string[]] $Arguments)
            $output = @(& $script:GitPath @gitArguments @Arguments 2>&1)
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) { throw "Git test fixture command failed: $($Arguments -join ' ')`n$($output -join "`n")" }
            return $output
        }
        & $invokeGit @('init', '--quiet') | Out-Null
        & $invokeGit @('config', 'user.email', 'review@example.test') | Out-Null
        & $invokeGit @('config', 'user.name', 'Review Test') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'root.txt'), 'root')
        & $invokeGit @('add', '--', 'root.txt') | Out-Null
        & $invokeGit @('commit', '--quiet', '-m', 'root') | Out-Null
        $rootCommit = ([string]((& $invokeGit @('rev-parse', 'HEAD')) | Select-Object -First 1)).Trim()
        [IO.File]::WriteAllText((Join-Path $root 'event.txt'), 'event')
        & $invokeGit @('add', '--', 'event.txt') | Out-Null
        & $invokeGit @('commit', '--quiet', '-m', 'event') | Out-Null
        $eventBase = ([string]((& $invokeGit @('rev-parse', 'HEAD')) | Select-Object -First 1)).Trim()
        & $invokeGit @('checkout', '--quiet', '--detach', $rootCommit) | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'candidate-one.txt'), 'candidate-one')
        & $invokeGit @('add', '--', 'candidate-one.txt') | Out-Null
        & $invokeGit @('commit', '--quiet', '-m', 'candidate-one') | Out-Null
        $candidateAncestor = ([string]((& $invokeGit @('rev-parse', 'HEAD')) | Select-Object -First 1)).Trim()
        [IO.File]::WriteAllText((Join-Path $root 'candidate-two.txt'), 'candidate-two')
        & $invokeGit @('add', '--', 'candidate-two.txt') | Out-Null
        & $invokeGit @('commit', '--quiet', '-m', 'candidate-two') | Out-Null
        $candidateCommit = ([string]((& $invokeGit @('rev-parse', 'HEAD')) | Select-Object -First 1)).Trim()

        $trustedArguments = @{
            GitPath = $script:GitPath
            GitConfigArguments = @('-c', "safe.directory=$root", '-c', "core.worktree=$root")
            RepositoryRoot = $root
            CandidateCommit = $candidateCommit
            BaseCommitInput = $eventBase
            BaseCommitSource = 'trusted-event-merge-base'
        }
        {
            Resolve-BaseCommitEvidence @trustedArguments -BaseCommit $candidateAncestor
        } | Should -Throw '*does not match the actual unique merge-base*'

        $validEvidence = Resolve-BaseCommitEvidence @trustedArguments -BaseCommit $rootCommit
        $validEvidence.baseCommit | Should -Be $rootCommit
        $validEvidence.baseCommitInput | Should -Be $eventBase
        $validEvidence.baseCommitSource | Should -Be 'trusted-event-merge-base'

        {
            Resolve-BaseCommitEvidence @trustedArguments -BaseCommit '' -BaseCommitInput $eventBase -BaseCommitSource 'safe-full-tree-no-merge-base'
        } | Should -Throw '*distinct merge-base*'
        {
            Resolve-BaseCommitEvidence @trustedArguments -BaseCommit '' -BaseCommitInput $eventBase -BaseCommitSource 'safe-full-tree-invalid-event-range'
        } | Should -Throw '*non-full event input*'

        $invalidEventEvidence = Resolve-BaseCommitEvidence @trustedArguments -BaseCommit '' -BaseCommitInput 'invalid-event-base' -BaseCommitSource 'safe-full-tree-invalid-event-range'
        $invalidEventEvidence.baseCommit | Should -Be ''
        $invalidEventEvidence.baseCommitInput | Should -Be 'invalid-event-base'
        $invalidEventEvidence.baseCommitSource | Should -Be 'safe-full-tree-invalid-event-range'

        & $invokeGit @('checkout', '--quiet', '--orphan', 'unrelated-candidate') | Out-Null
        Get-ChildItem -LiteralPath $root -Force |
            Where-Object { $_.Name -cne '.git' } |
            Remove-Item -Recurse -Force
        [IO.File]::WriteAllText((Join-Path $root 'unrelated.txt'), 'unrelated')
        & $invokeGit @('add', '--', 'unrelated.txt') | Out-Null
        & $invokeGit @('commit', '--quiet', '-m', 'unrelated') | Out-Null
        $unrelatedCandidate = ([string]((& $invokeGit @('rev-parse', 'HEAD')) | Select-Object -First 1)).Trim()
        $noMergeEvidence = Resolve-BaseCommitEvidence `
            -GitPath $script:GitPath `
            -GitConfigArguments @('-c', "safe.directory=$root", '-c', "core.worktree=$root") `
            -RepositoryRoot $root `
            -CandidateCommit $unrelatedCandidate `
            -BaseCommit '' `
            -BaseCommitInput $eventBase `
            -BaseCommitSource 'safe-full-tree-no-merge-base'
        $noMergeEvidence.baseCommit | Should -Be ''
        $noMergeEvidence.baseCommitInput | Should -Be $eventBase
        $noMergeEvidence.baseCommitSource | Should -Be 'safe-full-tree-no-merge-base'

        {
            Resolve-BaseCommitEvidence @trustedArguments -BaseCommit '' -BaseCommitSource 'trusted-event-merge-base'
        } | Should -Throw '*requires a distinct immutable comparison base*'
        {
            Resolve-BaseCommitEvidence @trustedArguments -BaseCommit '' -BaseCommitInput $eventBase -BaseCommitSource 'safe-full-tree-no-event-base'
        } | Should -Throw '*must be empty*'
        {
            Resolve-BaseCommitEvidence @trustedArguments -BaseCommit '' -BaseCommitInput 'invalid-event-base' -BaseCommitSource 'safe-full-tree-no-merge-base'
        } | Should -Throw '*must be one lowercase full commit SHA*'
        $safeEvidence = Resolve-BaseCommitEvidence @trustedArguments -BaseCommit '' -BaseCommitSource 'safe-full-tree-no-event-base' -BaseCommitInput ''
        $safeEvidence.baseCommit | Should -Be ''
        $safeEvidence.baseCommitSource | Should -Be 'safe-full-tree-no-event-base'
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
            $skill | Should -Match 'scripts/Configure-'
            $skill | Should -Match 'scripts/Test-'
            if ($skillId -ceq 'configure-jira-api-access') {
                $skill | Should -Match 'Assert-NoReparseAncestors'
            }
            else {
                $skill | Should -Match 'references/host-resolved-fast-path\.md'
                $referencePath = Join-Path $script:RepositoryRoot "skills/$skillId/references/host-resolved-fast-path.md"
                Test-Path -LiteralPath $referencePath -PathType Leaf | Should -BeTrue
                $reference = Get-Content -LiteralPath $referencePath -Raw
                $reference | Should -Match 'Assert-NoReparseAncestors'
                $reference | Should -Match 'scripts/Configure-'
                $reference | Should -Match 'scripts/Test-'
            }
        }
    }

    It 'UnitT70_PreservesNestedSecurityFindingIdentityInSummary' {
        # Scenario: SkillSpector returns rule identity inside its nested issue object.
        # Purpose: Keep the final security summary traceable without exposing finding text or secrets.
        $tokens = $null
        $parseErrors = $null
        $validatorAst = [Management.Automation.Language.Parser]::ParseFile($script:ValidatorPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $definitions = @($validatorAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                        $node.Name -ceq 'Get-SanitizedSecurityFindingValue'
                }, $false))
        $definitions.Count | Should -Be 1
        . ([scriptblock]::Create($definitions[0].Extent.Text))

        $finding = [pscustomobject][ordered]@{
            stage = 'skillspector-static'
            skillId = 'configure-jira-api-access'
            issue = [pscustomobject][ordered]@{
                id = 'nested-rule-identity'
                finding_id = 'nested-finding-identity'
            }
        }
        Get-SanitizedSecurityFindingValue -Finding $finding -Names @('ruleId', 'rule', 'check', 'id') |
            Should -Be 'nested-rule-identity'
        Get-SanitizedSecurityFindingValue -Finding $finding -Names @('reportId', 'report', 'path', 'finding_id') |
            Should -Be 'nested-finding-identity'
    }

    It 'uses Unicode-aware case-insensitive inventory collision detection' {
        $repositoryValidator = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1') -Raw
        $repositoryValidator | Should -Match 'StringComparer\]::OrdinalIgnoreCase'
        $repositoryValidator | Should -Match 'Unicode case-insensitive path collision'
        $repositoryValidator | Should -Not -Match 'ConvertTo-AsciiLowerInvariant'
    }
}
