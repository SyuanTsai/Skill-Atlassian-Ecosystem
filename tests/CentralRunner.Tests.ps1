# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Central Standard v1 authority runner wiring' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:Config = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'config/standard-v1.json') -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 20
        $script:Workflow = (Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml') -Raw -Encoding UTF8) -replace "`r`n", "`n"
        $script:SourceEntry = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1') -Raw -Encoding UTF8
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

    It 'keeps production metadata separate from the unprivileged source adapter' {
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
        $script:SourceEntry | Should -Match "mode = 'development-harness'"
        $script:SourceEntry | Should -Match "'-DevelopmentHarness'"
        $script:Workflow | Should -Match 'pull_request:'
        $script:Workflow | Should -Not -Match 'pull_request_target:|STANDARD_V1_SUPERVISOR_LAUNCH_BINDING_PATH|checks:\s*write'
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

    It 'accepts only a complete candidate-bound source projection' {
        $start = $script:Workflow.IndexOf('      - name: Route source conformance from canonical evidence', [StringComparison]::Ordinal)
        $end = $script:Workflow.IndexOf('      - name: Require source conformance', [StringComparison]::Ordinal)
        $start | Should -BeGreaterOrEqual 0
        $end | Should -BeGreaterThan $start
        $step = $script:Workflow.Substring($start, $end - $start)
        $run = $step.IndexOf("        run: |`n", [StringComparison]::Ordinal)
        $run | Should -BeGreaterOrEqual 0
        $body = ($step.Substring($run + 15) -split '\r?\n' | ForEach-Object {
            if ($_.StartsWith('          ', [StringComparison]::Ordinal)) { $_.Substring(10) } else { $_ }
        }) -join [Environment]::NewLine
        $routePath = Join-Path $TestDrive 'source-route.ps1'
        [IO.File]::WriteAllText($routePath, $body, [Text.UTF8Encoding]::new($false))
        $candidateSha = 'a' * 40
        $candidateId = 'b' * 64
        $contentSha = 'c' * 64
        $fixture = [pscustomobject][ordered]@{
            schemaVersion = 1
            evidence = 'standard-validation-evidence-v1'
            contract = 'standard-validation-contract-v1'
            state = 'BLOCKED'
            exitCode = 10
            releaseEligible = $false
            candidate = [pscustomobject]@{ sourceRevision = $candidateSha; candidateId = $candidateId; contentSha256 = $contentSha }
            stages = @(0..9 | ForEach-Object {
                [pscustomobject]@{ status = if ($_ -lt 5) { 'passed' } elseif ($_ -eq 5) { 'blocked' } else { 'not-run' }; events = @() }
            })
            sourceConformance = [pscustomobject][ordered]@{
                schemaVersion = 1
                contract = 'standard-source-conformance-v1'
                scope = 'source-stages-1-5'
                status = 'passed'
                sourceRevision = $candidateSha
                candidateId = $candidateId
                contentSha256 = $contentSha
                checkedStages = @(1..5)
                pester = [pscustomobject]@{ eventCount = 1; testInventoryCount = 1; total = 1; passed = 1; failed = 0 }
                canonicalValidation = [pscustomobject]@{ state = 'BLOCKED'; exitCode = 10; stage6Status = 'blocked'; releaseEligible = $false }
                releaseEligible = $false
                failureReasons = @()
            }
        }
        $pwshPath = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
        function Test-SourceCase {
            param($Evidence, [string]$Name, [string]$ExpectedStatus, [int]$ExitCode = 10, [switch]$MissingReport)
            $caseRoot = Join-Path $TestDrive $Name
            [void](New-Item -ItemType Directory -Path $caseRoot -Force)
            if (-not $MissingReport) {
                [IO.File]::WriteAllText((Join-Path $caseRoot 'atlassian-source-conformance-report.json'),
                    ($Evidence | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
            }
            [IO.File]::WriteAllText((Join-Path $caseRoot 'atlassian-central-exit.txt'), [string]$ExitCode)
            $outputPath = Join-Path $caseRoot 'github-output.txt'
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $pwshPath
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $routePath)) { [void]$startInfo.ArgumentList.Add($argument) }
            $startInfo.Environment['RUNNER_TEMP'] = $caseRoot
            $startInfo.Environment['GITHUB_OUTPUT'] = $outputPath
            $startInfo.Environment['GITHUB_SHA'] = $candidateSha
            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            [void]$process.Start()
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            $process.ExitCode | Should -Be 0 -Because "$Name stdout=$stdout stderr=$stderr"
            (Get-Content -LiteralPath $outputPath -Raw) | Should -Match "status=$ExpectedStatus"
        }
        Test-SourceCase -Evidence $fixture -Name 'source-pass-canonical-blocked' -ExpectedStatus 'passed'
        $wrongHead = $fixture | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
        $wrongHead.sourceConformance.sourceRevision = 'd' * 40
        Test-SourceCase -Evidence $wrongHead -Name 'wrong-head' -ExpectedStatus 'failed'
        Test-SourceCase -Evidence $fixture -Name 'missing-report' -ExpectedStatus 'failed' -MissingReport
        $failedStage = $fixture | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
        $failedStage.stages[3].status = 'failed'
        Test-SourceCase -Evidence $failedStage -Name 'failed-stage' -ExpectedStatus 'failed'
        $zeroPester = $fixture | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
        $zeroPester.sourceConformance.pester.total = 0
        Test-SourceCase -Evidence $zeroPester -Name 'zero-pester' -ExpectedStatus 'failed'
        $releasePromotion = $fixture | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
        $releasePromotion.releaseEligible = $true
        Test-SourceCase -Evidence $releasePromotion -Name 'release-promotion' -ExpectedStatus 'failed'
        Test-SourceCase -Evidence $fixture -Name 'exit-mismatch' -ExpectedStatus 'failed' -ExitCode 20
    }
}
