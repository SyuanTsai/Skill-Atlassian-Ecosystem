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
        $findings = @()
        foreach ($skillId in $activeSkills) {
            $skillRoot = Join-Path ([string]$env:STANDARD_VALIDATION_SKILLS_ROOT) $skillId
            $inventory = Get-SkillInventory -SkillRoot $skillRoot
            $reportPath = Join-Path (Get-Location) "skillspector-$skillId.json"
            $args = @('scan', $skillRoot, '--no-llm', '--format', 'json', '--output', $reportPath)
            $execution=Invoke-NativeProcessWithEvidence -Command $command -Arguments $args -Context "SkillSpector '$skillId'"
            $exitCode=$execution.exitCode
            if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
                throw "SkillSpector scan failed for '$skillId'. rawStdout=$($execution.stdoutPath); rawStderr=$($execution.stderrPath)"
            }
            $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 80 -ErrorAction Stop
            if ($report.execution_successful -isnot [bool] -or -not $report.execution_successful -or
                $report.analysis_completeness.execution_successful -isnot [bool] -or -not $report.analysis_completeness.execution_successful -or
                $report.analysis_completeness.is_complete -isnot [bool] -or -not $report.analysis_completeness.is_complete -or
                [string]$report.analysis_completeness.status -cne 'complete' -or [double]$report.analysis_completeness.coverage_percent -ne 100 -or
                @($report.analysis_completeness.ledger_exceptions).Count -gt 0 -or @($report.analysis_completeness.scope_exclusions).Count -gt 0 -or
                @($report.analysis_completeness.limitations).Count -gt 0 -or [string]$report.skill.name -cne $skillId -or
                -not (Test-PathWithin -Path ([string]$report.skill.source) -Root $skillRoot) -or @($report.components).Count -ne $inventory.Count) {
                throw "SkillSpector did not prove complete candidate-bound static analysis for '$skillId'."
            }
            $covered = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($component in @($report.components)) {
                if ($inventory -cnotcontains [string]$component.path -or -not $covered.Add([string]$component.path)) { throw "SkillSpector inventory differs for '$skillId'." }
            }
            if (@($report.issues).Count -gt 0) { throw "SkillSpector reported issues for '$skillId'." }
            $script:NativeReports.Add([pscustomobject]@{ skillId=$skillId; command=[IO.Path]::GetFullPath($command); commandSha256=(Get-FileSha256 -Path $command); arguments=@($args); exitCode=[int]$exitCode; path=[IO.Path]::GetFullPath($reportPath); sha256=(Get-FileSha256 -Path $reportPath) })
        }
        Write-Envelope -ActiveSkills $activeSkills -Additional @{ scannerIdentity='SkillSpector'; analyzerCompleteness='complete' }
    }
}
