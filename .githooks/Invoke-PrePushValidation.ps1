# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RemoteName,
    [Parameter(Mandatory = $true)][string]$RemoteUrl
)

$ErrorActionPreference = 'Stop'
try {
    $root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    if ($RemoteName -cne 'origin') { throw "Unsupported remote '$RemoteName'." }
    $configured = ([string](& git -C $root remote get-url origin)).Trim()
    if ($LASTEXITCODE -ne 0 -or $configured -cne $RemoteUrl) { throw 'Remote URL differs from configured origin.' }
    $records = @([Console]::In.ReadToEnd() -split '\r?\n' | Where-Object { $_ -ne '' })
    if ($records.Count -ne 1) { throw 'Expected exactly one pre-push ref update.' }
    if ($records[0] -cnotmatch '^(?<localRef>\S+) (?<localSha>[0-9a-f]{40}) (?<remoteRef>\S+) (?<remoteSha>[0-9a-f]{40})$') {
        throw 'Unsupported pre-push ref update shape.'
    }
    $localRef = [string]$Matches.localRef
    $remoteRef = [string]$Matches.remoteRef
    if (-not $localRef.StartsWith('refs/heads/', [StringComparison]::Ordinal) -or $remoteRef -cne $localRef) {
        throw 'Only matching branch refs are supported by source-only pre-push validation.'
    }
    $candidate = [string]$Matches.localSha
    $remoteSha = [string]$Matches.remoteSha
    $head = ([string](& git -C $root rev-parse HEAD)).Trim()
    if ($LASTEXITCODE -ne 0 -or $head -cnotmatch '^[0-9a-f]{40}$') { throw 'Could not resolve exact HEAD.' }
    if ($candidate -cne $head) { throw "Pushed candidate $candidate does not match HEAD $head." }
    $dirty = @(& git -C $root status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect candidate worktree.' }
    if ($dirty.Count -gt 0) { throw 'Pre-push candidate worktree is dirty.' }
    if ($remoteSha -ceq ('0' * 40)) {
        $base = ([string](& git -C $root merge-base HEAD refs/remotes/origin/main)).Trim()
        if ($LASTEXITCODE -ne 0 -or $base -cnotmatch '^[0-9a-f]{40}$') { throw 'New branch has no unique local origin/main merge base.' }
    }
    else {
        $base = $remoteSha
        & git -C $root cat-file -e "${base}^{commit}" 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Remote base commit is unavailable locally.' }
        & git -C $root merge-base --is-ancestor $base HEAD
        if ($LASTEXITCODE -ne 0) { throw 'Remote base is not an ancestor of pushed HEAD.' }
    }
    if ($base -ceq $head) { throw 'Comparison base equals pushed HEAD.' }
    $validator = Join-Path $root 'scripts/Validate.ps1'
    if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) { throw 'Canonical validator is missing.' }
    $goVersion = ([string](& go version)).Trim()
    if ($LASTEXITCODE -ne 0 -or $goVersion -cnotmatch '^go version go(?<version>[0-9]+\.[0-9]+\.[0-9]+) [^\s]+/[^\s]+$') {
        throw 'Local Go runtime identity is unavailable or malformed.'
    }
    $expectedGo = [string]$Matches.version
    $artifacts = Join-Path ([IO.Path]::GetTempPath()) ('atlassian-prepush-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($artifacts)
    $output = Join-Path $artifacts 'source-conformance-report.json'
    & $validator -SourceConformance -ArtifactsRoot $artifacts -BaseCommit $base -ExpectedGoRuntimeVersion $expectedGo -OutputPath $output
    $canonicalExit = $LASTEXITCODE
    if (-not (Test-Path -LiteralPath $output -PathType Leaf)) { throw 'Canonical source report is missing.' }
    $projection = Join-Path $root 'scripts/Test-SourceConformanceProjection.ps1'
    if (-not (Test-Path -LiteralPath $projection -PathType Leaf)) { throw 'Source conformance projection is missing.' }
    $status = & $projection -ReportPath $output -ExpectedSourceRevision $candidate -CanonicalExitCode $canonicalExit
    if ($status -cne 'passed') {
        throw "Canonical source conformance did not pass for $candidate. Report: $output"
    }
    Write-Output "Pre-push source conformance passed for $candidate. Report: $output"
    exit 0
}
catch {
    Write-Error "Pre-push blocked: $($_.Exception.Message)"
    exit 1
}
