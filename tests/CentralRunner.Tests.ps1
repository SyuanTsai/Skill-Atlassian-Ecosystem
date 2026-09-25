# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Central Standard v1 authority runner wiring' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:Config = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'config/standard-v1.json') -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 20
        $script:Workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml') -Raw -Encoding UTF8
        $script:RunnerPath = Join-Path $script:RepositoryRoot $script:Config.centralRunner.runnerPath
        $script:Runner = Get-Content -LiteralPath $script:RunnerPath -Raw -Encoding UTF8
        $script:Contract = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot $script:Config.centralRunner.contractPath) -Raw -Encoding UTF8
    }

    It 'UnitT10_BindsTheCentralRunnerToTheExactApprovedAuthorityFile' {
        # Scenario: The PR54 authority snapshot is materialized for this repository.
        # Purpose: Prevent a stale or altered runner from replacing the approved source.
        (Get-FileHash -Algorithm SHA256 -LiteralPath $script:RunnerPath).Hash.ToLowerInvariant() |
            Should -Be $script:Config.centralRunner.runnerSha256
        $script:Runner | Should -Match '\[ValidateSet\(\x27local\x27, \x27pre-push\x27, \x27pull_request\x27, \x27push\x27, \x27workflow_dispatch\x27\)\]'
        $script:Runner | Should -Match 'Invoke-StandardValidationRun'
        $script:Runner | Should -Match 'SemanticEvidencePath'
        $script:Runner | Should -Match 'releaseEligible = \$false'
    }

    It 'requires a trusted supervisor generated production adapter and evidence handoff' {
        $script:Config.centralRunner.adapterSource | Should -Be 'trusted-supervisor-generated-from-resolver-receipts'
        $script:Config.centralRunner.adapterMode | Should -Be 'production'
        @($script:Config.centralRunner.requiredEvidence) | Should -Be @(
            'launchBinding',
            'signedResolverReceipt',
            'candidateBinding',
            'semanticConsent',
            'semanticProvider',
            'semanticPurpose',
            'semanticScope',
            'semanticAttestation'
        )
        $script:Workflow | Should -Match 'STANDARD_V1_ADAPTER_PATH'
        $script:Workflow | Should -Match 'STANDARD_V1_SUPERVISOR_LAUNCH_BINDING_PATH'
        $script:Workflow | Should -Match 'STANDARD_V1_CANDIDATE_ACQUISITION_EVIDENCE_PATH'
        $script:Workflow | Should -Match 'STANDARD_V1_AUTHORITY_SNAPSHOT_EVIDENCE_PATH'
        $script:Workflow | Should -Match 'BLOCKED\|The trusted supervisor did not provide the production Standard v1 handoff'
        $script:Workflow | Should -Match 'exit 10'
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot 'config/standard-validation-adapter-v1.json') | Should -BeFalse
        $script:Runner | Should -Not -Match '/__standard-v1__/'
    }

    It 'rejects missing semantic consent and candidate bound evidence as BLOCKED' {
        $tokens = $null
        $parseErrors = $null
        $runnerAst = [Management.Automation.Language.Parser]::ParseFile($script:RunnerPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        . $script:RunnerPath `
            -CandidateRoot $TestDrive `
            -AdapterPath (Join-Path $TestDrive 'adapter.json') `
            -ArtifactsRoot $TestDrive `
            -SourceRepository 'https://example.test/repository.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -DefineFunctionsOnly

        $candidateId = 'a' * 64
        $missingConsent = [pscustomobject][ordered]@{
            schemaVersion = 1
            evidenceType = 'semantic'
            candidateId = $candidateId
            status = 'passed'
            decision = 'PASS'
            provider = 'provider'
            purpose = 'purpose'
            scope = 'scope'
            consentGranted = $false
            analyzerIdentity = 'analyzer'
            analyzerCompleteness = 'complete'
            findings = @()
            findingsSha256 = ('0' * 64)
            attestation = [pscustomobject]@{}
        }
        {
            Assert-StandardValidationSemanticEvidence -Evidence $missingConsent -CandidateId $candidateId -TrustAnchorRoot $TestDrive -Context 'semantic fixture'
        } | Should -Throw '*BLOCKED|*'

        $missingEvidence = $script:Runner.Substring($script:Runner.IndexOf("Semantic consent has no candidate-bound evidence file", [StringComparison]::Ordinal) - 300)
        $missingEvidence | Should -Match 'throw \x27BLOCKED\|Semantic consent requires candidate-bound semantic evidence\.\x27'
    }

    It 'keeps installed tool closure bound before and after every candidate child' {
        $beforeCount = ([regex]::Matches($script:Runner, 'candidate acquisition before child')).Count
        $afterCount = ([regex]::Matches($script:Runner, 'candidate acquisition after child')).Count
        $beforeCount | Should -BeGreaterThan 0
        $afterCount | Should -BeGreaterThan 0
        $script:Runner | Should -Match 'Assert-StandardValidationToolReceiptUnchanged'
        $script:Runner | Should -Match 'installed dependency closure does not match its signed resolver identity'
        $script:Contract | Should -Match 'snapshotRevalidation'
    }

    It 'runs only from the protected pull request target and publishes central evidence' {
        $script:Workflow | Should -Match '(?ms)^on:\s*\r?\n\s+pull_request_target:\s*\r?\n\s+branches:\s*\r?\n\s+-\s+main\s*$'
        $script:Workflow | Should -Not -Match '(?m)^\s+push\s*:'
        $script:Workflow | Should -Not -Match '(?m)^\s+workflow_dispatch\s*:'
        $script:Workflow | Should -Match 'Run central Standard v1 authority runner'
        $script:Workflow | Should -Match 'Join-Path \$env:TRUSTED_SUPERVISOR_ROOT.*Invoke-StandardValidation\.ps1'
        $script:Workflow | Should -Not -Match '\$trustedValidator'
        $script:Workflow | Should -Not -Match 'Run canonical Standard v1 validation'
        $script:Workflow | Should -Match 'merge-base \$baseCandidate \$candidateHead'
        $script:Workflow | Should -Match 'BLOCKED\|The trusted event base did not resolve to one distinct immutable merge-base'
        $script:Workflow | Should -Match "validationEventName = 'pull_request'"
        $script:Workflow | Should -Match ([regex]::Escape("'-EventName', `$validationEventName"))
        $script:Workflow | Should -Match 'semanticRequired = @\(\$changedSkillPaths'
        $script:Workflow | Should -Match "runnerArguments \+= '-SemanticTriggered'"
        $script:Workflow | Should -Match "sourceConformance\.status -cne 'passed'"
        $script:Workflow | Should -Match 'sourceConformance\.sourceRevision -cne \$candidateHead'
        $script:Workflow | Should -Match 'centralExitCode -notin @\(0, 10\)'
        $script:Workflow | Should -Not -Match 'if \(\$centralExitCode -ne 0\) \{ exit \$centralExitCode \}'
        $script:Workflow | Should -Match 'evidence\.releaseEligible -ne \$false'
        $script:Workflow | Should -Match 'CENTRAL_STANDARD_V1_EVIDENCE_PATH'
        $script:Workflow | Should -Not -Match 'atlassian-ecosystem-conformance-report\.json'
        $script:Workflow | Should -Match 'standard_v1_evidence_sha256='
    }

    It 'returns BLOCKED exit 10 before candidate head checks when production handoff is absent' {
        $stepMatch = [regex]::Match(
            $script:Workflow,
            '(?ms)- name: Run central Standard v1 authority runner.*?\r?\n\s+- name: Remove delegated Linux cgroup subtree'
        )
        $stepMatch.Success | Should -BeTrue
        $runMatch = [regex]::Match($stepMatch.Value, '(?ms)\r?\n\s+run: \|\r?\n(?<body>(?:\s{10}.*\r?\n)+)\s+- name: Remove delegated Linux cgroup subtree')
        $runMatch.Success | Should -BeTrue
        $centralScript = ($runMatch.Groups['body'].Value -split '\r?\n' | ForEach-Object {
            if ($_.Length -ge 10) { $_.Substring(10) } else { $_ }
        }) -join [Environment]::NewLine
        $scriptPath = Join-Path $TestDrive 'central-run.ps1'
        [IO.File]::WriteAllText($scriptPath, $centralScript, [Text.UTF8Encoding]::new($false))

        $pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $pwsh
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        [void]$startInfo.ArgumentList.Add('-NoLogo')
        [void]$startInfo.ArgumentList.Add('-NoProfile')
        [void]$startInfo.ArgumentList.Add('-NonInteractive')
        [void]$startInfo.ArgumentList.Add('-File')
        [void]$startInfo.ArgumentList.Add($scriptPath)
        foreach ($name in @(
                'STANDARD_V1_ADAPTER_PATH',
                'STANDARD_V1_SUPERVISOR_LAUNCH_BINDING_PATH',
                'STANDARD_V1_CANDIDATE_ARCHIVE_PATH',
                'STANDARD_V1_CANDIDATE_ACQUISITION_EVIDENCE_PATH',
                'STANDARD_V1_AUTHORITY_ARCHIVE_PATH',
                'STANDARD_V1_AUTHORITY_SNAPSHOT_EVIDENCE_PATH')) {
            $startInfo.Environment[$name] = ''
        }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $process.ExitCode | Should -Be 10
        "$stdout`n$stderr" | Should -Match 'BLOCKED\|The trusted supervisor did not provide the production Standard v1 handoff'
        $stdout | Should -Not -Match 'standard_v1_evidence_sha256='
    }

    It 'UnitT50_AcceptsOnlyCandidateBoundSourceConformanceWithoutReleaseAuthority' {
        # Scenario: The trusted runner reports complete source stages but canonical Stage 6 remains BLOCKED.
        # Purpose: Permit source checks while rejecting wrong heads, missing evidence, and release promotion.
        $step = [regex]::Match(
            $script:Workflow,
            '(?ms)- name: Run central Standard v1 authority runner.*?\r?\n\s+- name: Remove delegated Linux cgroup subtree'
        ).Value
        $step | Should -Not -BeNullOrEmpty
        $run = [regex]::Match($step, '(?ms)\r?\n\s+run: \|\r?\n(?<body>(?:\s{10}.*\r?\n)+)\s+- name: Remove delegated Linux cgroup subtree')
        $run.Success | Should -BeTrue
        $body = ($run.Groups['body'].Value -split '\r?\n' | ForEach-Object {
            if ($_.Length -ge 10) { $_.Substring(10) } else { $_ }
        }) -join [Environment]::NewLine
        $marker = 'if ($centralExitCode -notin @(0, 10))'
        $offset = $body.IndexOf($marker, [StringComparison]::Ordinal)
        $offset | Should -BeGreaterOrEqual 0
        $scriptPath = Join-Path $TestDrive 'source-decision.ps1'
        $scriptSource = @'
param([string] $OutputPath, [string] $CandidateHead, [int] $RunnerExitCode)
$ErrorActionPreference = 'Stop'
$outputPath = $OutputPath
$candidateHead = $CandidateHead
$centralExitCode = $RunnerExitCode
'@ + [Environment]::NewLine + $body.Substring($offset)
        [IO.File]::WriteAllText($scriptPath, $scriptSource, [Text.UTF8Encoding]::new($false))

        $candidateHead = 'a' * 40
        $candidateId = 'b' * 64
        $contentSha256 = 'c' * 64
        $fixture = [pscustomobject][ordered]@{
            state = 'BLOCKED'
            exitCode = 10
            releaseEligible = $false
            candidate = [pscustomobject]@{
                sourceRevision = $candidateHead
                candidateId = $candidateId
                contentSha256 = $contentSha256
            }
            sourceConformance = [pscustomobject][ordered]@{
                contract = 'standard-source-conformance-v1'
                status = 'passed'
                scope = 'source-stages-1-5'
                sourceRevision = $candidateHead
                candidateId = $candidateId
                contentSha256 = $contentSha256
                checkedStages = @(1, 2, 3, 4, 5)
                pester = [pscustomobject]@{ passed = 1 }
                releaseEligible = $false
                canonicalValidation = [pscustomobject]@{
                    state = 'BLOCKED'
                    exitCode = 10
                    stage6Status = 'blocked'
                    releaseEligible = $false
                }
            }
        }
        $pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
        function Invoke-SourceDecisionCase {
            param($Evidence, [string] $Name, [int] $ExpectedExitCode, [switch] $MissingReport)
            $evidencePath = Join-Path $TestDrive "$Name.json"
            if (-not $MissingReport) {
                [IO.File]::WriteAllText($evidencePath, ($Evidence | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
            }
            $githubOutput = Join-Path $TestDrive "$Name-output.txt"
            $githubEnvironment = Join-Path $TestDrive "$Name-env.txt"
            [IO.File]::WriteAllText($githubOutput, '')
            [IO.File]::WriteAllText($githubEnvironment, '')
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $pwsh
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $scriptPath,
                    '-OutputPath', $evidencePath, '-CandidateHead', $candidateHead, '-RunnerExitCode', '10')) {
                [void]$startInfo.ArgumentList.Add($argument)
            }
            $startInfo.Environment['GITHUB_OUTPUT'] = $githubOutput
            $startInfo.Environment['GITHUB_ENV'] = $githubEnvironment
            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            [void]$process.Start()
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            $process.ExitCode | Should -Be $ExpectedExitCode -Because "$Name stdout=$stdout stderr=$stderr"
            if ($ExpectedExitCode -eq 0) {
                (Get-Content -Raw $githubOutput) | Should -Match 'standard_v1_evidence_sha256=[0-9a-f]{64}'
            }
            else {
                (Get-Content -Raw $githubOutput) | Should -Not -Match 'standard_v1_evidence_sha256='
            }
        }

        Invoke-SourceDecisionCase -Evidence $fixture -Name 'source-pass-canonical-blocked' -ExpectedExitCode 0
        $wrongRevision = $fixture | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $wrongRevision.sourceConformance.sourceRevision = 'd' * 40
        Invoke-SourceDecisionCase -Evidence $wrongRevision -Name 'wrong-source-revision' -ExpectedExitCode 10
        Invoke-SourceDecisionCase -Evidence $fixture -Name 'missing-report' -ExpectedExitCode 20 -MissingReport
        $failedProjection = $fixture | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $failedProjection.sourceConformance.status = 'failed'
        Invoke-SourceDecisionCase -Evidence $failedProjection -Name 'failed-source-projection' -ExpectedExitCode 10
        $stageMismatch = $fixture | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $stageMismatch.sourceConformance.canonicalValidation.stage6Status = 'passed'
        Invoke-SourceDecisionCase -Evidence $stageMismatch -Name 'stage-six-mismatch' -ExpectedExitCode 10
        $releasePromotion = $fixture | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $releasePromotion.releaseEligible = $true
        Invoke-SourceDecisionCase -Evidence $releasePromotion -Name 'release-promotion' -ExpectedExitCode 10
    }
}
