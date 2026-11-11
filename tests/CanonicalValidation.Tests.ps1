# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Canonical Standard v1 validation adapter' {
    BeforeAll {
        function Get-CanonicalWorkflowRunScript {
            param(
                [Parameter(Mandatory)][string] $WorkflowPath,
                [Parameter(Mandatory)][string] $StepName
            )

            $lines = [IO.File]::ReadAllLines($WorkflowPath)
            $stepIndex = -1
            for ($index = 0; $index -lt $lines.Length; $index++) {
                if ($lines[$index] -ceq "      - name: $StepName") { $stepIndex = $index; break }
            }
            if ($stepIndex -lt 0) { throw "The named workflow step '$StepName' is absent." }

            $runIndex = -1
            for ($index = $stepIndex + 1; $index -lt $lines.Length; $index++) {
                if ($lines[$index] -ceq '        run: |') { $runIndex = $index; break }
                if ($lines[$index] -match '^      - name:') { break }
            }
            if ($runIndex -lt 0) { throw "The named workflow step '$StepName' has no literal run block." }

            $bodyLines = [System.Collections.Generic.List[string]]::new()
            for ($index = $runIndex + 1; $index -lt $lines.Length; $index++) {
                $line = $lines[$index]
                if ([string]::IsNullOrWhiteSpace($line)) { $bodyLines.Add(''); continue }
                if (-not $line.StartsWith('          ', [StringComparison]::Ordinal)) { break }
                $bodyLines.Add($line.Substring(10))
            }
            $body = [string]::Join("`n", $bodyLines.ToArray())
            $tokens = $null
            $parseErrors = $null
            [Management.Automation.Language.Parser]::ParseInput($body, [ref]$tokens, [ref]$parseErrors) | Out-Null
            if (@($parseErrors).Count -gt 0) { throw "The extracted workflow step '$StepName' does not parse." }
            return $body
        }

        function Invoke-CanonicalWorkflowChild {
            param(
                [Parameter(Mandatory)][string] $ScriptPath,
                [Parameter(Mandatory)][System.Collections.IDictionary] $Environment
            )

            $pwshPath = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $pwshPath
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $ScriptPath)) {
                [void]$startInfo.ArgumentList.Add($argument)
            }
            foreach ($key in $Environment.Keys) { $startInfo.Environment[[string]$key] = [string]$Environment[$key] }

            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            [void]$process.Start()
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
        }

        function Get-CanonicalValidationObserverPrivacyAssessment {
            param(
                [Parameter(Mandatory)][string] $Transcript,
                [string] $ExpectedInjectedRuntimeError
            )
            $privatePattern = 'SYP171_PRIVATE_SENTINEL_59b62|SYP171_PRIVATE_KEY_SENTINEL|SYP171_PRIVATE_SKILL_KEY|SYP171_PRIVATE_COMPLETENESS_KEY|SYP171_PRIVATE_DEEP_PROPERTY|SYP171_PRIVATE_NESTED_SENTINEL|SYP171_PRIVATE_ENUM_SENTINEL|SYP171_PRIVATE_TAINTED_LEDGER_MESSAGE|SYP171_PRIVATE_SERIALIZER_SENTINEL|::add-mask::'
            $lines = @($Transcript -split "`r?`n")
            $privateLines = @($lines | Where-Object { $_ -match $privatePattern })
            $injectedRuntimePattern = if ($ExpectedInjectedRuntimeError -ceq 'SYP171_PRIVATE_SERIALIZER_SENTINEL') {
                '^PS>TerminatingError\(\): "' + [regex]::Escape($ExpectedInjectedRuntimeError) + '"$'
            }
            else { $null }
            $existingStreamPrivateLines = @($privateLines | Where-Object {
                $_ -cmatch '^STANDARD_STATIC_EVIDENCE_CHUNK\|(?:stdout|stderr)\|[0-9]{6}\|'
            })
            $injectedRuntimeLines = @(
                if ($null -ne $injectedRuntimePattern) {
                    $privateLines | Where-Object { $_ -cmatch $injectedRuntimePattern }
                }
            )
            $unclassifiedPrivateLines = @($privateLines | Where-Object {
                $_ -cnotmatch '^STANDARD_STATIC_EVIDENCE_CHUNK\|(?:stdout|stderr)\|[0-9]{6}\|' -and
                    ($null -eq $injectedRuntimePattern -or $_ -cnotmatch $injectedRuntimePattern)
            })
            $observerDiagnosticLines = @($lines | Where-Object {
                $_.StartsWith('STANDARD_STATIC_PROVIDER_DIAGNOSTIC|', [StringComparison]::Ordinal) -or
                    $_.StartsWith('STANDARD_STATIC_PROVIDER_CAPTURE_STATUS=', [StringComparison]::Ordinal) -or
                    $_.StartsWith('STANDARD_STATIC_PROVIDER_CAPTURE_REASON=', [StringComparison]::Ordinal) -or
                    $_.Contains('The provider report could not be retained by the diagnostic observer.')
            })
            [pscustomobject]@{
                PrivateLines = $privateLines
                ExistingStreamPrivateLines = $existingStreamPrivateLines
                InjectedRuntimeLines = $injectedRuntimeLines
                UnclassifiedPrivateLines = $unclassifiedPrivateLines
                ObserverDiagnosticLines = $observerDiagnosticLines
            }
        }

        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $script:Validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
        $script:Adapter = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'config/standard-v1.json') -Raw |
            ConvertFrom-Json -Depth 20
        $script:GitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
    }

    # Scenario: The ordinary entry point is called on a non-Windows host.
    # Purpose: Retire the legacy Linux namespace/cgroup route before any source or candidate process starts.
    It 'UnitT05_RequiresWindowsBeforeOrdinaryValidationDispatch' {
        $sourceEntry = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1') -Raw
        $validatorPrelude = $script:Validator.Substring(0, $script:Validator.IndexOf('if ($SourceConformance'))
        $sourcePrelude = $sourceEntry.Substring(0, $sourceEntry.IndexOf('function Assert-ExactPropertySet'))
        $validatorPrelude | Should -Match 'if \(-not \$IsWindows\) \{ throw ''Standard v1 canonical validation requires Windows with PowerShell 7\.'' \}'
        $sourcePrelude | Should -Match 'if \(-not \$IsWindows\) \{ throw ''Standard v1 canonical validation requires Windows with PowerShell 7\.'' \}'
    }

    It 'UnitT06_DoesNotRequireRetiredWindowsPowerShell51Contract' {
        # Scenario: Source regression runs on the supported PowerShell 7 host.
        # Purpose: Keep the retired PS5.1 check out of the ordinary candidate gate.
        $sourceEntry = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1') -Raw
        $sourceEntry | Should -Not -Match '(?i)Get-Command powershell\.exe|windowsPowerShell51'
        $sourceEntry | Should -Match 'Pester repository regression did not complete successfully'
    }

    It 'UnitT10_PinsApprovedAuthorityAndExactArchiveBoundary' {
        # Scenario: The validator obtains the normative Standard v1 snapshot.
        # Purpose: Reject mutable branches, broad archive URLs, or an unbound authority.
        $script:Adapter.authority.commit | Should -Be '472cbd6f533d3f6d0a5381862128ebcc87618a7c'
        $script:Adapter.authority.archiveUrl | Should -Match '/zip/[0-9a-f]{40}$'
        $script:Adapter.authority.archiveSha256 | Should -Be '357def24360566e9351af5c7b3bb8b8a7989f9ccb1eaf6f2401fa33e4069d8bf'
        $script:Adapter.authority.files.Count | Should -Be 60
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

    It 'UnitT20_BindsTheProtectedDriverAndEventCandidateToTheMergeBase' {
        # Scenario: GitHub validates the immutable PR head using the protected event-base driver.
        # Purpose: Bind the comparison merge-base separately from the protected driver revision.
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml') -Raw
        $sourceEntry = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1') -Raw
        $workflow | Should -Match 'baseHead -cne \$driverCommit'
        $workflow | Should -Match 'candidateCommit -cne \$env:CANDIDATE_SHA'
        $workflow | Should -Match 'PULL_REQUEST_BASE_SHA'
        $workflow | Should -Match 'merge-base \$eventBase \$candidateCommit'
        $workflow | Should -Match '-SourceValidation -BaseCommit \$env:SOURCE_BASE_COMMIT'
        $workflow | Should -Match 'prepared\.sourceRevision -cne \$env:SOURCE_CANDIDATE_COMMIT'
        $sourceEntry | Should -Match 'merge-base --is-ancestor \$baseRevision \$candidateCommit'
        $sourceEntry | Should -Match '\$semanticRequired = Test-SkillSpectorExceptionCandidateChange -GitPath \$gitPath -RepositoryRoot \$repoRoot -BaseRevision \$baseRevision -CandidateRevision \$candidateCommit'
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

        $implicitSafeEvidence = Resolve-BaseCommitEvidence `
            -GitPath $script:GitPath `
            -GitConfigArguments @('-c', "safe.directory=$root", '-c', "core.worktree=$root") `
            -RepositoryRoot $root `
            -CandidateCommit $candidateCommit `
            -BaseCommitSource 'caller-supplied'
        $implicitSafeEvidence.baseCommit | Should -Be ''
        $implicitSafeEvidence.baseCommitInput | Should -Be ''
        $implicitSafeEvidence.baseCommitSource | Should -Be 'safe-full-tree-no-supplied-base'
    }

    # Scenario: a pre-push caller has several pending commits and omits the comparison base.
    # Purpose: Reject a one-parent comparison that would omit earlier pending source changes.
    It 'UnitT22_RequiresExplicitPrePushBaseForTheCompletePendingRange' {
        $sourcePath = Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1'
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $definition = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Resolve-SourceComparisonBaseInput'
        }, $false))
        $definition.Count | Should -Be 1
        . ([scriptblock]::Create($definition[0].Extent.Text))
        { Resolve-SourceComparisonBaseInput -BaseCommit '' -EventName 'pre-push' } |
            Should -Throw '*explicit base revision*'
        Resolve-SourceComparisonBaseInput -BaseCommit ('a' * 40) -EventName 'pre-push' |
            Should -Be ('a' * 40)
        Resolve-SourceComparisonBaseInput -BaseCommit '' -EventName 'local' |
            Should -Be 'HEAD^'
        (Get-Content -LiteralPath $sourcePath -Raw) |
            Should -Match 'Resolve-SourceComparisonBaseInput -BaseCommit \$BaseCommit -EventName \$eventName'
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
    It 'UnitT35_UsesTheCentralSemanticTriggerWithoutAnOptInSwitch_<Trigger>' -ForEach @(
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
        $script:Validator | Should -Match '-StandardOutputPath \$reportPath -StandardErrorPath \$stderrPath'
        $script:Validator | Should -Match '-StandardOutputPath \$semanticPath -StandardErrorPath \$semanticStderrPath'
        $script:Validator | Should -Not -Match '@\(''scan'', \$skillRoot, ''--no-llm'', ''--format'', ''json'', ''--output'''
        $script:Validator | Should -Not -Match '@\(''scan'', \$skillRoot, ''--format'', ''json'', ''--output'''
        $script:Validator | Should -Match 'Substring\(0, 4096\)'
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
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml') -Raw
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

    It 'keeps Jira Web route decisions and projection boundaries source-owned' {
        # Scenario: A projected Skill runs with or without a connector and receives read or write intent.
        # Purpose: Verify the declared source contract blocks site, permission, authorization, and readback gaps without switching paths.
        $skillRoot = Join-Path $script:RepositoryRoot 'skills/work-with-jira'
        $contract = Get-Content -LiteralPath (Join-Path $skillRoot 'references/web-capability-contract.json') -Raw |
            ConvertFrom-Json -Depth 20
        $fixture = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'tests/fixtures/work-with-jira-web-capabilities.json') -Raw |
            ConvertFrom-Json -Depth 20
        $skill = Get-Content -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Raw

        $contract.schemaVersion | Should -Be 1
        $contract.skillId | Should -Be 'work-with-jira'
        $fixture.skillId | Should -Be $contract.skillId
        $contract.projection.sourceOwned | Should -BeTrue
        $contract.projection.secretsInProjection | Should -BeFalse
        $contract.sourceFixture | Should -Be 'tests/fixtures/work-with-jira-web-capabilities.json'
        $contract.paths.connector.localEnvironmentRequired | Should -BeFalse
        $contract.paths.rest.localEnvironmentRequired | Should -BeTrue
        $contract.routing.defaultDecision | Should -Be 'block'
        $contract.routing.selectedPathRequired | Should -BeTrue
        $contract.routing.fallbackAllowed | Should -BeFalse
        $skill | Should -Match 'references/web-capability-contract.json'
        @($fixture.cases).Count | Should -BeGreaterThan 10

        foreach ($case in @($fixture.cases)) {
            $decision = [string]$contract.routing.defaultDecision
            $selected = [string]$case.selectedPath
            if (-not [string]::IsNullOrWhiteSpace($selected) -and
                @($contract.paths.PSObject.Properties.Name) -ccontains $selected) {
                $required = if ($case.intent -ceq 'read') {
                    @($contract.routing.readRequirements)
                }
                elseif ($case.intent -cin @('write', 'create')) {
                    @($contract.routing.writeRequirements)
                }
                else { throw "Unexpected Jira fixture intent: $($case.intent)" }
                if ($case.intent -ceq 'create' -and $selected -ceq 'connector') {
                    $required += @($contract.routing.connectorCreateRequirements)
                }
                $missing = @($required | Where-Object {
                    $property = $case.PSObject.Properties[[string]$_]
                    $null -eq $property -or $property.Value -ne $true
                })
                if ($missing.Count -eq 0) { $decision = $selected }
            }
            if ($decision -cne [string]$case.expected) {
                throw "Jira Web fixture '$($case.name)' resolved '$decision', expected '$($case.expected)'."
            }
        }
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

    # Scenario: The privacy helper sees the one expected serializer-failure runtime record.
    # Purpose: Allow only the exact injected PowerShell transcript line when its test context is explicitly named.
    It 'UnitT75_ClassifiesOnlyTheExactKnownInjectedSerializerRuntimeLine' {
        $expected = 'SYP171_PRIVATE_SERIALIZER_SENTINEL'
        $runtimeLine = 'PS>TerminatingError(): "' + $expected + '"'
        $withContext = Get-CanonicalValidationObserverPrivacyAssessment -Transcript $runtimeLine -ExpectedInjectedRuntimeError $expected
        $withContext.PrivateLines.Count | Should -Be 1
        $withContext.InjectedRuntimeLines.Count | Should -Be 1
        $withContext.UnclassifiedPrivateLines | Should -BeNullOrEmpty

        $withoutContext = Get-CanonicalValidationObserverPrivacyAssessment -Transcript $runtimeLine
        $withoutContext.PrivateLines.Count | Should -Be 1
        $withoutContext.InjectedRuntimeLines.Count | Should -Be 0
        $withoutContext.UnclassifiedPrivateLines.Count | Should -Be 1
    }

    # Scenario: Similar text appears as raw host output, a warning, or a malformed runtime record.
    # Purpose: Keep every serializer-sentinel spelling private and unclassified unless the exact injected record matches.
    It 'UnitT76_RejectsUntrustedSerializerSentinelOutputVariants' {
        $expected = 'SYP171_PRIVATE_SERIALIZER_SENTINEL'
        $runtimeLine = 'PS>TerminatingError(): "' + $expected + '"'
        $untrustedLines = @(
            $expected,
            ('HOST OUTPUT: ' + $expected),
            ('WARNING: ' + $expected),
            ('prefix ' + $runtimeLine),
            ($runtimeLine + ' suffix'),
            $runtimeLine.ToLowerInvariant(),
            ('PS>TerminatingError(): "' + $expected + '_OTHER"')
        )

        foreach ($line in $untrustedLines) {
            $assessment = Get-CanonicalValidationObserverPrivacyAssessment -Transcript $line -ExpectedInjectedRuntimeError $expected
            $assessment.PrivateLines.Count | Should -Be 1
            $assessment.InjectedRuntimeLines.Count | Should -Be 0
            $assessment.UnclassifiedPrivateLines.Count | Should -Be 1
        }
    }
    It 'uses Unicode-aware case-insensitive inventory collision detection' {
        $repositoryValidator = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1') -Raw
        $repositoryValidator | Should -Match 'StringComparer\]::OrdinalIgnoreCase'
        $repositoryValidator | Should -Match 'Unicode case-insensitive path collision'
        $repositoryValidator | Should -Not -Match 'ConvertTo-AsciiLowerInvariant'
    }

    # Scenario: Each event has one source execution and three required mirrors.
    # Purpose: Keep required contexts stable while replacing the v1 workflow route.
    It 'UnitT78_UsesOneCoreV2SourceRouteAndOnlyTheCanonicalWorkflow' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml') -Raw
        @([IO.Directory]::GetFiles((Join-Path $script:RepositoryRoot '.github/workflows')) | ForEach-Object { [IO.Path]::GetFileName($_) }) | Should -Be @('validate.yml')
        ([regex]::Matches($workflow, '(?m)^  canonical-validation:')).Count | Should -Be 1
        $workflow | Should -Match '(?m)^    name: Atlassian Ecosystem Standard v1\r?$'
        $workflow | Should -Match '(?m)^    runs-on: windows-latest\r?$'
        $workflow | Should -Match '(?m)^    timeout-minutes: 90\r?$'
        ([regex]::Matches($workflow, '-PrepareSourceTools\b')).Count | Should -Be 1
        ([regex]::Matches($workflow, '-SourceValidation\b')).Count | Should -Be 1
        ([regex]::Matches($workflow, [regex]::Escape('-File (Join-Path $baseRoot ''scripts/Validate.ps1'')'))).Count | Should -Be 2
        ([regex]::Matches($workflow, '-RepositoryRoot \$candidateRoot -AdapterVersion 2')).Count | Should -Be 2
        $workflow | Should -Not -Match '-SourceConformance|source_conformance:|Observe Stage 4|Route source conformance|Require source conformance'
        $workflow | Should -Not -Match 'Join-Path \$candidateRoot ''scripts/(Validate\.ps1|StandardSourceDriver\.psm1)'''
    }

    It 'UnitT79_UsesProtectedCheckoutRefsAndRawGitBytes' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml') -Raw
        $workflow | Should -Match 'CHECKOUT_ACTION_REFERENCE: &checkout-action-reference actions/checkout@[0-9a-f]{40}'
        ([regex]::Matches($workflow, 'uses: \*checkout-action-reference')).Count | Should -Be 3
        ([regex]::Matches($workflow, 'fetch-depth: 0')).Count | Should -Be 3
        ([regex]::Matches($workflow, 'persist-credentials: false')).Count | Should -Be 3
        $workflow | Should -Match ([regex]::Escape('ref: ${{ github.event.pull_request.base.sha || (github.event.before != ''0000000000000000000000000000000000000000'' && github.event.before) || github.sha }}'))
        $workflow | Should -Match ([regex]::Escape('ref: ${{ github.event.pull_request.head.sha || github.sha }}'))
        $workflow | Should -Match '(?m)^          path: candidate\r?$'
        $workflow | Should -Match 'GIT_CONFIG_KEY_0: core.autocrlf\r?\n      GIT_CONFIG_VALUE_0: ''false'''
        $workflow | Should -Match 'GIT_CONFIG_KEY_1: core.eol\r?\n      GIT_CONFIG_VALUE_1: lf'
    }

    It 'UnitT80_FailsClosedWithoutADistinctEventMergeBase' {
        $body = Get-CanonicalWorkflowRunScript -WorkflowPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml') -StepName 'Verify protected driver, merge-base, candidate and authority bindings'
        $body | Should -Match 'eventName -eq ''pull_request'''
        $body | Should -Match 'eventName -eq ''push'''
        $body | Should -Match 'PUSH_BEFORE_SHA -notmatch.*0\+'
        $body | Should -Match ([regex]::Escape('if ($eventBase -cnotmatch ''^[0-9a-f]{40}$'')'))
        $body | Should -Match 'Get-Commit \$candidateRoot \$eventBase'
        $body | Should -Match 'merge-base \$eventBase \$candidateCommit'
        $body | Should -Match 'mergeBase.Count -ne 1'
        $body | Should -Match ([regex]::Escape('[string]$mergeBase[0] -cnotmatch ''^[0-9a-f]{40}$'''))
        $body | Should -Match 'baseCommit -ceq \$candidateCommit'
        $body | Should -Match 'merge-base --is-ancestor \$baseCommit \$candidateCommit'
        $body | Should -Match '\$driverCommit = \$eventBase'
        $body | Should -Match 'baseCommit = \$baseCommit; protectedDriverCommit = \$driverCommit; candidateCommit = \$candidateCommit'
        $body | Should -Match 'authorityCommit = \$authorityCommit'
        $body | Should -Not -Match 'HEAD\^'
    }

    It 'UnitT81_ValidatesCandidateAuthorityThroughTheProtectedBaseModule' {
        $workflowPath = Join-Path $script:RepositoryRoot '.github/workflows/validate.yml'
        $workflow = Get-Content -LiteralPath $workflowPath -Raw
        $read = Get-CanonicalWorkflowRunScript -WorkflowPath $workflowPath -StepName 'Read candidate authority pin with protected base driver'
        $verify = Get-CanonicalWorkflowRunScript -WorkflowPath $workflowPath -StepName 'Verify protected driver, merge-base, candidate and authority bindings'
        foreach ($body in @($read, $verify)) {
            $body | Should -Match ([regex]::Escape('Import-Module (Join-Path $baseRoot ''scripts/StandardSourceDriver.psm1'') -Force'))
            $body | Should -Not -Match '(?i)Import-Module\s+.*\$candidateRoot'
        }
        $read | Should -Match ([regex]::Escape('Join-Path $candidateRoot ''config/standard-v1.json'''))
        $read | Should -Match 'Assert-AtlassianSourceAuthorityConfig -Config \$config'
        $verify | Should -Match ([regex]::Escape('Join-Path $candidateRoot ''config/standard-v1.json'''))
        $verify | Should -Match 'Assert-AtlassianSourceAuthorityConfig -Config \$candidateConfig'
        $verify | Should -Not -Match 'Join-Path \$baseRoot ''config/standard-v1\.json''|candidatePin|differs from protected base'
        $verify | Should -Match 'authorityCommit -cne \[string\]\$pin.commit'
        $verify | Should -Match 'Protected base, candidate and authority must be clean'
        $verify | Should -Match 'Expected an independent Git checkout root'
        $workflow | Should -Not -Match '(?im)^\s*Import-Module\s+.*\$candidateRoot.*\.(psm1|ps1)'
        $workflow | Should -Not -Match '(?im)^\s*\.\s+.*\$candidateRoot.*\.(psm1|ps1)'
        $workflow | Should -Not -Match 'RUNNER_TEMP[^\r\n]*[\\/]cc|runner\.temp[^\r\n]*[\\/]cc'
        $workflow | Should -Match '\$sourceRoot\s+''evidence-index\.json'''
    }

    It 'UnitT77_MirrorsCanonicalJobSuccessFailClosed_<Context>' -ForEach @(
        @{ Context = 'repository-contract' },
        @{ Context = 'skill-validator' },
        @{ Context = 'skill-tools' }
    ) {
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml') -Raw
        $job = [regex]::Match($workflow, ('(?ms)^  ' + [regex]::Escape($Context) + ':\r?\n(?<body>.*?)(?=^  [a-z-]+:|\z)')).Groups['body'].Value
        $job | Should -Match ('name: ' + [regex]::Escape($Context))
        $job | Should -Match 'if: always\(\)'
        $job | Should -Match 'needs: canonical-validation'
        $job | Should -Match 'runs-on: ubuntu-latest'
        $job | Should -Match 'shell: bash'
        $job | Should -Match ([regex]::Escape('CANONICAL_RESULT: ${{ needs[''canonical-validation''].result }}'))
        $run = $job.Substring($job.IndexOf('        run: |', [StringComparison]::Ordinal))
        $run | Should -Not -Match '\$\{\{'
        $run | Should -Match 'if \[\[ "\$CANONICAL_RESULT" != ''success'' \]\]; then[\s\S]*?exit 1'
    }

    # Scenario: The protected child returns PASS, BLOCKED, or FAILED.
    # Purpose: Preserve the actual process exit and saved evidence through the workflow.
    It 'InterT97_PropagatesTheCoreV2NativeExitCode_<ExitCode>' -ForEach @(
        @{ ExitCode = 0 }, @{ ExitCode = 10 }, @{ ExitCode = 20 }
    ) {
        $caseRoot = Join-Path $TestDrive ('core-v2-exit-' + [guid]::NewGuid().ToString('N'))
        $baseRoot = Join-Path $caseRoot 'base'
        $candidateRoot = Join-Path $baseRoot 'candidate'
        $sourceRoot = Join-Path $caseRoot 'source'
        foreach ($path in @((Join-Path $baseRoot 'scripts'), $candidateRoot, (Join-Path $sourceRoot 'source-tools'))) {
            [void](New-Item -ItemType Directory -Path $path -Force)
        }
        $stub = @'
param(
    [string] $RepositoryRoot, [int] $AdapterVersion, [switch] $SourceValidation,
    [string] $BaseCommit, [string] $ArtifactsRoot, [string] $SourceToolsPath,
    [string] $AuthorityRepositoryRoot, [string] $TrustedToolRoot,
    [string] $ExpectedGoRuntimeVersion, [int] $TimeoutSeconds
)
Set-StrictMode -Version Latest
if (-not $SourceValidation -or $AdapterVersion -ne 2 -or
    $RepositoryRoot -cne (Join-Path $env:GITHUB_WORKSPACE 'candidate') -or
    $BaseCommit -cne $env:SOURCE_BASE_COMMIT) { throw 'Invalid protected source boundary.' }
[IO.File]::WriteAllText((Join-Path $env:SOURCE_ROOT 'boundary.json'), '{"driver":"protected-base"}')
exit ([int]$env:SYP482_TEST_EXIT_CODE)
'@
        [IO.File]::WriteAllText((Join-Path $baseRoot 'scripts/Validate.ps1'), $stub, [Text.UTF8Encoding]::new($false))
        $receipt = [ordered]@{ runId = ('a' * 32); sourceRevision = ('b' * 40); authorityRevision = ('c' * 40) }
        [IO.File]::WriteAllText((Join-Path $sourceRoot 'source-tools/source-tools.json'), ($receipt | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $body = Get-CanonicalWorkflowRunScript -WorkflowPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml') -StepName 'Run Core v2 source validation with protected base driver'
        $launch = Join-Path $caseRoot 'launch.ps1'
        [IO.File]::WriteAllText($launch, ("Set-StrictMode -Version Latest`n" + $body), [Text.UTF8Encoding]::new($false))
        $result = Invoke-CanonicalWorkflowChild -ScriptPath $launch -Environment @{
            GITHUB_WORKSPACE = $baseRoot; SOURCE_ROOT = $sourceRoot
            SOURCE_PREPARED_RUN_ID = $receipt.runId; SOURCE_CANDIDATE_COMMIT = $receipt.sourceRevision
            SOURCE_AUTHORITY_COMMIT = $receipt.authorityRevision; SOURCE_BASE_COMMIT = ('d' * 40)
            STANDARD_GO_RUNTIME_VERSION = '1.25.1'; SYP482_TEST_EXIT_CODE = [string]$ExitCode
        }
        $result.ExitCode | Should -Be $ExitCode -Because "stdout=$($result.Stdout); stderr=$($result.Stderr)"
        [IO.File]::ReadAllText((Join-Path $sourceRoot 'source-validation-exit.txt')) | Should -Be ([string]$ExitCode)
        [IO.File]::ReadAllText((Join-Path $sourceRoot 'boundary.json')) | Should -Be '{"driver":"protected-base"}'
    }
}
