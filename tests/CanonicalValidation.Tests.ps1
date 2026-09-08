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

    It 'keeps validation stage ordering fail closed' {
        # Scenario: Package validation, static scanning, repository tests, and
        # explicitly requested semantic scanning run in canonical order.
        # Purpose: Ensure no later stage can mask an earlier package or static failure.
        $packageIndex = $script:Validator.IndexOf('skill-validator package validation for')
        $staticIndex = $script:Validator.IndexOf('SkillSpector static scan for')
        $repositoryIndex = $script:Validator.IndexOf('$repositoryReportPath')
        $packageIndex | Should -BeGreaterThan -1
        $staticIndex | Should -BeGreaterThan $packageIndex
        $repositoryIndex | Should -BeGreaterThan $staticIndex
        $script:Validator | Should -Match 'Assert-SkillSpectorReport'
        $script:Validator | Should -Match "validate', 'structure', '--allow-dirs=agents'"
        $script:Validator | Should -Match "'check', '--strict', '--allow-dirs=agents'"
        $script:Validator | Should -Match 'Triggered SkillSpector semantic scan did not complete'
        $script:Validator | Should -Match '\[switch\] \$EnableSemanticScan'
        $script:Validator | Should -Match '\$semanticTriggered = \[bool\]\$EnableSemanticScan -and'
        $script:Validator | Should -Match 'repository-validation-post-pester'
        $script:Validator | Should -Match 'pesterRunnerPath'
        $script:Validator | Should -Match 'supervisor-owned completion result'
        $script:Validator | Should -Match 'StandardInput \$pesterResultMarker'
        $script:Validator | Should -Match 'IsolateRunnerCommandFiles'
        $script:Validator | Should -Match 'GITHUB_ENV'
        $script:Validator | Should -Match 'GITHUB_PATH'
        $script:Validator | Should -Match 'bridgeCompletionMarker'
        $script:Validator | Should -Match 'protected completion marker'
        $script:Validator | Should -Match 'CompletionMarker'
        $script:Validator | Should -Match 'CompletionMarkerFromInput'
        $script:Validator | Should -Match 'trustedBridgeHashes'
        $script:Validator | Should -Match 'Assert-ReceiptInstalledClosure'
        $script:Validator | Should -Match 'installedClosureSha256'
        $script:Validator | Should -Match 'installed closure contains a reparse-backed entry'
        $script:Validator | Should -Match 'Get-ChildItem -LiteralPath \$root -Recurse -Force'
        $script:Validator | Should -Match 'GIT_CONFIG_NOSYSTEM'
        $script:Validator | Should -Match 'core\.hooksPath'
        $script:Validator | Should -Not -Match ([regex]::Escape("'-OutputPath', `$pesterResultPath"))
        $script:Validator | Should -Match 'postPesterCandidateCommit'
        $script:Validator | Should -Match 'postPesterTree'
        $script:Validator | Should -Match 'prePesterGitIndexSha256'
        $script:Validator | Should -Match 'Get-RepositoryRawSnapshot'
        $script:Validator | Should -Match 'Assert-RepositoryRawSnapshotUnchanged'
        $script:Validator | Should -Match 'postPesterRepositoryRawSnapshot'
        $script:Validator | Should -Match '\$repositoryValidatorPath'
        $script:Validator | Should -Match '\$repositoryValidatorBytes'
        $script:Validator | Should -Match 'postPesterRepositoryValidatorScript'
        $script:Validator | Should -Match 'pesterRunnerSha256'
        $script:Validator | Should -Match 'Candidate whitespace validation'
        $script:Validator | Should -Match 'Pester installed closure before candidate tests'
        $script:Validator | Should -Match 'Assert-NoGitReplacementObjects'
        $script:Validator | Should -Match 'GIT_NO_REPLACE_OBJECTS'
        $script:Validator | Should -Match 'Assert-RegularFileForHash'
        $script:Validator | Should -Match 'InterT30_runs all offline API credential and access-path checks'
        $script:Validator | Should -Match 'requiredPesterTests'
        $script:Validator | Should -Match 'requiredTests'
        $script:Validator | Should -Match 'Invoke-NativeChecked -Command \$powerShellPath'
        $script:Validator | Should -Match '\$bridgeScriptPaths = @\('
        $script:Validator | Should -Match 'Direct bridge validation for'
        $script:Validator | Should -Match 'Candidate Pester test names are supplemental coverage'
        $script:Validator | Should -Match 'function Stop-ProcessTree'
        $script:Validator | Should -Match 'function Get-UnixProcessGroupId'
        $script:Validator | Should -Match 'function Get-UnixProcessGroupProcessIds'
        $script:Validator | Should -Match 'function Add-ObservedProcessIds'
        $script:Validator | Should -Match 'function Get-ProcessIdentity'
        $script:Validator | Should -Match 'function Test-ProcessIdentity'
        $script:Validator | Should -Match 'function Stop-UnixProcessByIdentity'
        $script:Validator | Should -Match 'OpenProcessFileDescriptor'
        $script:Validator | Should -Match 'SendProcessSignal'
        $script:Validator | Should -Match 'function Get-WindowsProcessBoundaryType'
        $script:Validator | Should -Match 'CreateKillOnCloseJob'
        $script:Validator | Should -Match 'AssignProcess'
        $script:Validator | Should -Match 'TerminateProcessHandle'
        $script:Validator | Should -Match 'WindowsJobHandle'
        $script:Validator | Should -Match 'TimeoutMilliseconds'
        $script:Validator | Should -Match 'bounded candidate execution timeout'
        $script:Validator | Should -Match 'EventWaitHandle'
        $script:Validator | Should -Match 'CODEX_VALIDATION_RESUME_EVENT'
        $script:Validator | Should -Match 'CreateSuspended'
        $script:Validator | Should -Match 'StartupInfoEx'
        $script:Validator | Should -Match 'ProcThreadAttributeHandleList'
        $script:Validator | Should -Match 'InitializeProcThreadAttributeList'
        $script:Validator | Should -Match 'UpdateProcThreadAttribute'
        $script:Validator | Should -Match 'CreateExtendedStartupInfo'
        $script:Validator | Should -Match '\.Resume\(\)'
        $script:Validator | Should -Match 'ReadBoundedAsync'
        $script:Validator | Should -Match 'bounded native-process output limit'
        $script:Validator | Should -Match 'unassigned suspended Windows process safely'
        $windowsAssignmentIndex = $script:Validator.IndexOf('Assign-WindowsProcessToJob -JobHandle $windowsJobHandle')
        $windowsReleaseIndex = $script:Validator.IndexOf('$windowsResumeEvent.Set()')
        $windowsAssignmentIndex | Should -BeGreaterThan -1
        $windowsReleaseIndex | Should -BeGreaterThan $windowsAssignmentIndex
        $script:Validator | Should -Not -Match 'taskkill'
        $script:Validator | Should -Not -Match '\$killPath'
        $script:Validator | Should -Match 'function Enable-UnixChildSubreaper'
        $script:Validator | Should -Match 'function Wait-ForUnixProcessGroupId'
        $script:Validator | Should -Match 'ObservedProcessIdentities'
        $script:Validator | Should -Match 'ProcessGroupId'
        $script:Validator | Should -Match 'setsid'
        $script:Validator | Should -Match 'unshare'
        $script:Validator | Should -Match '--kill-child'
        $script:Validator | Should -Match 'maskHostSocketsScript'
        $script:Validator | Should -Match '--make-rprivate'
        $script:Validator | Should -Match 'find_path'
        $script:Validator | Should -Match 'private_root'
        $script:Validator | Should -Match 'ApplyLinuxResourceLimits'
        $script:Validator | Should -Match '--nproc=256'
        $script:Validator | Should -Match 'function New-ContainedProcessEnvironment'
        $script:Validator | Should -Match 'function Protect-ProcessCredentialEnvironment'
        $script:Validator | Should -Match 'SemanticCredentialNames'
        $script:Validator | Should -Match 'AdditionalEnvironmentVariables'
        $script:Validator | Should -Match 'EnvironmentVariables\.Clear\(\)'
        $script:Validator | Should -Match 'ACTIONS_RUNTIME_TOKEN'
        $script:Validator | Should -Match 'WaitForExit\(100\)'
        $observedProcessIndex = $script:Validator.IndexOf('Add-ObservedProcessIds -RootProcessId')
        $timedWaitIndex = $script:Validator.IndexOf('WaitForExit(100)')
        $observedProcessIndex | Should -BeGreaterThan -1
        $timedWaitIndex | Should -BeGreaterThan $observedProcessIndex
        $script:Validator | Should -Match 'function Get-RunnerCommandFileSnapshot'
        $script:Validator | Should -Match 'function Assert-RunnerCommandFilesUnchanged'
        $script:Validator | Should -Match 'TerminateProcessTree'
        $script:Validator | Should -Match 'ProtectRunnerCommandFiles'
        $script:Validator | Should -Match "'-NoProfile'"
        $script:Validator | Should -Match "'route'"
        $script:Validator | Should -Match 'skill-tools route did not return exactly one result'
        $script:Validator | Should -Match '\$routeResults = @\(Read-JsonFile'
        $script:Validator | Should -Not -Match '\$routeResults -isnot \[array\]'
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml') -Raw
        $workflow | Should -Match 'github\.run_attempt'
        $workflow | Should -Match 'github\.event\.pull_request\.head\.sha'
        $workflow | Should -Match 'pull_request_target:'
        $workflow | Should -Match 'ref: \$\{\{ github\.event_name == .pull_request_target. && github\.event\.pull_request\.head\.sha \|\| github\.sha \}\}'
        $workflow | Should -Match 'Materialize protected validation supervisor'
        $workflow | Should -Match 'Materialize protected Windows compatibility contract'
        $workflow | Should -Match 'TRUSTED_WINDOWS_CONTRACT'
        $workflow | Should -Match 'validate-windows-powershell\.ps1'
        $workflow | Should -Match 'TRUSTED_SUPERVISOR_COMMIT: \$\{\{ github\.sha \}\}'
        $workflow | Should -Match 'publish-head-required-checks'
        $workflow | Should -Match 'HEAD_SHA'
        $workflow | Should -Match 'GitHub Copilot Agent Skills'
        $workflow | Should -Match 'STANDARD_V1_BOOTSTRAP_SKIP'
        $workflow | Should -Match 'bootstrap_skip'
        $workflow | Should -Match 'CANONICAL_BOOTSTRAP_SKIP'
        $workflow | Should -Match 'Assert-NoDuplicateJsonProperties'
        $workflow | Should -Match 'TryGetInt64'
        $workflow | Should -Match 'Parse candidate PowerShell trust-anchor files'
        $workflow | Should -Match 'PUBLICATION_RESULT'
        $workflow | Should -Match 'github-copilot-agent-skills'
        $workflow | Should -Match 'candidate-integrity\.json'
        $workflow | Should -Match 'receipt-\*\.json'
        $workflow | Should -Not -Match '(?m)^\s*\$\{\{ runner\.temp \}\}/sgv1-\*\s*$'
        $workflow | Should -Not -Match "github\.event_name == 'pull_request'"
        $workflow | Should -Not -Match 'TRUSTED_VALIDATE_BLOB|TRUSTED_REPOSITORY_VALIDATOR_BLOB'
        $workflow | Should -Match '\$actualBlob = .*rev-parse \$revision'
        $workflow | Should -Match 'TRUSTED_SUPERVISOR_ROOT'
        $workflow | Should -Match '\$trustedValidator = Join-Path \$env:TRUSTED_SUPERVISOR_ROOT'
        $workflow | Should -Not -Match '(?m)^\s*& \.\/scripts\/Validate\.ps1'
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml') | Should -BeFalse
        $repositoryValidator = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1') -Raw
        $repositoryValidator | Should -Match 'rawSha256'
        $repositoryValidator | Should -Match 'expectedPublisherSkillPaths'
        $repositoryValidator | Should -Match 'function Assert-WindowsPortableRelativePath'
        $repositoryValidator | Should -Match 'Windows-reserved device name'
        $repositoryValidator | Should -Match 'Publisher-discoverable Skill inventory'
        $repositoryValidator | Should -Match '\[switch\] \$NoFilters'
        $repositoryValidator | Should -Match 'NoFilters:\$NoFilters'
        foreach ($bridgeName in @('validate-repository.ps1', 'validate-repository-standalone.ps1', 'validate-api-access.ps1')) {
            $bridge = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot "tests/$bridgeName") -Raw
            $bridge | Should -Match 'Set-Variable -Name CompletionMarker -Value \$CompletionMarker -Scope Script -Option Private'
        }
    }

    It 'keeps the required CI gate free of implicit LLM credentials' {
        # Scenario: GitHub Actions invokes the canonical validator without a
        # provider secret. Purpose: Prevent missing optional LLM credentials
        # from turning deterministic repository validation into a CI failure.
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml') -Raw
        $workflow | Should -Not -Match 'EnableSemanticScan'
        $script:Validator | Should -Match 'credential-free and deterministic'
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
