# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Source conformance Static bridge' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $source = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceConformance.ps1') -Raw
        $start = $source.IndexOf(('$childRunnerText = @' + [char]39), [StringComparison]::Ordinal)
        if ($start -lt 0) { throw 'The source validation child was not found.' }
        $start = $source.IndexOf("`n", $start) + 1
        $end = $source.IndexOf(("`n" + [char]39 + '@'), $start, [StringComparison]::Ordinal)
        if ($end -lt $start) { throw 'The source validation child terminator was not found.' }
        $script:ChildSource = $source.Substring($start, $end - $start).TrimEnd("`r")
        $script:PowerShellPath = (Get-Process -Id $PID).Path

        function New-StaticBridgeFixture {
            param([Parameter(Mandatory = $true)][string] $Root)
            $candidate = Join-Path $Root 'candidate'
            $skill = Join-Path $candidate 'skills/manage-confluence-docs-as-code'
            $output = Join-Path $Root 'output'
            [void](New-Item -ItemType Directory -Path $skill, $output -Force)
            Set-Content -LiteralPath (Join-Path $skill 'SKILL.md') -Value '# Test skill' -Encoding utf8NoBOM

            $child = Join-Path $Root 'child.ps1'
            $scanner = Join-Path $Root 'scanner.ps1'
            $wrapper = Join-Path $Root 'wrapper.ps1'
            $receipt = Join-Path $Root 'receipt-skillspector.json'
            $toolchain = Join-Path $Root 'toolchain.json'
            [IO.File]::WriteAllText($child, $script:ChildSource, [Text.UTF8Encoding]::new($false))
            Set-Content -LiteralPath $receipt -Value '{}' -Encoding utf8NoBOM
            Set-Content -LiteralPath $scanner -Encoding utf8NoBOM -Value @'
$skillRoot = [string]$args[1]
$reportPath = [string]$args[-1]
$reason = [string]$env:SOURCE_STATIC_TEST_REASON
$limitation = [string]$env:SOURCE_STATIC_TEST_LIMITATION
$report = [ordered]@{
    execution_successful = $true
    skill = [ordered]@{ name = (Split-Path -Leaf $skillRoot); source = $skillRoot }
    analysis_completeness = [ordered]@{
        execution_successful = $true; is_complete = $false; status = 'partial'; coverage_percent = 50
        ledger_exceptions = @([ordered]@{
            path = 'SKILL.md'; phase = 'static'; outcome = 'partial'; reason_code = $reason
            fatal = $false; analyzers = @('static_patterns_tool_misuse')
        })
        scope_exclusions = @(); limitations = @($limitation)
    }
    components = @([ordered]@{ path = 'SKILL.md' })
    issues = @([ordered]@{ id = 'E1'; severity = 'medium'; message = 'Retained finding' })
}
[IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
'@
            Set-Content -LiteralPath $wrapper -Encoding utf8NoBOM -Value @'
param($ToolReceiptPath, $ExpectedToolReceiptSha256, $ExpectedResolutionRunId, $SkillRoot,
    $SourceRevision, $CandidateIdentity, $ReportPath, $EvidencePath)
[IO.File]::WriteAllText($env:SOURCE_STATIC_TEST_WRAPPER_MARKER, 'called', [Text.UTF8Encoding]::new($false))
$sourcePath = Join-Path (Get-Location) ("skillspector-$(Split-Path -Leaf $SkillRoot).json")
$report = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json -Depth 20
$report.analysis_completeness.is_complete = $true
$report.analysis_completeness.status = 'complete'
$report.analysis_completeness.coverage_percent = 100
$report.analysis_completeness.ledger_exceptions = @()
$report.analysis_completeness.limitations = @()
[IO.File]::WriteAllText($ReportPath, ($report | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
foreach ($sidecar in @($EvidencePath, "$EvidencePath.profile.json", "$ReportPath.original.json")) {
    [IO.File]::WriteAllText($sidecar, '{}', [Text.UTF8Encoding]::new($false))
}
[pscustomobject]@{
    status = 'completed'; reportPath = $ReportPath; evidencePath = $EvidencePath
    applicabilityStatus = 'not-verified'; executionProvenanceStatus = 'not-verified'
    authorizationGranted = $false; authorizedOperations = @(); releaseEligible = $false
} | ConvertTo-Json -Compress
'@
            $toolchainValue = [ordered]@{
                skillSpectorPath = $scanner
                skillSpectorSha256 = (Get-FileHash -LiteralPath $scanner -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            [IO.File]::WriteAllText($toolchain, ($toolchainValue | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            [pscustomobject]@{
                candidate = $candidate; skill = $skill; output = $output; child = $child
                wrapper = $wrapper; receipt = $receipt; toolchain = $toolchain
                marker = (Join-Path $Root 'wrapper-called.txt')
            }
        }

        function Invoke-StaticBridgeFixture {
            param([Parameter(Mandatory = $true)] $Fixture, [Parameter(Mandatory = $true)][string] $Reason,
                [string] $Limitation = 'Analyzer static_patterns_tool_misuse status: degraded.')
            $previous = @{}
            foreach ($name in @('STANDARD_VALIDATION_CANDIDATE_ROOT', 'STANDARD_VALIDATION_CANDIDATE_ID',
                    'STANDARD_VALIDATION_ACTIVE_SKILLS', 'STANDARD_VALIDATION_SKILLS_ROOT',
                    'SOURCE_STATIC_TEST_REASON', 'SOURCE_STATIC_TEST_LIMITATION', 'SOURCE_STATIC_TEST_WRAPPER_MARKER')) {
                $previous[$name] = [Environment]::GetEnvironmentVariable($name)
            }
            try {
                $env:STANDARD_VALIDATION_CANDIDATE_ROOT = $Fixture.candidate
                $env:STANDARD_VALIDATION_CANDIDATE_ID = 'b' * 64
                $env:STANDARD_VALIDATION_ACTIVE_SKILLS = 'manage-confluence-docs-as-code'
                $env:STANDARD_VALIDATION_SKILLS_ROOT = Join-Path $Fixture.candidate 'skills'
                $env:SOURCE_STATIC_TEST_REASON = $Reason
                $env:SOURCE_STATIC_TEST_LIMITATION = $Limitation
                $env:SOURCE_STATIC_TEST_WRAPPER_MARKER = $Fixture.marker
                Push-Location $Fixture.output
                try {
                    $lines = @(& $script:PowerShellPath -NoProfile -NonInteractive -File $Fixture.child `
                        -Mode static `
                        -ToolchainPath $Fixture.toolchain `
                        -ToolchainSha256 ((Get-FileHash -LiteralPath $Fixture.toolchain -Algorithm SHA256).Hash.ToLowerInvariant()) `
                        -SourceRevision ('a' * 40) `
                        -StaticWrapperPath $Fixture.wrapper `
                        -StaticWrapperSha256 ((Get-FileHash -LiteralPath $Fixture.wrapper -Algorithm SHA256).Hash.ToLowerInvariant()) `
                        -StaticReceiptPath $Fixture.receipt `
                        -StaticReceiptSha256 ((Get-FileHash -LiteralPath $Fixture.receipt -Algorithm SHA256).Hash.ToLowerInvariant()) `
                        -StaticResolutionRunId ('c' * 32) 2>&1)
                    [pscustomobject]@{ exitCode = $LASTEXITCODE; output = ($lines -join "`n") }
                }
                finally { Pop-Location }
            }
            finally {
                foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
            }
        }
    }

    # Scenario: the bound SkillSpector 2.12.0 report is partial only because of the supported PowerShell parser limit.
    # Purpose: Keep the native report while requiring the pinned central wrapper to produce a complete graph with findings intact.
    It 'InterT10_UsesTheCentralWrapperForSupportedStaticParseLimit' {
        $fixture = New-StaticBridgeFixture -Root (Join-Path $TestDrive 'supported')
        $result = Invoke-StaticBridgeFixture -Fixture $fixture -Reason 'static_parse_limit'
        $result.exitCode | Should -Be 0 -Because $result.output
        Test-Path -LiteralPath $fixture.marker | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $fixture.output 'skillspector-manage-confluence-docs-as-code.json') | Should -BeTrue
        $envelope = $result.output | ConvertFrom-Json -Depth 20
        $envelope.status | Should -Be 'passed'
        @($envelope.findings).Count | Should -Be 1
        $envelope.findings[0].severity | Should -Be 'medium'
    }

    # Scenario: the native report is partial for a different reason.
    # Purpose: Prevent a parser correction from laundering unknown incomplete coverage into a passing Stage 4.
    It 'InterT20_RejectsOtherPartialReasonsWithoutCallingTheWrapper' {
        $fixture = New-StaticBridgeFixture -Root (Join-Path $TestDrive 'unsupported')
        $result = Invoke-StaticBridgeFixture -Fixture $fixture -Reason 'reference_missing'
        $result.exitCode | Should -Not -Be 0
        Test-Path -LiteralPath $fixture.marker | Should -BeFalse
        $result.output | Should -Match 'SkillSpector did not prove complete static analysis'
    }

    # Scenario: the native report has the supported exception but an unrelated limitation.
    # Purpose: Do not convert unknown incomplete coverage into a passing Stage 4.
    It 'InterT30_RejectsUnrelatedLimitationWithoutCallingTheWrapper' {
        $fixture = New-StaticBridgeFixture -Root (Join-Path $TestDrive 'unrelated-limitation')
        $result = Invoke-StaticBridgeFixture -Fixture $fixture -Reason 'static_parse_limit' -Limitation 'Unrelated analyzer degraded.'
        $result.exitCode | Should -Not -Be 0
        Test-Path -LiteralPath $fixture.marker | Should -BeFalse
        $result.output | Should -Match 'SkillSpector did not prove complete static analysis'
    }
}
