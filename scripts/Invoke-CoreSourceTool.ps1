# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('package-adapter', 'skill-validator', 'skill-tools', 'static')][string] $Mode,
    [Parameter(Mandatory)][string] $ToolchainPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string] $ToolchainSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'StandardCoreSourcePreparation.psm1') -Force -ErrorAction Stop

function Get-FileSha256 {
    param([Parameter(Mandatory)][string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Test-PathWithin {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Root)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return $fullPath.Equals($fullRoot, $comparison) -or $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, $comparison)
}

function Assert-ReviewedE1BaselineContract {
    param([Parameter(Mandatory)][object] $Document)
    $expectedSkills = @(
        'configure-bitbucket-api-access',
        'configure-confluence-api-access',
        'configure-jira-api-access',
        'publish-requirements-to-confluence',
        'review-bitbucket-pull-request'
    )
    if ($Document.schemaVersion -ne 1 -or [string]$Document.policy -cne 'reviewed-skillspector-e1-exact-baselines' -or
        [string]$Document.scannerSource -cne 'NVIDIA/SkillSpector' -or [string]$Document.scannerVersion -cne '2.12.0' -or
        [string]$Document.scannerSourceCommit -cne 'c7958a3268d9498644b22edb75d0f051bbc8cbfc' -or
        [string]$Document.reviewer -cne 'Independent SYP-304 SOL' -or [string]$Document.reviewFindingId -cne 'F304-SOL-22' -or
        [string]$Document.reviewedSourceRevision -cnotmatch '^[0-9a-f]{40}$' -or
        [string]$Document.authorityRevision -cne 'ff85d5f80fe795b96354e753074b5ce59ad04ecd' -or
        $Document.skills -isnot [array] -or @($Document.skills).Count -ne $expectedSkills.Count) {
        throw 'Reviewed E1 policy metadata or occurrence count is invalid.'
    }
    if ($Document.reviewedOccurrenceCount -ne 17) { throw 'Reviewed occurrence count differs from the pinned review artifact.' }

    $actualSkills = [string[]]@($Document.skills | ForEach-Object { [string]$_.skillId })
    if (($actualSkills -join "`n") -cne ($expectedSkills -join "`n")) { throw 'Reviewed E1 policy Skill inventory is invalid.' }
    $actualCount = 0
    foreach ($skill in $Document.skills) {
        if ($skill.PSObject.Properties.Name -join ',' -cne 'skillId,rawReportSha256,components,baseline' -or
            [string]$skill.rawReportSha256 -cnotmatch '^[0-9a-f]{64}$' -or $skill.components -isnot [array] -or @($skill.components).Count -eq 0 -or
            $skill.baseline.version -ne 2 -or [string]$skill.baseline.scanner_version -cne '2.12.0' -or
            $skill.baseline.fingerprints -isnot [array]) {
            throw "Reviewed E1 policy baseline data is invalid for '$($skill.skillId)'."
        }
        if ($skill.baseline.rules -isnot [array] -or @($skill.baseline.rules).Count -ne 0) { throw "Reviewed E1 baseline rules must be empty for '$($skill.skillId)'." }

        $componentPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $findingCount = 0
        foreach ($component in $skill.components) {
            $componentPath = [string]$component.path
            if ($component.PSObject.Properties.Name -join ',' -cne 'path,sha256,length,reviewedFindings' -or
                [string]::IsNullOrWhiteSpace($componentPath) -or $componentPath.StartsWith('/', [StringComparison]::Ordinal) -or
                $componentPath.Contains('\') -or @($componentPath.Split('/').Where({ $_ -in @('', '.', '..') })).Count -gt 0 -or
                [string]$component.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $component.length -le 0 -or
                $component.reviewedFindings -isnot [array] -or -not $componentPaths.Add($componentPath)) {
                throw "Reviewed E1 policy component is invalid for '$($skill.skillId)'."
            }
            foreach ($finding in $component.reviewedFindings) {
                if ($finding.PSObject.Properties.Name -join ',' -cne 'ruleId,severity,line,finding,disposition,reason' -or
                    [string]$finding.ruleId -cne 'E1' -or [string]$finding.severity -cne 'MEDIUM' -or
                    $finding.line -le 0 -or [string]::IsNullOrWhiteSpace([string]$finding.finding) -or
                    [string]$finding.disposition -cne 'false-positive' -or [string]::IsNullOrWhiteSpace([string]$finding.reason)) {
                    throw "Reviewed E1 occurrence is invalid for '$($skill.skillId)'."
                }
                $findingCount++
            }
        }
        if ($findingCount -eq 0 -or $findingCount -ne @($skill.baseline.fingerprints).Count) {
            throw "Reviewed E1 fingerprint inventory differs from its reviewed occurrences for '$($skill.skillId)'."
        }
        foreach ($fingerprint in $skill.baseline.fingerprints) {
            if ($fingerprint.PSObject.Properties.Name -join ',' -cne 'hash,rule_id,file,reason' -or
                [string]$fingerprint.hash -cnotmatch '^sha256:[0-9a-f]{64}$' -or [string]$fingerprint.rule_id -cne 'E1' -or
                [string]::IsNullOrWhiteSpace([string]$fingerprint.file) -or $fingerprint.file.Contains('\') -or
                @($fingerprint.file.Split('/').Where({ $_ -in @('', '.', '..') })).Count -gt 0 -or
                [string]::IsNullOrWhiteSpace([string]$fingerprint.reason)) {
                throw "Reviewed E1 fingerprint is invalid for '$($skill.skillId)'."
            }
        }
        $actualCount += $findingCount
    }
    if ($actualCount -ne [int]$Document.reviewedOccurrenceCount) { throw 'Reviewed E1 policy review occurrence count does not match the pinned document.' }
}

function Read-ReviewedE1BaselinePolicy {
    $path = Join-Path $PSScriptRoot 'SkillSpectorReviewedE1Baselines.json'
    Assert-StandardCoreV2NoReparseAncestors -Path $path -Context 'Protected reviewed E1 policy'
    $expectedHash = '05bf02ad11bc7f2430eb50f4a3e87c49b47c0eb92cb3453c1d8d0f44a443e2c2'
    $actualHash = Get-FileSha256 -Path $path
    if ($actualHash -cne $expectedHash) { throw 'Protected reviewed E1 policy hash differs from the pinned review artifact.' }
    try { $document = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 80 -ErrorAction Stop }
    catch { throw "Protected reviewed E1 policy JSON is invalid: $($_.Exception.Message)" }
    Assert-ReviewedE1BaselineContract -Document $document
    return [pscustomobject]@{ path = [IO.Path]::GetFullPath($path); sha256 = $actualHash; document = $document }
}

function Get-ReviewedE1SkillPolicy {
    param([Parameter(Mandatory)][object] $Policy, [Parameter(Mandatory)][string] $SkillId)
    $matches = @($Policy.document.skills | Where-Object { [string]$_.skillId -ceq $SkillId })
    if ($matches.Count -gt 1) { throw "Reviewed E1 policy contains duplicate Skill '$SkillId'." }
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Test-ReviewedE1ComponentsMatch {
    param([Parameter(Mandatory)][object] $SkillPolicy, [Parameter(Mandatory)][string] $SkillRoot, [Parameter(Mandatory)][string[]] $Inventory)
    foreach ($component in $SkillPolicy.components) {
        $relativePath = [string]$component.path
        if ($Inventory -cnotcontains $relativePath) { return $false }
        $path = [IO.Path]::GetFullPath((Join-Path $SkillRoot $relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)))
        if (-not (Test-PathWithin -Path $path -Root $SkillRoot) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        Assert-StandardCoreV2NoReparseAncestors -Path $path -Context "Reviewed E1 component '$relativePath'"
        $file = Get-Item -LiteralPath $path -Force
        if ($file.Length -ne [long]$component.length -or (Get-FileSha256 -Path $path) -cne [string]$component.sha256) { return $false }
    }
    return $true
}

function New-RunOwnedNativeJsonPath {
    param(
        [Parameter(Mandatory)][ValidateSet('b', 's')][string] $Prefix,
        [string] $WorkingDirectory = (Get-Location).Path,
        [ValidatePattern('^[0-9a-fA-F]{32}$')][string] $Nonce = ([guid]::NewGuid().ToString('N'))
    )
    $directory = [IO.Path]::GetFullPath($WorkingDirectory)
    $path = [IO.Path]::GetFullPath((Join-Path $directory ("{0}-{1}.json" -f $Prefix, $Nonce.ToLowerInvariant())))
    if ($IsWindows -and $path.Length -gt 259) {
        throw "Native JSON output path exceeds the Windows MAX_PATH limit of 259 characters (length $($path.Length)); use a shorter working directory."
    }
    if (Test-Path -LiteralPath $path) { throw "Native JSON output path already exists: $path" }
    return $path
}

function Write-ReviewedE1NativeBaseline {
    param([Parameter(Mandatory)][object] $SkillPolicy)
    $path = New-RunOwnedNativeJsonPath -Prefix 'b'
    $json = $SkillPolicy.baseline | ConvertTo-Json -Depth 80 -Compress
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json + "`n")
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    return [pscustomobject]@{ path = [IO.Path]::GetFullPath($path); sha256 = Get-FileSha256 -Path $path }
}

function Assert-ReviewedE1SuppressionReport {
    param([Parameter(Mandatory)][object] $Report, [object] $SkillPolicy, [Parameter(Mandatory)][string] $ExpectedScannerVersion, [Parameter(Mandatory)][string] $SkillId)
    $reportedVersion = [string]$Report.metadata.skillspector_version
    if ([string]::IsNullOrWhiteSpace($reportedVersion) -or $reportedVersion -cne $ExpectedScannerVersion) {
        throw "SkillSpector report version does not match its frozen receipt for '$SkillId'."
    }
    $countProperty = $Report.PSObject.Properties['suppressed_count']
    $suppressedProperty = $Report.PSObject.Properties['suppressed']
    if ($null -eq $countProperty -or ($countProperty.Value -isnot [int] -and $countProperty.Value -isnot [long]) -or
        [long]$countProperty.Value -lt 0 -or $null -eq $suppressedProperty -or $suppressedProperty.Value -isnot [array] -or
        [long]$countProperty.Value -ne @($suppressedProperty.Value).Count) {
        throw "SkillSpector returned a missing or malformed suppression ledger for '$SkillId'."
    }

    $expected = [Collections.Generic.List[string]]::new()
    if ($null -ne $SkillPolicy) {
        foreach ($component in $SkillPolicy.components) {
            foreach ($finding in $component.reviewedFindings) {
                $expected.Add((ConvertTo-Json -InputObject ([ordered]@{
                    id = 'E1'; severity = 'MEDIUM'; file = [string]$component.path; line = [int]$finding.line; finding = [string]$finding.finding
                }) -Compress -Depth 5))
            }
        }
    }
    if (@($suppressedProperty.Value).Count -ne $expected.Count) { throw "SkillSpector suppression count differs from the reviewed policy for '$SkillId'." }
    $remaining = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($key in $expected) { if (-not $remaining.Add($key)) { throw "Reviewed E1 policy has a duplicate expected occurrence for '$SkillId'." } }
    foreach ($suppressed in $suppressedProperty.Value) {
        if ($null -eq $suppressed -or $suppressed -is [string] -or $suppressed -is [ValueType] -or $suppressed -is [array]) {
            throw "SkillSpector returned a malformed suppressed occurrence for '$SkillId'."
        }
        $location = $suppressed.PSObject.Properties['location']
        $line = if ($null -ne $location -and $null -ne $location.Value.PSObject.Properties['start_line']) { $location.Value.start_line } else { $null }
        $file = if ($null -ne $location -and $null -ne $location.Value.PSObject.Properties['file']) { [string]$location.Value.file } else { '' }
        $finding = [string]$suppressed.finding
        $approvedReasons = @()
        if ($null -ne $SkillPolicy -and -not [string]::IsNullOrWhiteSpace($file)) {
            $approvedReasons = @($SkillPolicy.baseline.fingerprints | Where-Object {
                [string]$_.rule_id -ceq 'E1' -and [string]$_.file -ceq $file
            } | ForEach-Object { [string]$_.reason } | Sort-Object -Unique -CaseSensitive)
        }
        if ($suppressed.PSObject.Properties['suppressed']?.Value -isnot [bool] -or -not [bool]$suppressed.suppressed -or
            [string]$suppressed.id -cne 'E1' -or [string]$suppressed.severity -cne 'MEDIUM' -or
            ($line -isnot [int] -and $line -isnot [long]) -or [long]$line -le 0 -or
            [string]::IsNullOrWhiteSpace($file) -or [string]::IsNullOrWhiteSpace($finding) -or
            $approvedReasons.Count -ne 1 -or [string]$suppressed.suppression_reason -cne [string]$approvedReasons[0]) {
            throw "SkillSpector suppression was not a structured reviewed E1/MEDIUM occurrence for '$SkillId'."
        }
        $key = ConvertTo-Json -InputObject ([ordered]@{ id='E1'; severity='MEDIUM'; file=$file; line=[int]$line; finding=$finding }) -Compress -Depth 5
        if (-not $remaining.Remove($key)) { throw "SkillSpector suppressed an unreviewed or duplicate occurrence for '$SkillId'." }
    }
    if ($remaining.Count -ne 0) { throw "SkillSpector omitted a reviewed suppression for '$SkillId'." }
    return [int]$expected.Count
}

function Get-SkillSpectorReceiptVersion {
    param([Parameter(Mandatory)][object] $Toolchain, [Parameter(Mandatory)][string] $Command)
    $receiptPath = [string]$Toolchain.skillSpectorReceiptPath
    $receiptHash = [string]$Toolchain.skillSpectorReceiptSha256
    if ([string]::IsNullOrWhiteSpace($receiptPath) -or $receiptHash -cnotmatch '^[0-9a-f]{64}$' -or
        -not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { throw 'Frozen SkillSpector resolver receipt is missing.' }
    Assert-StandardCoreV2NoReparseAncestors -Path $receiptPath -Context 'Frozen SkillSpector resolver receipt'
    if ((Get-FileSha256 -Path $receiptPath) -cne $receiptHash) { throw 'Frozen SkillSpector resolver receipt hash changed.' }
    try { $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 40 -ErrorAction Stop }
    catch { throw "Frozen SkillSpector resolver receipt JSON is invalid: $($_.Exception.Message)" }
    if ([string]$receipt.toolName -cne 'skillspector' -or $receipt.frozenForRun -isnot [bool] -or -not $receipt.frozenForRun -or
        [string]$receipt.executablePath -cne [IO.Path]::GetFullPath($Command) -or
        [string]$receipt.executableSha256 -cne (Get-FileSha256 -Path $Command) -or
        [string]$receipt.resolvedVersion -cnotmatch '^\d+\.\d+\.\d+$') { throw 'Frozen SkillSpector resolver receipt does not bind the executable and semantic version.' }
    return [string]$receipt.resolvedVersion
}

function Invoke-NativeProcessWithEvidence {
    param([Parameter(Mandatory)][string] $Command, [Parameter(Mandatory)][string[]] $Arguments, [Parameter(Mandatory)][string] $Context)
    if (-not (Test-Path -LiteralPath $Command -PathType Leaf)) { throw "$Context command is missing." }
    $workingDirectory = [IO.Path]::GetFullPath((Get-Location).Path)
    Assert-StandardCoreV2NoReparseAncestors -Path $workingDirectory -Context "$Context evidence directory"
    $process = [Diagnostics.Process]::new()
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.WorkingDirectory = $workingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.FileName = [IO.Path]::GetFullPath($Command)
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add([string]$argument) }
    $process.StartInfo = $startInfo
    $stdout = [IO.MemoryStream]::new()
    $stderr = [IO.MemoryStream]::new()
    try {
        if (-not $process.Start()) { throw "$Context process could not start." }
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
        $process.WaitForExit()
        [void]$stdoutTask.GetAwaiter().GetResult()
        [void]$stderrTask.GetAwaiter().GetResult()
        $stdoutBytes = $stdout.ToArray()
        $stderrBytes = $stderr.ToArray()
        $evidenceId = [guid]::NewGuid().ToString('N')
        $stdoutPath = Join-Path $workingDirectory "native-raw-$Mode-$evidenceId.stdout.bin"
        $stderrPath = Join-Path $workingDirectory "native-raw-$Mode-$evidenceId.stderr.bin"
        $stdoutStream = [IO.File]::Open($stdoutPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        try { $stdoutStream.Write($stdoutBytes,0,$stdoutBytes.Length); $stdoutStream.Flush($true) } finally { $stdoutStream.Dispose() }
        $stderrStream = [IO.File]::Open($stderrPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        try { $stderrStream.Write($stderrBytes,0,$stderrBytes.Length); $stderrStream.Flush($true) } finally { $stderrStream.Dispose() }
        return [pscustomobject]@{ exitCode=[int]$process.ExitCode; stdoutBytes=$stdoutBytes; stderrBytes=$stderrBytes; stdoutPath=[IO.Path]::GetFullPath($stdoutPath); stderrPath=[IO.Path]::GetFullPath($stderrPath) }
    }
    finally { $stdout.Dispose(); $stderr.Dispose(); $process.Dispose() }
}

function Resolve-CandidateFile {
    param([Parameter(Mandatory)][string] $Value, [Parameter(Mandatory)][string] $SkillRoot, [Parameter(Mandatory)][string[]] $Inventory)
    $candidate = if ([IO.Path]::IsPathRooted($Value)) { $Value } else { Join-Path $SkillRoot $Value }
    $full = [IO.Path]::GetFullPath($candidate)
    if (-not (Test-PathWithin -Path $full -Root $SkillRoot)) { throw 'Native tool report path escaped its candidate Skill.' }
    foreach ($relative in $Inventory) {
        if ($full.Equals([IO.Path]::GetFullPath((Join-Path $SkillRoot $relative)), $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }))) { return $full }
    }
    throw 'Native tool report referenced a file outside the frozen Skill inventory.'
}

function Get-SkillInventory {
    param([Parameter(Mandatory)][string] $SkillRoot)
    $root = [IO.Path]::GetFullPath($SkillRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Candidate Skill root is missing: $root" }
    $paths = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | ForEach-Object {
        [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/')
    })
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    if ($paths.Count -eq 0) { throw 'Candidate Skill inventory is empty.' }
    return [string[]]$paths
}

function Invoke-NativeJson {
    param([Parameter(Mandatory)][string] $Command, [Parameter(Mandatory)][string[]] $Arguments, [Parameter(Mandatory)][string] $Context)
    $execution = Invoke-NativeProcessWithEvidence -Command $Command -Arguments $Arguments -Context $Context
    $evidence = "rawStdout=$($execution.stdoutPath); rawStderr=$($execution.stderrPath)"
    if ($execution.exitCode -ne 0) { throw "$Context returned exit code $($execution.exitCode). $evidence" }
    try { $text = [Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$execution.stdoutBytes).Trim() }
    catch { throw "$Context returned non-UTF-8 JSON output. $evidence" }
    if ([string]::IsNullOrWhiteSpace($text)) { throw "$Context returned no JSON output. $evidence" }
    try { $report = $text | ConvertFrom-Json -Depth 100 -ErrorAction Stop }
    catch { throw "$Context returned invalid JSON. $evidence $($_.Exception.Message)" }
    $path = Join-Path (Get-Location) "native-$Mode-$([guid]::NewGuid().ToString('N')).json"
    [IO.File]::WriteAllText($path, $text + "`n", [Text.UTF8Encoding]::new($false))
    $script:NativeReports.Add([pscustomobject]@{
        skillId = [string]$env:STANDARD_VALIDATION_SKILL_ID
        command = [IO.Path]::GetFullPath($Command)
        commandSha256 = Get-FileSha256 -Path $Command
        arguments = @($Arguments)
        exitCode = [int]$execution.exitCode
        path = [IO.Path]::GetFullPath($path)
        sha256 = Get-FileSha256 -Path $path
    })
    return $report
}

function Write-Envelope {
    param([string[]] $ActiveSkills, [object[]] $Findings = @(), [hashtable] $Additional = @{})
    $envelope = [ordered]@{
        schemaVersion = 1
        status = 'passed'
        decision = 'PASS'
        candidateIdentity = [string]$env:STANDARD_VALIDATION_CANDIDATE_ID
        activeSkills = @($ActiveSkills)
        findings = @($Findings)
    }
    if ($Mode -in @('skill-validator', 'skill-tools', 'static')) { $envelope.nativeReports = @($script:NativeReports.ToArray()) }
    foreach ($key in $Additional.Keys) { $envelope[$key] = $Additional[$key] }
    [Console]::Out.WriteLine(($envelope | ConvertTo-Json -Depth 80 -Compress))
    exit 0
}

$script:NativeReports = [Collections.Generic.List[object]]::new()
$toolchainFull = [IO.Path]::GetFullPath($ToolchainPath)
if ((Get-FileSha256 -Path $toolchainFull) -cne $ToolchainSha256) { throw 'Frozen source toolchain changed.' }
$toolchain = Get-Content -LiteralPath $toolchainFull -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 40 -ErrorAction Stop
$candidateRoot = [IO.Path]::GetFullPath([string]$env:STANDARD_VALIDATION_CANDIDATE_ROOT)
$candidateId = [string]$env:STANDARD_VALIDATION_CANDIDATE_ID
$skillText = [string]$env:STANDARD_VALIDATION_ACTIVE_SKILLS
$activeSkills = [string[]]@($skillText -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ([string]::IsNullOrWhiteSpace($candidateId) -or $activeSkills.Count -eq 0 -or
    @($activeSkills | Select-Object -Unique).Count -ne $activeSkills.Count) { throw 'Central runner supplied an invalid source candidate identity or Skill set.' }

if ($Mode -eq 'skill-validator') {
    if ((Get-FileSha256 -Path ([string]$toolchain.centralRunnerPath)) -cne [string]$toolchain.centralRunnerSha256) {
        throw 'Frozen central validation runner changed.'
    }
    $sharedReportFunctions = & {
        param($RunnerPath, $CandidateRoot, $ToolchainPath)
        . $RunnerPath -DefineFunctionsOnly -CandidateRoot $CandidateRoot -AdapterPath $ToolchainPath `
            -ArtifactsRoot ([IO.Path]::GetFullPath((Get-Location).Path)) -SourceRepository ([string]$toolchain.sourceRepository) `
            -SourceRevision ([string]$toolchain.sourceRevision) -BaseRevision ([string]$toolchain.sourceRevision)
        $exports = @{}
        foreach ($name in @(
            'Get-StandardValidationFullPath',
            'Get-StandardValidationCaseVariant',
            'Get-StandardValidationPathCaseBehavior',
            'Get-StandardValidationPathComparison',
            'Test-StandardValidationSameResolvedPath',
            'Assert-StandardValidationSkillValidatorReport'
        )) {
            $exports[$name] = (Get-Command $name -CommandType Function -ErrorAction Stop).ScriptBlock
        }
        return $exports
    } ([string]$toolchain.centralRunnerPath) $candidateRoot $toolchainFull
    foreach ($name in $sharedReportFunctions.Keys) { Set-Item -Path "function:$name" -Value $sharedReportFunctions[$name] }
}

switch ($Mode) {
    'package-adapter' {
        $candidatePath = [IO.Path]::GetFullPath($candidateRoot)
        if ([IO.Path]::GetFileName($candidatePath) -cne 'candidate') { throw 'Package adapter did not receive the central candidate snapshot.' }
        $runRoot = Split-Path -Parent $candidatePath
        $runId = [IO.Path]::GetFileName($runRoot)
        $runsRoot = Split-Path -Parent $runRoot
        if ($runId -cnotmatch '^[0-9a-f]{32}$' -or [IO.Path]::GetFileName($runsRoot) -cne 'runs') { throw 'Package adapter candidate path is not in the canonical run tree.' }
        $artifactsRoot = Split-Path -Parent $runsRoot
        $adapterRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $artifactsRoot) ".core-v2-adapter-$runId"))
        $metadataRoot = Join-Path $adapterRoot 'candidate-git'
        $gitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
        $binding = Assert-StandardCoreV2SourceBinding -SnapshotRoot $candidateRoot -ExpectedSha256 ([string]$toolchain.sourceBindingSha256) `
            -RunId $runId -MetadataRoot $metadataRoot -GitPath $gitPath
        $catalogPath = Join-Path $candidateRoot 'catalog/source.json'
        $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20 -ErrorAction Stop
        $catalogSkills = [string[]]@($catalog.skills | ForEach-Object { [string]$_ })
        if ((@($catalogSkills | Sort-Object -CaseSensitive) -join "`n") -cne (@($activeSkills | Sort-Object -CaseSensitive) -join "`n")) { throw 'Candidate package adapter Skill inventory differs from the central runner.' }
        $validator = Join-Path $candidateRoot 'scripts/Test-Repository.ps1'
        $raw = @(& $validator -RepositoryRoot $candidateRoot -ReadOnlySnapshot -GitMetadataRoot $binding.GitMetadataRoot `
            -ExpectedRevision $binding.SourceRevision -TrustedGitPath $gitPath 6>$null)
        if ($raw.Count -eq 0) { throw 'Candidate package adapter returned no repository contract report.' }
        $report = ([string]$raw[-1]) | ConvertFrom-Json -Depth 40 -ErrorAction Stop
        $reportedSkills = [string[]]@($report.skills | ForEach-Object { [string]$_.skillId })
        if ([string]$report.result -cne 'passed' -or [int]$report.activeSkillCount -ne $activeSkills.Count -or
            (@($reportedSkills | Sort-Object -CaseSensitive) -join "`n") -cne (@($activeSkills | Sort-Object -CaseSensitive) -join "`n")) {
            throw 'Candidate package adapter did not pass the repository-specific contract and active Skill inventory.'
        }
        Write-Envelope -ActiveSkills $activeSkills -Additional @{
            testInventory = @($activeSkills | ForEach-Object { [pscustomobject]@{ id=[string]$_ } })
            testResult = [ordered]@{ status='passed'; decision='PASS'; result='Test-Repository' }
            domainAdapterResult = [ordered]@{ status='passed'; decision='PASS'; result='atlassian-ecosystem-source-adapter' }
        }
    }
    'skill-validator' {
        $skillId = [string]$env:STANDARD_VALIDATION_SKILL_ID
        $skillRoot = Join-Path ([string]$env:STANDARD_VALIDATION_SKILLS_ROOT) $skillId
        $inventory = Get-SkillInventory -SkillRoot $skillRoot
        $command = [string]$toolchain.skillValidatorPath
        if ((Get-FileSha256 -Path $command) -cne [string]$toolchain.skillValidatorSha256) { throw 'skill-validator executable hash changed.' }
        $arguments = @('-o', 'json', 'validate', 'structure', '--allow-dirs=agents', $skillRoot)
        $report = Invoke-NativeJson -Command $command -Arguments $arguments -Context "skill-validator '$skillId'"
        $results = @(Assert-StandardValidationSkillValidatorReport -Report $report -SkillRoot $skillRoot -SkillId $skillId)
        foreach ($result in $results) {
            if ($null -ne $result.PSObject.Properties['file']) {
                [void](Resolve-CandidateFile -Value ([string]$result.file) -SkillRoot $skillRoot -Inventory $inventory)
            }
        }
        Write-Envelope -ActiveSkills $activeSkills -Additional @{ skillId=$skillId; skillInventorySha256=[string]$env:STANDARD_VALIDATION_SKILL_INVENTORY_SHA256 }
    }
    'skill-tools' {
        $skillId = [string]$env:STANDARD_VALIDATION_SKILL_ID
        $skillRoot = Join-Path ([string]$env:STANDARD_VALIDATION_SKILLS_ROOT) $skillId
        $inventory = Get-SkillInventory -SkillRoot $skillRoot
        $node = [string]$toolchain.skillToolsNodePath
        $entry = [string]$toolchain.skillToolsEntryPointPath
        if ((Get-FileSha256 -Path $node) -cne [string]$toolchain.skillToolsNodeSha256 -or
            (Get-FileSha256 -Path $entry) -cne [string]$toolchain.skillToolsEntryPointSha256) { throw 'skill-tools runtime or entry point hash changed.' }
        $report = Invoke-NativeJson -Command $node -Arguments @($entry, 'check', $skillRoot, '--format', 'sarif', '--fail-on', 'warning', '--min-score', '91') -Context "skill-tools '$skillId'"
        if ([string]$report.version -cne '2.1.0' -or @($report.runs).Count -ne 1 -or [string]$report.runs[0].tool.driver.name -cne 'skill-tools') {
            throw "skill-tools did not return one valid SARIF 2.1.0 run for '$skillId'."
        }
        foreach ($result in @($report.runs[0].results)) {
            $level = [string]$result.level
            if ([string]::IsNullOrWhiteSpace($level)) { $level = [string]$report.runs[0].tool.driver.rules[[int]$result.ruleIndex].defaultConfiguration.level }
            if ($level -in @('warning','error')) { throw "skill-tools reported a blocking SARIF result for '$skillId'." }
            foreach ($location in @($result.locations)) {
                $uri = [string]$location.physicalLocation.artifactLocation.uri
                if (-not [string]::IsNullOrWhiteSpace($uri)) { [void](Resolve-CandidateFile -Value $uri -SkillRoot $skillRoot -Inventory $inventory) }
            }
        }
        Write-Envelope -ActiveSkills $activeSkills -Additional @{ skillId=$skillId; skillInventorySha256=[string]$env:STANDARD_VALIDATION_SKILL_INVENTORY_SHA256 }
    }
    'static' {
        $command = [string]$toolchain.skillSpectorPath
        if ((Get-FileSha256 -Path $command) -cne [string]$toolchain.skillSpectorSha256) { throw 'SkillSpector executable hash changed.' }
        $reviewedPolicy = Read-ReviewedE1BaselinePolicy
        $scannerVersion = Get-SkillSpectorReceiptVersion -Toolchain $toolchain -Command $command
        $findings = [Collections.Generic.List[object]]::new()
        foreach ($skillId in $activeSkills) {
            $skillRoot = Join-Path ([string]$env:STANDARD_VALIDATION_SKILLS_ROOT) $skillId
            $inventory = Get-SkillInventory -SkillRoot $skillRoot
            $reviewedSkill = Get-ReviewedE1SkillPolicy -Policy $reviewedPolicy -SkillId $skillId
            $baselineSkill = $null
            $baselineComponentMatch = $null
            $baselineDecision = 'not-reviewed'
            if ($null -ne $reviewedSkill) {
                if ($scannerVersion -cne [string]$reviewedPolicy.document.scannerVersion) {
                    $baselineDecision = 'scanner-version-mismatch'
                } else {
                    $baselineComponentMatch = Test-ReviewedE1ComponentsMatch -SkillPolicy $reviewedSkill -SkillRoot $skillRoot -Inventory $inventory
                    if ($baselineComponentMatch) {
                        $baselineSkill = $reviewedSkill
                        $baselineDecision = 'applied'
                    } else {
                        $baselineDecision = 'component-hash-drift'
                    }
                }
            }
            $reportPath = New-RunOwnedNativeJsonPath -Prefix 's'
            $args = @('scan', $skillRoot, '--no-llm', '--format', 'json', '--output', $reportPath)
            $materializedBaseline = $null
            if ($null -ne $baselineSkill) {
                $materializedBaseline = Write-ReviewedE1NativeBaseline -SkillPolicy $baselineSkill
                $args += @('--baseline', [string]$materializedBaseline.path, '--show-suppressed')
            }
            $execution=Invoke-NativeProcessWithEvidence -Command $command -Arguments $args -Context "SkillSpector '$skillId'"
            $exitCode=$execution.exitCode
            $reportEvidence = "report=$([IO.Path]::GetFullPath($reportPath)); rawStdout=$($execution.stdoutPath); rawStderr=$($execution.stderrPath)"
            if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
                throw "SkillSpector scan failed for '$skillId'. $reportEvidence"
            }
            try { $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 80 -ErrorAction Stop }
            catch { throw "SkillSpector report was invalid for '$skillId'. $reportEvidence $($_.Exception.Message)" }
            $reportedSourcePath = if ($null -ne $report.skill.source) { [IO.Path]::GetFullPath([string]$report.skill.source) } else { '' }
            $sourceComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
            if ($report.execution_successful -isnot [bool] -or -not $report.execution_successful -or
                $report.analysis_completeness.execution_successful -isnot [bool] -or -not $report.analysis_completeness.execution_successful -or
                $report.analysis_completeness.is_complete -isnot [bool] -or -not $report.analysis_completeness.is_complete -or
                [string]$report.analysis_completeness.status -cne 'complete' -or [double]$report.analysis_completeness.coverage_percent -ne 100 -or
                @($report.analysis_completeness.ledger_exceptions).Count -gt 0 -or @($report.analysis_completeness.scope_exclusions).Count -gt 0 -or
                @($report.analysis_completeness.limitations).Count -gt 0 -or [string]$report.skill.name -cne $skillId -or
                -not $reportedSourcePath.Equals([IO.Path]::GetFullPath($skillRoot), $sourceComparison) -or @($report.components).Count -ne @($inventory).Count) {
                throw "SkillSpector did not prove complete candidate-bound static analysis for '$skillId'. $reportEvidence"
            }
            try { $suppressedCount = Assert-ReviewedE1SuppressionReport -Report $report -SkillPolicy $baselineSkill -ExpectedScannerVersion $scannerVersion -SkillId $skillId }
            catch { throw "SkillSpector suppression ledger was invalid for '$skillId'. $reportEvidence $($_.Exception.Message)" }
            $covered = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($component in @($report.components)) {
                if ($inventory -cnotcontains [string]$component.path -or -not $covered.Add([string]$component.path)) { throw "SkillSpector inventory differs for '$skillId'. $reportEvidence" }
            }
            $expectedSuppressedCount = if ($null -ne $baselineSkill) { @($baselineSkill.components | ForEach-Object { @($_.reviewedFindings) }).Count } else { 0 }
            $script:NativeReports.Add([pscustomobject]@{
                skillId = $skillId
                scannerIdentity = 'SkillSpector'
                scannerVersion = $scannerVersion
                command = [IO.Path]::GetFullPath($command)
                commandSha256 = Get-FileSha256 -Path $command
                arguments = @($args)
                exitCode = [int]$exitCode
                path = [IO.Path]::GetFullPath($reportPath)
                sha256 = Get-FileSha256 -Path $reportPath
                reviewedBaseline = [pscustomobject]@{
                    decision = $baselineDecision
                    applied = ($null -ne $baselineSkill)
                    componentHashesMatched = $baselineComponentMatch
                    policyPath = [string]$reviewedPolicy.path
                    policySha256 = [string]$reviewedPolicy.sha256
                    reviewer = [string]$reviewedPolicy.document.reviewer
                    reviewFindingId = [string]$reviewedPolicy.document.reviewFindingId
                    reviewedSourceRevision = [string]$reviewedPolicy.document.reviewedSourceRevision
                    authorityRevision = [string]$reviewedPolicy.document.authorityRevision
                    reviewedRawReportSha256 = if ($null -ne $reviewedSkill) { [string]$reviewedSkill.rawReportSha256 } else { $null }
                    nativeBaselinePath = if ($null -ne $materializedBaseline) { [string]$materializedBaseline.path } else { $null }
                    nativeBaselineSha256 = if ($null -ne $materializedBaseline) { [string]$materializedBaseline.sha256 } else { $null }
                    expectedSuppressedCount = [int]$expectedSuppressedCount
                    actualSuppressedCount = [int]$suppressedCount
                }
            })
            foreach ($issue in @($report.issues)) {
                if ($null -eq $issue -or $issue -is [string] -or $issue -is [ValueType] -or $issue -is [array]) {
                    throw "SkillSpector issue was not a structured finding for '$skillId'. $reportEvidence"
                }
                $severityProperty = $issue.PSObject.Properties['severity']
                if ($null -eq $severityProperty -or $severityProperty.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$severityProperty.Value)) {
                    throw "SkillSpector issue had no valid severity for '$skillId'. $reportEvidence"
                }
                $severity = ([string]$severityProperty.Value).ToLowerInvariant()
                if ($severity -notin @('critical', 'high', 'medium', 'low', 'informational')) {
                    throw "SkillSpector issue had an unknown severity '$($severityProperty.Value)' for '$skillId'. $reportEvidence"
                }

                $locationProperty = $issue.PSObject.Properties['location']
                if ($null -eq $locationProperty -or $null -eq $locationProperty.Value -or $locationProperty.Value -is [string] -or $locationProperty.Value -is [ValueType]) {
                    throw "SkillSpector issue had no structured location for '$skillId'. $reportEvidence"
                }
                $fileProperty = $locationProperty.Value.PSObject.Properties['file']
                if ($null -eq $fileProperty -or $fileProperty.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$fileProperty.Value)) {
                    throw "SkillSpector issue had no candidate file location for '$skillId'. $reportEvidence"
                }
                try { $resolvedFile = Resolve-CandidateFile -Value ([string]$fileProperty.Value) -SkillRoot $skillRoot -Inventory $inventory }
                catch { throw "SkillSpector issue referenced an invalid candidate file for '$skillId'. $reportEvidence $($_.Exception.Message)" }
                $relativeFile = [IO.Path]::GetRelativePath($candidateRoot, $resolvedFile).Replace('\', '/')
                $finding = [ordered]@{ severity = $severity }

                $optionalStrings = @(
                    @{ Target = 'fingerprint'; Source = 'match_fingerprint' },
                    @{ Target = 'ruleId'; Source = 'id' }
                )
                foreach ($mapping in $optionalStrings) {
                    $property = $issue.PSObject.Properties[[string]$mapping.Source]
                    if ($null -ne $property -and $null -ne $property.Value) {
                        if ($property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$property.Value) -or [string]$property.Value -match '[\x00-\x1F\x7F]') {
                            throw "SkillSpector issue had an invalid $($mapping.Source) field for '$skillId'. $reportEvidence"
                        }
                        $finding[[string]$mapping.Target] = [string]$property.Value
                    }
                }

                $message = $null
                foreach ($sourceName in @('explanation', 'message', 'finding')) {
                    $property = $issue.PSObject.Properties[$sourceName]
                    if ($null -ne $property -and $property.Value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                        $message = [string]$property.Value
                        break
                    }
                }
                if ($null -ne $message) {
                    if ($message -match '[\x00-\x1F\x7F]') { throw "SkillSpector issue had an invalid message field for '$skillId'. $reportEvidence" }
                    $finding.message = $message
                }
                $finding.path = $relativeFile
                [void]$findings.Add([pscustomobject]$finding)
            }
        }
        Write-Envelope -ActiveSkills $activeSkills -Findings @($findings.ToArray()) -Additional @{
            scannerIdentity='SkillSpector'
            analyzerCompleteness='complete'
            reviewedBaselinePolicy=[pscustomobject]@{
                artifactPath=[string]$reviewedPolicy.path
                artifactSha256=[string]$reviewedPolicy.sha256
                reviewer=[string]$reviewedPolicy.document.reviewer
                reviewFindingId=[string]$reviewedPolicy.document.reviewFindingId
                scannerVersion=[string]$reviewedPolicy.document.scannerVersion
            }
        }
    }
}
