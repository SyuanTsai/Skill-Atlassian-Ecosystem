# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ReportPath,
    [Parameter(Mandatory = $true)][string]$ExpectedSourceRevision,
    [Parameter(Mandatory = $true)][int]$CanonicalExitCode
)

$ErrorActionPreference = 'Stop'
$status = 'failed'
try {
    if ($ExpectedSourceRevision -cnotmatch '^[0-9a-f]{40}$') { throw 'Expected source revision must be a full immutable commit SHA.' }
    if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) { throw 'Canonical report is missing.' }
    $report = Get-Content -LiteralPath $ReportPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
    $source = $report.sourceConformance
    $canonical = $source.canonicalValidation
    if ($report.schemaVersion -eq 1 -and
        $report.evidence -ceq 'standard-validation-evidence-v1' -and
        $report.contract -ceq 'standard-validation-contract-v1' -and
        $report.candidate.sourceRevision -ceq $ExpectedSourceRevision -and
        $source.schemaVersion -eq 1 -and
        $source.contract -ceq 'standard-source-conformance-v1' -and
        $source.scope -ceq 'source-stages-1-5' -and
        $source.status -ceq 'passed' -and
        $source.sourceRevision -ceq $ExpectedSourceRevision -and
        $source.candidateId -ceq $report.candidate.candidateId -and
        $source.contentSha256 -ceq $report.candidate.contentSha256 -and
        $source.releaseEligible -eq $false -and
        $report.releaseEligible -eq $false -and
        @($source.failureReasons).Count -eq 0 -and
        $CanonicalExitCode -eq $report.exitCode -and
        $canonical.state -ceq $report.state -and
        $canonical.exitCode -eq $report.exitCode -and
        $canonical.releaseEligible -eq $report.releaseEligible -and
        $canonical.stage6Status -ceq $report.stages[5].status -and
        @($report.stages).Count -eq 10 -and
        @($source.checkedStages).Count -eq 5 -and
        @($report.stages[0..4] | Where-Object { $_.status -cne 'passed' }).Count -eq 0 -and
        $source.pester.eventCount -gt 0 -and
        $source.pester.testInventoryCount -gt 0 -and
        $source.pester.total -gt 0 -and
        $source.pester.passed -gt 0 -and
        $source.pester.failed -eq 0 -and
        @($report.stages[0..4] | ForEach-Object { @($_.events | Where-Object { $null -ne $_ }) } | Where-Object { $_.cleanedUp -ne $true }).Count -eq 0) {
        $status = 'passed'
    }
}
catch {
    Write-Warning "Could not project source conformance: $($_.Exception.Message)"
}
Write-Output $status
