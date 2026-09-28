# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RemoteName,
    [Parameter(Mandatory = $true)][string]$RemoteUrl,
    [string]$RepositoryRoot,
    [string]$TrustedEntryRoot,
    [string]$TrustedSourceRevision
)

$ErrorActionPreference = 'Stop'
$artifacts = $null
$output = $null
$enteredRoot = $false
try {
    $root = (Resolve-Path -LiteralPath $(if ($RepositoryRoot) { $RepositoryRoot } else { Join-Path $PSScriptRoot '..' })).Path
    if ($RemoteName -cne 'origin') { throw 'Unsupported remote identifier.' }
    $configured = @(& git -C $root remote get-url --push --all origin 2>$null | ForEach-Object { ([string]$_).Trim() })
    if ($LASTEXITCODE -ne 0 -or $configured.Count -eq 0 -or $configured -cnotcontains $RemoteUrl) {
        throw 'Remote URL differs from configured origin push destinations.'
    }
    $records = @([Console]::In.ReadToEnd() -split '\r?\n' | Where-Object { $_ -ne '' })
    if ($records.Count -eq 0) { Write-Output 'Pre-push has no pending ref updates.'; exit 0 }
    if ($records.Count -ne 1) { throw 'Expected exactly one pre-push ref update.' }
    if ($records[0] -cnotmatch '^(?<localRef>\S+) (?<localSha>[0-9a-f]{40}) (?<remoteRef>\S+) (?<remoteSha>[0-9a-f]{40})$') {
        throw 'Unsupported pre-push ref update shape.'
    }
    $localRef = [string]$Matches.localRef
    $remoteRef = [string]$Matches.remoteRef
    $candidate = [string]$Matches.localSha
    $remoteSha = [string]$Matches.remoteSha
    if ($localRef -ceq 'HEAD') {
        $localRef = ([string](& git -C $root symbolic-ref --quiet HEAD 2>$null)).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'A symbolic current branch is required for a HEAD push.' }
    }
    if (-not $localRef.StartsWith('refs/heads/', [StringComparison]::Ordinal) -or $remoteRef -cne $localRef) {
        throw 'Only matching branch refs are supported by source-only pre-push validation.'
    }
    $head = ([string](& git -C $root rev-parse HEAD)).Trim()
    if ($LASTEXITCODE -ne 0 -or $head -cnotmatch '^[0-9a-f]{40}$') { throw 'Could not resolve exact HEAD.' }
    if ($candidate -cne $head) { throw "Pushed candidate $candidate does not match HEAD $head." }
    $dirty = @(& git -C $root status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect candidate worktree.' }
    if ($dirty.Count -gt 0) { throw 'Pre-push candidate worktree is dirty.' }
    if ($remoteSha -ceq ('0' * 40)) {
        $remoteMainRecord = @(& git -C $root ls-remote --exit-code --heads $RemoteUrl refs/heads/main 2>$null)
        if ($LASTEXITCODE -ne 0 -or $remoteMainRecord.Count -ne 1 -or
            [string]$remoteMainRecord[0] -cnotmatch '^(?<tip>[0-9a-f]{40})\s+refs/heads/main$') {
            throw 'Authenticated remote main tip is unavailable.'
        }
        $remoteMain = [string]$Matches.tip
        & git -C $root cat-file -e "${remoteMain}^{commit}" 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Authenticated remote main commit is unavailable locally.' }
        $bases = @(& git -C $root merge-base --all $candidate $remoteMain 2>$null)
        if ($LASTEXITCODE -ne 0 -or $bases.Count -ne 1 -or [string]$bases[0] -cnotmatch '^[0-9a-f]{40}$') {
            throw 'New branch has no unique authenticated remote main merge base.'
        }
        $base = ([string]$bases[0]).Trim()
        if ($candidate -ceq $remoteMain) {
            Write-Output 'Pre-push publishes a new branch at the authenticated remote main commit; no new source content.'
            exit 0
        }
    }
    else {
        $base = $remoteSha
        & git -C $root cat-file -e "${base}^{commit}" 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Remote base commit is unavailable locally.' }
        & git -C $root merge-base --is-ancestor $base HEAD
        if ($LASTEXITCODE -ne 0) { throw 'Remote base is not an ancestor of pushed HEAD.' }
    }
    if ($base -ceq $head) { throw 'Comparison base equals pushed HEAD.' }
    # Five entry hashes do not cover candidate scripts/tests. Only the complete reviewed commit may execute them.
    # Ref-only early returns above run exclusively in the verified trusted helper and never execute candidate code.
    if ($TrustedEntryRoot -or $TrustedSourceRevision) {
        if ($TrustedSourceRevision -cnotmatch '^[0-9a-f]{40}$' -or $head -cne $TrustedSourceRevision) {
            throw 'Candidate revision is outside the complete reviewed snapshot; no candidate code was executed.'
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $root 'scripts/Validate.ps1') -PathType Leaf)) { throw 'Canonical validator is missing.' }
    $goVersion = ([string](& go version)).Trim()
    if ($LASTEXITCODE -ne 0 -or $goVersion -cnotmatch '^go version go(?<version>[0-9]+\.[0-9]+\.[0-9]+) [^\s]+/[^\s]+$') {
        throw 'Local Go runtime identity is unavailable or malformed.'
    }
    $expectedGo = [string]$Matches.version
    $artifacts = Join-Path ([IO.Path]::GetTempPath()) ('atlassian-prepush-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($artifacts)
    $output = Join-Path $artifacts 'source-conformance-report.json'
    Push-Location -LiteralPath $(if ($TrustedEntryRoot) { $TrustedEntryRoot } else { $root })
    $enteredRoot = $true
    $env:GITHUB_EVENT_NAME = 'pre-push'
    & ./scripts/Validate.ps1 -SourceConformance -RepositoryRoot $root -ArtifactsRoot $artifacts -BaseCommit $base -ExpectedGoRuntimeVersion $expectedGo -OutputPath $output
    $canonicalExit = $LASTEXITCODE
    if (-not (Test-Path -LiteralPath $output -PathType Leaf)) { throw 'Canonical source report is missing.' }
    if (((Get-Item -LiteralPath $output -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Canonical source report must not be reparse-backed.'
    }
    try { $report = Get-Content -LiteralPath $output -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100 }
    catch { throw 'Canonical source report is not valid JSON.' }
    $source = $report.sourceConformance
    $canonical = $source.canonicalValidation
    $status = 'failed'
    if ($report.schemaVersion -eq 1 -and
        $report.evidence -ceq 'standard-validation-evidence-v1' -and
        $report.contract -ceq 'standard-validation-contract-v1' -and
        $report.candidate.sourceRevision -ceq $candidate -and
        $source.schemaVersion -eq 1 -and
        $source.contract -ceq 'standard-source-conformance-v1' -and
        $source.scope -ceq 'source-stages-1-5' -and
        $source.status -ceq 'passed' -and
        $source.sourceRevision -ceq $candidate -and
        $source.candidateId -ceq $report.candidate.candidateId -and
        $source.contentSha256 -ceq $report.candidate.contentSha256 -and
        $source.releaseEligible -eq $false -and
        $report.releaseEligible -eq $false -and
        @($source.failureReasons).Count -eq 0 -and
        $canonicalExit -eq $report.exitCode -and
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
    if ($status -cne 'passed') {
        throw "Canonical source conformance did not pass for $candidate."
    }
    Write-Output "Pre-push source conformance passed for $candidate. Run artifacts will be reclaimed."
    exit 0
}
catch {
    $blockedMessage = $_.Exception.Message
    if ($artifacts -and $output -and (Test-Path -LiteralPath $output -PathType Leaf)) {
        try {
            $reportFile = Get-Item -LiteralPath $output -Force
            if (($reportFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and $reportFile.Length -le 1048576) {
                $runId = [IO.Path]::GetFileName($artifacts).Substring('atlassian-prepush-'.Length)
                $retained = Join-Path ([IO.Path]::GetTempPath()) "atlassian-prepush-report-$runId.json"
                [IO.File]::Copy($output, $retained, $false)
                Write-Warning "Bounded local failure report retained: $retained"
            }
            else { Write-Warning 'No bounded local report snapshot is available.' }
        }
        catch { Write-Warning 'Could not retain the bounded local failure report.' }
    }
    Write-Error "Pre-push blocked: $blockedMessage"
    exit 1
}
finally {
    if ($enteredRoot) { Pop-Location }
    if ($artifacts -and (Test-Path -LiteralPath $artifacts)) {
        $full = [IO.Path]::GetFullPath($artifacts).TrimEnd([char[]]@('\','/'))
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]@('\','/'))
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if (-not [IO.Path]::GetDirectoryName($full).Equals($tempRoot, $comparison) -or
            [IO.Path]::GetFileName($full) -cnotmatch '^atlassian-prepush-[0-9a-f]{32}$') {
            throw 'Refusing unsafe per-push artifact cleanup.'
        }
        $items = @((Get-Item -LiteralPath $full -Force)) + @(Get-ChildItem -LiteralPath $full -Recurse -Force)
        if (@($items | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -gt 0) {
            throw 'Refusing reparse-backed per-push artifact cleanup.'
        }
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    }
}
