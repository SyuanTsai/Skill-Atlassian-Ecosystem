# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $PowerShellPath,
    [Parameter(Mandatory = $true)][string] $ResolverPath,
    [Parameter(Mandatory = $true)][string] $PolicyPath,
    [Parameter(Mandatory = $true)][string] $InstallRoot,
    [Parameter(Mandatory = $true)][string] $ExpectedGoRuntimeVersion,
    [Parameter(Mandatory = $true)][string] $RunId,
    [Parameter(Mandatory = $true)][string] $OutputRoot,
    [Parameter(Mandatory = $true)][string] $SummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$toolNames = @('skillspector', 'skill-validator', 'skill-tools', 'pester')
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$processes = [Collections.Generic.List[object]]::new()
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$maxObservedConcurrency = 0
$failure = $null
$completedSuccessfully = $false

function Assert-RegularInputFile {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Context)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "$Context is missing: $fullPath" }
    $item = Get-Item -LiteralPath $fullPath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Context must not be a reparse point: $fullPath" }
    return $fullPath
}

function Stop-OwnedResolverProcesses {
    param([Parameter(Mandatory = $true)] $Records)
    foreach ($record in @($Records)) {
        try {
            if (-not $record.process.HasExited) { $record.process.Kill($true) }
        }
        catch { }
    }
    foreach ($record in @($Records)) {
        try { if (-not $record.process.HasExited) { $record.process.WaitForExit(5000) | Out-Null } }
        catch { }
    }
}

try {
    $powerShellFull = Assert-RegularInputFile -Path $PowerShellPath -Context 'PowerShell executable'
    $resolverFull = Assert-RegularInputFile -Path $ResolverPath -Context 'Validation tool resolver'
    $policyFull = Assert-RegularInputFile -Path $PolicyPath -Context 'Validation tool policy'
    $installFull = [IO.Path]::GetFullPath($InstallRoot)
    $outputFull = [IO.Path]::GetFullPath($OutputRoot)
    $summaryFull = [IO.Path]::GetFullPath($SummaryPath)
    if ($RunId -cnotmatch '^[0-9a-f]{32}$') { throw 'Resolver RunId must be a lowercase 32-character hexadecimal value.' }
    if ([string]::IsNullOrWhiteSpace($ExpectedGoRuntimeVersion)) { throw 'Expected Go runtime version is required.' }
    foreach ($directory in @($installFull, $outputFull)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
        $item = Get-Item -LiteralPath $directory -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Resolver directory must be a regular directory: $directory"
        }
    }
    if (Test-Path -LiteralPath $summaryFull) { throw "Parallel resolver summary is create-only: $summaryFull" }

    foreach ($toolName in $toolNames) {
        $receiptPath = Join-Path $outputFull "receipt-$toolName.json"
        if (Test-Path -LiteralPath $receiptPath) { throw "Resolver receipt is create-only: $receiptPath" }
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $powerShellFull
        $start.WorkingDirectory = Split-Path -Parent $resolverFull
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @(
                '-NoProfile', '-NonInteractive', '-File', $resolverFull,
                '-PolicyPath', $policyFull,
                '-ToolName', $toolName,
                '-Install',
                '-InstallRoot', $installFull,
                '-ExpectedGoRuntimeVersion', $ExpectedGoRuntimeVersion,
                '-RunId', $RunId,
                '-OutputPath', $receiptPath
            )) {
            [void]$start.ArgumentList.Add([string]$argument)
        }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        if (-not $process.Start()) { throw "Could not start resolver for '$toolName'." }
        $processes.Add([pscustomobject]@{
                toolName = $toolName
                receiptPath = $receiptPath
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
            $record.completed = $true
            if ($record.exitCode -ne 0 -and $null -eq $failure) {
                $failure = "Validation tool resolver '$($record.toolName)' failed with exit code $($record.exitCode): $($record.stderr)"
            }
        }
        if ($null -eq $failure -and @($processes | Where-Object { -not $_.completed }).Count -gt 0) {
            Start-Sleep -Milliseconds 50
        }
    }

    if ($null -ne $failure) {
        Stop-OwnedResolverProcesses -Records $processes
        throw $failure
    }

    foreach ($record in $processes) {
        if (-not (Test-Path -LiteralPath $record.receiptPath -PathType Leaf)) {
            throw "Validation tool resolver '$($record.toolName)' did not create its receipt."
        }
    }
    $stopwatch.Stop()
    $summary = [ordered]@{
        marker = 'atlassian-parallel-resolver-v1'
        resolutionRunId = $RunId
        toolNames = @($toolNames)
        processCount = $processes.Count
        maxObservedConcurrency = $maxObservedConcurrency
        elapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
        receipts = @($processes | ForEach-Object { [ordered]@{ toolName = $_.toolName; path = [IO.Path]::GetFullPath($_.receiptPath) } })
    }
    $summaryJson = ($summary | ConvertTo-Json -Depth 10 -Compress)
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
    if (-not $completedSuccessfully) { Stop-OwnedResolverProcesses -Records $processes }
    foreach ($record in $processes) {
        try { $record.process.Dispose() }
        catch { }
    }
}
