# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ExecutablePath,
    [string] $ExecutablePrefixArgumentsJson = '[]',
    [Parameter(Mandatory = $true)][string] $SkillsRoot,
    [Parameter(Mandatory = $true)][string] $SkillIdsJson,
    [Parameter(Mandatory = $true)][string] $OutputRoot,
    [Parameter(Mandatory = $true)][string] $SummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$processes = [Collections.Generic.List[object]]::new()
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$maxObservedConcurrency = 0
$failure = $null
$completedSuccessfully = $false
$maximumDiagnosticCharacters = 4096

function Get-BoundedScannerDiagnostic {
    param([AllowNull()][string] $Text)

    if ([string]::IsNullOrEmpty($Text) -or $Text.Length -le $maximumDiagnosticCharacters) { return [string]$Text }
    return $Text.Substring(0, $maximumDiagnosticCharacters)
}

function Write-Utf8NoBomCreateNew {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [AllowEmptyString()][Parameter(Mandatory = $true)][string] $Text
    )

    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $bytes = $utf8NoBom.GetBytes($Text)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}

function Stop-OwnedScannerProcesses {
    param([Parameter(Mandatory = $true)] $Records)
    foreach ($record in @($Records)) {
        try { if (-not $record.process.HasExited) { $record.process.Kill($true) } }
        catch { }
    }
    foreach ($record in @($Records)) {
        try { if (-not $record.process.HasExited) { $record.process.WaitForExit(5000) | Out-Null } }
        catch { }
    }
}

