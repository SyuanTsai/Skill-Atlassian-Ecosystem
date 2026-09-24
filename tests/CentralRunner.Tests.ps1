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

    It 'binds the central runner to the exact a403 authority file' {
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
        $script:Workflow | Should -Match "evidence\.state -cne 'PASS'"
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
}