try {
    $executableFull = [IO.Path]::GetFullPath($ExecutablePath)
    if (-not (Test-Path -LiteralPath $executableFull -PathType Leaf)) { throw "SkillSpector executable is missing: $executableFull" }
    $executableItem = Get-Item -LiteralPath $executableFull -Force
    if (($executableItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'SkillSpector executable must not be a reparse point.' }

    try { $prefixArguments = @($ExecutablePrefixArgumentsJson | ConvertFrom-Json -Depth 10) }
    catch { throw "Executable prefix arguments are not valid JSON: $($_.Exception.Message)" }
    if ($null -eq $prefixArguments) { $prefixArguments = @() }
    foreach ($argument in $prefixArguments) {
        if ($argument -isnot [string]) { throw 'Every executable prefix argument must be a string.' }
    }
    try { $skillIds = @($SkillIdsJson | ConvertFrom-Json -Depth 10) }
    catch { throw "Skill IDs are not valid JSON: $($_.Exception.Message)" }
    if ($skillIds.Count -le 0 -or $skillIds.Count -gt 32) { throw 'Parallel SkillSpector requires between one and 32 Skill IDs.' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($skillIdValue in $skillIds) {
        if ($skillIdValue -isnot [string] -or [string]$skillIdValue -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62})$' -or -not $seen.Add([string]$skillIdValue)) {
            throw 'Parallel SkillSpector received an invalid or duplicate Skill ID.'
        }
    }

    $skillsFull = [IO.Path]::GetFullPath($SkillsRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $skillsFull -PathType Container)) { throw "Skills root is missing: $skillsFull" }
    $skillsItem = Get-Item -LiteralPath $skillsFull -Force
    if (($skillsItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Skills root must not be a reparse point.' }
    $outputFull = [IO.Path]::GetFullPath($OutputRoot)
    [void](New-Item -ItemType Directory -Path $outputFull -Force)
    $outputItem = Get-Item -LiteralPath $outputFull -Force
    if (-not $outputItem.PSIsContainer -or ($outputItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'SkillSpector output root must be a regular directory.'
    }
    $summaryFull = [IO.Path]::GetFullPath($SummaryPath)
    if (Test-Path -LiteralPath $summaryFull) { throw "Parallel SkillSpector summary is create-only: $summaryFull" }
    $pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }

    foreach ($skillIdValue in $skillIds) {
        $skillId = [string]$skillIdValue
        $skillRoot = [IO.Path]::GetFullPath((Join-Path $skillsFull $skillId))
        if (-not $skillRoot.StartsWith($skillsFull + [IO.Path]::DirectorySeparatorChar, $pathComparison) -or
            -not (Test-Path -LiteralPath $skillRoot -PathType Container)) {
            throw "Skill root is unsafe or missing: $skillId"
        }
        $reportPath = Join-Path $outputFull "skillspector-$skillId.json"
        $stderrPath = Join-Path $outputFull "skillspector-$skillId.stderr.txt"
        if (Test-Path -LiteralPath $reportPath) { throw "SkillSpector report is create-only: $reportPath" }
        if (Test-Path -LiteralPath $stderrPath) { throw "SkillSpector stderr is create-only: $stderrPath" }
        $skillRootPrefix = $skillRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if ($reportPath.StartsWith($skillRootPrefix, $pathComparison) -or $stderrPath.StartsWith($skillRootPrefix, $pathComparison)) {
            throw "SkillSpector output files must be outside the scan target: $skillId"
        }
        $scanArguments = @('scan', $skillRoot, '--no-llm', '--format', 'json')
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $executableFull
        $start.WorkingDirectory = $outputFull
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        # Keep the receipt-bound Python install closure unchanged for the central correction that follows these scans.
        $start.Environment['PYTHONDONTWRITEBYTECODE'] = '1'
        foreach ($argument in @($prefixArguments) + $scanArguments) {
            [void]$start.ArgumentList.Add([string]$argument)
        }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        if (-not $process.Start()) { throw "Could not start SkillSpector for '$skillId'." }
        $processes.Add([pscustomobject]@{
                skillId = $skillId
                reportPath = $reportPath
                stderrPath = $stderrPath
                arguments = $scanArguments
                process = $process
                stdoutTask = $process.StandardOutput.ReadToEndAsync()
                stderrTask = $process.StandardError.ReadToEndAsync()
                completed = $false
                stdout = $null
                stderr = $null
                exitCode = $null
            })
        $activeCount = @($processes | Where-Object { -not $_.process.HasExited }).Count
        if ($activeCount -gt $maxObservedConcurrency) { $maxObservedConcurrency = $activeCount }
    }

    while (@($processes | Where-Object { -not $_.completed }).Count -gt 0 -and $null -eq $failure) {
        foreach ($record in $processes) {
            if ($record.completed -or -not $record.process.HasExited) { continue }
            $record.process.WaitForExit()
            $record.stdout = $record.stdoutTask.GetAwaiter().GetResult()
            $record.stderr = $record.stderrTask.GetAwaiter().GetResult()
            $record.exitCode = $record.process.ExitCode
            Write-Utf8NoBomCreateNew -Path $record.reportPath -Text ([string]$record.stdout)
            Write-Utf8NoBomCreateNew -Path $record.stderrPath -Text ([string]$record.stderr)
            $record.completed = $true
            if ($record.exitCode -ne 0 -and $null -eq $failure) {
                $failure = "SkillSpector scan for '$($record.skillId)' failed with exit code $($record.exitCode): $(Get-BoundedScannerDiagnostic -Text ([string]$record.stderr))"
            }
            elseif ($null -eq $failure) {
                try { [void]([IO.File]::ReadAllText($record.reportPath, $utf8NoBom) | ConvertFrom-Json -Depth 100) }
                catch {
                    $failure = "SkillSpector scan for '$($record.skillId)' returned invalid JSON: $($_.Exception.Message). STDERR: $(Get-BoundedScannerDiagnostic -Text ([IO.File]::ReadAllText($record.stderrPath, $utf8NoBom)))"
                }
            }
        }
        if ($null -eq $failure -and @($processes | Where-Object { -not $_.completed }).Count -gt 0) { Start-Sleep -Milliseconds 50 }
    }
    if ($null -ne $failure) {
        Stop-OwnedScannerProcesses -Records $processes
        throw $failure
    }
    foreach ($record in $processes) {
        if (-not (Test-Path -LiteralPath $record.reportPath -PathType Leaf)) {
            throw "SkillSpector scan for '$($record.skillId)' did not create its report."
        }
    }

    $stopwatch.Stop()
    $summary = [ordered]@{
        marker = 'atlassian-parallel-skillspector-v1'
        skillIds = @($skillIds | ForEach-Object { [string]$_ })
        processCount = $processes.Count
        maxObservedConcurrency = $maxObservedConcurrency
        elapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
        reports = @($processes | ForEach-Object {
                [ordered]@{
                    skillId = $_.skillId
                    path = [IO.Path]::GetFullPath($_.reportPath)
                    stderrPath = [IO.Path]::GetFullPath($_.stderrPath)
                    arguments = @($_.arguments)
                }
            })
    }
    $summaryJson = $summary | ConvertTo-Json -Depth 10 -Compress
    $stream = [IO.File]::Open($summaryFull, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = $utf8NoBom.GetBytes($summaryJson)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
    foreach ($record in $processes) {
        if (-not [string]::IsNullOrEmpty([string]$record.stdout)) { [Console]::Out.Write([string]$record.stdout) }
        if (-not [string]::IsNullOrEmpty([string]$record.stderr)) { [Console]::Error.Write([string]$record.stderr) }
    }
    $summaryJson
    $completedSuccessfully = $true
}
finally {
    if (-not $completedSuccessfully) { Stop-OwnedScannerProcesses -Records $processes }
    foreach ($record in $processes) {
        try { $record.process.Dispose() }
        catch { }
    }
}
