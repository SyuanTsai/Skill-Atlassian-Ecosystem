# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $PesterModulePath,
    [Parameter(Mandatory = $true)][string] $ExpectedPesterVersion,
    [Parameter(Mandatory = $true)][string] $TestsRoot,
    [Parameter(Mandatory = $true)][string] $WorkingRoot,
    [Parameter(Mandatory = $true)][string] $ResultPath,
    [ValidateRange(1, 16)][int] $MaxConcurrency = 12,
    [ValidateRange(1, 64)][int] $MaxCasesPerShard = 6,
    [string] $PriorityTestFilesJson = '[]',
    [string] $FineGrainedTestFilesJson = '[]',
    [string] $ExclusiveTestFilesJson = '[]'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8NoBom = [Text.UTF8Encoding]::new($false)

function Write-JsonCreateNew {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)] $Value)

    $json = ($Value | ConvertTo-Json -Depth 30 -Compress) + [Environment]::NewLine
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $writer = [IO.StreamWriter]::new($stream, $utf8NoBom)
        try { $writer.Write($json); $writer.Flush() }
        finally { $writer.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Test-OrdinalSequenceEqual {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Left,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Right
    )

    if ($Left.Count -ne $Right.Count) { return $false }
    for ($index = 0; $index -lt $Left.Count; $index++) {
        if ($Left[$index] -cne $Right[$index]) { return $false }
    }
    return $true
}

function Assert-NonNegativeInteger {
    param([Parameter(Mandatory = $true)] $Value, [Parameter(Mandatory = $true)][string] $Context)

    if (($Value -isnot [int] -and $Value -isnot [long]) -or [int64]$Value -lt 0) {
        throw "$Context must be a non-negative integer."
    }
}

function Read-WorkerResult {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)] $ExpectedTask)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Pester worker result is not a regular file: $($ExpectedTask.shardId)"
    }
    $result = [IO.File]::ReadAllText($item.FullName, [Text.UTF8Encoding]::new($false, $true)) |
        ConvertFrom-Json -Depth 30 -ErrorAction Stop
    $actualProperties = @($result.PSObject.Properties | ForEach-Object { [string]$_.Name })
    $expectedProperties = @(
        'marker', 'shardId', 'testFile', 'assignedDefinitions', 'executedDefinitions', 'executedCases',
        'TotalCount', 'PassedCount', 'SkippedCount', 'FailedCount',
        'FailedContainersCount', 'failures'
    )
    if ($actualProperties.Count -ne $expectedProperties.Count -or
        @($expectedProperties | Where-Object { $actualProperties -cnotcontains $_ }).Count -ne 0 -or
        @($actualProperties | Where-Object { $expectedProperties -cnotcontains $_ }).Count -ne 0) {
        throw "Pester worker result has an invalid property set: $($ExpectedTask.shardId)"
    }
    if ([string]$result.marker -cne 'atlassian-pester-shard-result-v3' -or
        [string]$result.shardId -cne [string]$ExpectedTask.shardId -or
        [string]$result.testFile -cne [string]$ExpectedTask.testFile -or
        $result.assignedDefinitions -isnot [array] -or $result.executedDefinitions -isnot [array] -or
        $result.executedCases -isnot [array] -or $result.failures -isnot [array]) {
        throw "Pester worker result has an invalid identity: $($ExpectedTask.shardId)"
    }
    $expectedDefinitions = [string[]]@($ExpectedTask.assignedDefinitions)
    $assignedDefinitions = [string[]]@($result.assignedDefinitions)
    if (-not (Test-OrdinalSequenceEqual -Left $assignedDefinitions -Right $expectedDefinitions)) {
        throw "Pester worker changed its assigned definition inventory: $($ExpectedTask.shardId)"
    }
    $expectedSorted = [string[]]$expectedDefinitions.Clone()
    $executedSorted = [string[]]@($result.executedDefinitions)
    [Array]::Sort($expectedSorted, [StringComparer]::Ordinal)
    [Array]::Sort($executedSorted, [StringComparer]::Ordinal)
    if (-not (Test-OrdinalSequenceEqual -Left $executedSorted -Right $expectedSorted)) {
        throw "Pester worker did not execute its exact assigned definition inventory: $($ExpectedTask.shardId)"
    }
    foreach ($name in @('TotalCount', 'PassedCount', 'SkippedCount', 'FailedCount', 'FailedContainersCount')) {
        Assert-NonNegativeInteger -Value $result.$name -Context "Pester worker $($ExpectedTask.shardId) $name"
    }
    if ([int64]$result.TotalCount -ne @($result.executedCases).Count -or
        [int64]$result.TotalCount -lt $executedSorted.Count -or
        [int64]$result.PassedCount + [int64]$result.SkippedCount + [int64]$result.FailedCount -ne [int64]$result.TotalCount) {
        throw "Pester worker counts are inconsistent: $($ExpectedTask.shardId)"
    }
    return $result
}

$moduleFull = [IO.Path]::GetFullPath($PesterModulePath)
$testsFull = [IO.Path]::GetFullPath($TestsRoot)
$candidateRoot = [IO.Path]::GetFullPath((Split-Path -Parent $testsFull))
$workingFull = [IO.Path]::GetFullPath($WorkingRoot)
$resultFull = [IO.Path]::GetFullPath($ResultPath)
if (-not (Test-Path -LiteralPath $moduleFull -PathType Leaf)) { throw 'The pinned Pester module is missing.' }
if ([string]::IsNullOrWhiteSpace($ExpectedPesterVersion)) { throw 'The expected Pester version is required.' }
if (-not (Test-Path -LiteralPath $testsFull -PathType Container)) { throw 'The Pester tests root is missing.' }
if (Test-Path -LiteralPath $resultFull) { throw 'The aggregate Pester result path already exists.' }
if (Test-Path -LiteralPath $workingFull) {
    if (-not (Test-Path -LiteralPath $workingFull -PathType Container) -or
        @(Get-ChildItem -LiteralPath $workingFull -Force).Count -ne 0) {
        throw 'The Pester working root must be a new or empty directory.'
    }
}
else { [void](New-Item -ItemType Directory -Path $workingFull -ErrorAction Stop) }
$resultParent = Split-Path -Parent $resultFull
if (-not (Test-Path -LiteralPath $resultParent -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $resultParent -ErrorAction Stop)
}

$pathComparer = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
$testFilesByRelativePath = [Collections.Generic.Dictionary[string, IO.FileInfo]]::new([StringComparer]::Ordinal)
$relativePathByFullPath = [Collections.Generic.Dictionary[string, string]]::new($pathComparer)
foreach ($file in @(Get-ChildItem -LiteralPath $testsFull -Filter '*.Tests.ps1' -File -Recurse -Force)) {
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Pester test file must not be a reparse point: $($file.FullName)" }
    $relative = [IO.Path]::GetRelativePath($testsFull, $file.FullName).Replace([IO.Path]::DirectorySeparatorChar, '/')
    if (-not $testFilesByRelativePath.TryAdd($relative, $file) -or
        -not $relativePathByFullPath.TryAdd([IO.Path]::GetFullPath($file.FullName), $relative)) {
        throw "Duplicate Pester test-file identity: $relative"
    }
}
$testFiles = [string[]]$testFilesByRelativePath.Keys
[Array]::Sort($testFiles, [StringComparer]::Ordinal)
if ($testFiles.Count -eq 0) { throw 'No Pester test files were found.' }
if ([string]::IsNullOrWhiteSpace($ExclusiveTestFilesJson)) { throw 'The exclusive Pester inventory JSON is required.' }
$exclusiveParsed = ConvertFrom-Json -InputObject $ExclusiveTestFilesJson -Depth 5 -NoEnumerate -ErrorAction Stop
if ($exclusiveParsed -isnot [array]) { throw 'The exclusive Pester inventory must be a JSON array.' }
$exclusiveTestFiles = [string[]]@($exclusiveParsed)
$exclusiveSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($relative in $exclusiveTestFiles) {
    if ([string]::IsNullOrWhiteSpace($relative) -or -not $testFilesByRelativePath.ContainsKey($relative) -or
        -not $exclusiveSet.Add($relative)) {
        throw "The exclusive Pester inventory contains an invalid or duplicate file: $relative"
    }
}
if ([string]::IsNullOrWhiteSpace($PriorityTestFilesJson)) { throw 'The priority Pester inventory JSON is required.' }
$priorityParsed = ConvertFrom-Json -InputObject $PriorityTestFilesJson -Depth 5 -NoEnumerate -ErrorAction Stop
if ($priorityParsed -isnot [array]) { throw 'The priority Pester inventory must be a JSON array.' }
$priorityTestFiles = [string[]]@($priorityParsed)
$prioritySet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($relative in $priorityTestFiles) {
    if ([string]::IsNullOrWhiteSpace($relative) -or -not $testFilesByRelativePath.ContainsKey($relative) -or
        $exclusiveSet.Contains($relative) -or -not $prioritySet.Add($relative)) {
        throw "The priority Pester inventory contains an invalid, overlapping, or duplicate file: $relative"
    }
}
$fineGrainedParsed = ConvertFrom-Json -InputObject $FineGrainedTestFilesJson -Depth 5 -NoEnumerate -ErrorAction Stop
if ($fineGrainedParsed -isnot [array]) { throw 'The fine-grained Pester inventory must be a JSON array.' }
$fineGrainedTestFiles = [string[]]@($fineGrainedParsed)
$fineGrainedSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($relative in $fineGrainedTestFiles) {
    if ([string]::IsNullOrWhiteSpace($relative) -or -not $testFilesByRelativePath.ContainsKey($relative) -or
        $exclusiveSet.Contains($relative) -or -not $fineGrainedSet.Add($relative)) {
        throw "The fine-grained Pester inventory contains an invalid, exclusive, or duplicate file: $relative"
    }
}
Import-Module -Name $moduleFull -Force -ErrorAction Stop
$loadedPester = Get-Module Pester | Select-Object -First 1
if ($null -eq $loadedPester -or [string]$loadedPester.Version -cne $ExpectedPesterVersion) {
    throw 'The resolved Pester module identity was not loaded for discovery.'
}
$discoveryConfiguration = New-PesterConfiguration
$discoveryConfiguration.Run.Path = $testsFull
$discoveryConfiguration.Run.SkipRun = $true
$discoveryConfiguration.Run.PassThru = $true
$discoveryConfiguration.Output.Verbosity = 'None'
$previousErrorActionPreference = $ErrorActionPreference
Push-Location -LiteralPath $candidateRoot
try {
    $ErrorActionPreference = 'Continue'
    $discovery = Invoke-Pester -Configuration $discoveryConfiguration 3>$null 6>$null
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
    Pop-Location
}
if ($null -eq $discovery -or $discovery.FailedContainers.Count -ne 0) { throw 'Pester discovery failed.' }

$definitionsByFile = [Collections.Generic.Dictionary[string, Collections.Generic.List[object]]]::new([StringComparer]::Ordinal)
$definitionSetsByFile = [Collections.Generic.Dictionary[string, Collections.Generic.HashSet[string]]]::new([StringComparer]::Ordinal)
$selectorSetsByFile = [Collections.Generic.Dictionary[string, Collections.Generic.HashSet[string]]]::new([StringComparer]::Ordinal)
$duplicateSelectorFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($relative in $testFiles) {
    $definitionsByFile.Add($relative, [Collections.Generic.List[object]]::new())
    $definitionSetsByFile.Add($relative, [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal))
    $selectorSetsByFile.Add($relative, [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal))
}
foreach ($test in @($discovery.Tests)) {
    $sourcePath = [string]$test.ScriptBlock.File
    if ([string]::IsNullOrWhiteSpace($sourcePath)) { throw 'Pester discovery produced a test without a source file.' }
    $relative = ''
    if (-not $relativePathByFullPath.TryGetValue([IO.Path]::GetFullPath($sourcePath), [ref]$relative)) {
        throw "Pester discovery produced a test outside the exact file inventory: $sourcePath"
    }
    $selector = [string]($test.Path -join '.')
    $startLine = [int]$test.StartLine
    if ([string]::IsNullOrWhiteSpace($selector) -or $startLine -le 0) {
        throw "Pester discovery produced an invalid test definition: $relative"
    }
    $definitionId = "$selector#L$startLine"
    if (-not $definitionSetsByFile[$relative].Add($definitionId)) {
        # Pester may expose one discovery object per data row even though all rows
        # belong to the same source definition. The definition is scheduled once.
        continue
    }
    if (-not $selectorSetsByFile[$relative].Add($selector)) { [void]$duplicateSelectorFiles.Add($relative) }
    $definitionsByFile[$relative].Add([pscustomobject]@{ id = $definitionId; selector = $selector; startLine = $startLine })
}
$discoveredDefinitionCount = 0
$plans = [Collections.Generic.List[object]]::new()
foreach ($relative in $testFiles) {
    $definitions = [object[]]@($definitionsByFile[$relative] | Sort-Object -Property startLine, id)
    if ($definitions.Count -eq 0) { throw "Pester discovery produced no definitions for a test file: $relative" }
    $discoveredDefinitionCount += $definitions.Count
    $useFilter = -not $duplicateSelectorFiles.Contains($relative) -and -not $exclusiveSet.Contains($relative)
    $shardCount = if (-not $useFilter) { 1 } elseif ($fineGrainedSet.Contains($relative)) { $definitions.Count } else { [int][Math]::Ceiling($definitions.Count / [double]$MaxCasesPerShard) }
    $groups = @()
    for ($index = 0; $index -lt $shardCount; $index++) { $groups += ,([Collections.Generic.List[object]]::new()) }
    for ($index = 0; $index -lt $definitions.Count; $index++) { $groups[$index % $shardCount].Add($definitions[$index]) }
    $plans.Add([pscustomobject]@{ testFile = $relative; definitionCount = $definitions.Count; groups = $groups; useFilter = $useFilter })
}
$orderedPlans = [object[]]@($plans | Sort-Object -Property @{ Expression = 'definitionCount'; Descending = $true }, @{ Expression = 'testFile'; Descending = $false })
$tasks = [Collections.Generic.List[object]]::new()
foreach ($plan in $orderedPlans) {
    for ($shardIndex = 0; $shardIndex -lt $plan.groups.Count; $shardIndex++) {
        $group = [object[]]$plan.groups[$shardIndex].ToArray()
        $tasks.Add([pscustomobject]@{
            shardId = "$($plan.testFile)::case-$('{0:D2}' -f ($shardIndex + 1))"
            testFile = [string]$plan.testFile
            assignedDefinitions = [string[]]@($group | ForEach-Object { [string]$_.id })
            filterSelectors = if ([bool]$plan.useFilter) { [string[]]@($group | ForEach-Object { [string]$_.selector }) } else { [string[]]@() }
            isRecycleToken = $false
            requiresFreshWorker = $exclusiveSet.Contains([string]$plan.testFile)
            exitWorkerAfterTask = $exclusiveSet.Contains([string]$plan.testFile)
        })
    }
}

$workerScript = {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $modulePath = [string]$env:SYP304_PESTER_MODULE
    $expectedVersion = [string]$env:SYP304_PESTER_VERSION
    $queueRoot = [string]$env:SYP304_PESTER_QUEUE
    $workerRoot = [string]$env:SYP304_PESTER_WORKER_ROOT
    $completedTaskCount = 0
    if (-not (Test-Path -LiteralPath $queueRoot -PathType Container) -or
        -not (Test-Path -LiteralPath $workerRoot -PathType Container)) {
        throw 'The Pester worker queue or worker root is missing.'
    }
    Import-Module -Name $modulePath -Force -ErrorAction Stop
    $loaded = Get-Module Pester | Select-Object -First 1
    if ($null -eq $loaded -or [string]$loaded.Version -cne $expectedVersion) { throw 'The resolved Pester module identity was not loaded.' }
    while ($true) {
        $claimedPath = $null
        $taskJson = $null
        $available = [string[]][IO.Directory]::GetFiles($queueRoot, 'task-*.json', [IO.SearchOption]::TopDirectoryOnly)
        [Array]::Sort($available, [StringComparer]::Ordinal)
        foreach ($sourcePath in $available) {
            $destinationPath = Join-Path $workerRoot ("claim-$([IO.Path]::GetFileName($sourcePath))")
            try {
                $taskJson = [IO.File]::ReadAllText($sourcePath, [Text.UTF8Encoding]::new($false, $true))
                $candidateTask = $taskJson | ConvertFrom-Json -Depth 20 -ErrorAction Stop
                if ($candidateTask.requiresFreshWorker -isnot [bool]) { throw 'The Pester shard has an invalid fresh-worker flag.' }
                if ([bool]$candidateTask.requiresFreshWorker -and $completedTaskCount -gt 0) { break }
                [IO.File]::Move($sourcePath, $destinationPath)
                $claimedPath = $destinationPath
                break
            }
            catch [IO.IOException] { continue }
        }
        if ($null -eq $claimedPath) { break }
        try {
            $task = $taskJson | ConvertFrom-Json -Depth 20 -ErrorAction Stop
        if ($task.isRecycleToken -isnot [bool]) { throw 'The Pester shard has an invalid recycle-token flag.' }
        if ($task.exitWorkerAfterTask -isnot [bool]) { throw 'The Pester shard has an invalid worker-lifecycle flag.' }
        $exitWorkerAfterTask = [bool]$task.exitWorkerAfterTask
        if (-not [bool]$task.isRecycleToken) {
        $assignedDefinitions = [string[]]@($task.assignedDefinitions)
        $filterSelectors = [string[]]@($task.filterSelectors)
        if ($assignedDefinitions.Count -eq 0) { throw 'The Pester shard has an empty definition inventory.' }
        $configuration = New-PesterConfiguration
        $configuration.Run.Path = [string]$task.testPath
        $configuration.Run.PassThru = $true
        $configuration.Output.Verbosity = 'None'
        if ($filterSelectors.Count -gt 0) {
            $configuration.Filter.FullName = [string[]]@($filterSelectors | ForEach-Object { [WildcardPattern]::Escape($_) })
        }
        try {
            # Pester repository tests were authored for PowerShell's default
            # non-strict property-access semantics. Keep scheduler validation
            # strict without leaking StrictMode into the test script scopes.
            Set-StrictMode -Off
            $ErrorActionPreference = 'Continue'
            $run = Invoke-Pester -Configuration $configuration 3>$null 6>$null
        }
        finally {
            $ErrorActionPreference = 'Stop'
            Set-StrictMode -Version Latest
        }
        if ($null -eq $run) { throw 'Pester did not produce a run result.' }
        $executedTests = [object[]]@($run.Tests | Where-Object { [string]$_.Result -cne 'NotRun' })
        $executedCases = [string[]]@($executedTests | ForEach-Object { [string]$_.ExpandedPath })
        $executedDefinitionSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($test in $executedTests) {
            $selector = [string]($test.Path -join '.')
            $startLine = [int]$test.StartLine
            if ([string]::IsNullOrWhiteSpace($selector) -or $startLine -le 0) { throw 'Pester produced an invalid executed definition.' }
            [void]$executedDefinitionSet.Add("$selector#L$startLine")
        }
        $executedDefinitions = [string[]]@($executedDefinitionSet)
        $expectedSorted = [string[]]$assignedDefinitions.Clone()
        $executedSorted = [string[]]$executedDefinitions.Clone()
        [Array]::Sort($expectedSorted, [StringComparer]::Ordinal)
        [Array]::Sort($executedSorted, [StringComparer]::Ordinal)
        if (($expectedSorted -join "`n") -cne ($executedSorted -join "`n")) { throw 'Pester did not execute the exact assigned definition inventory.' }
        $containerFailures = @($run.FailedContainers | ForEach-Object {
            $detail = @($_.ErrorRecord | ForEach-Object { $_.Exception.Message }) -join ' | '
            if ($detail.Length -gt 800) { $detail = $detail.Substring(0, 800) }
            "Container $($_.Name)`: $detail"
        })
        $failures = @($run.Failed | ForEach-Object {
            $name = if ([string]::IsNullOrWhiteSpace([string]$_.ExpandedName)) { [string]$_.Name } else { [string]$_.ExpandedName }
            "$name`: $(@($_.ErrorRecord | ForEach-Object { [string]$_ }) -join ' | ')"
        })
        $value = [ordered]@{
            marker = 'atlassian-pester-shard-result-v3'; shardId = [string]$task.shardId; testFile = [string]$task.testFile
            assignedDefinitions = @($assignedDefinitions); executedDefinitions = @($executedDefinitions); executedCases = @($executedCases)
            TotalCount = [int64]$executedCases.Count; PassedCount = [int64]$run.PassedCount
            SkippedCount = [int64]$run.SkippedCount; FailedCount = [int64]$run.FailedCount
            FailedContainersCount = [int64]$run.FailedContainers.Count
            failures = @($containerFailures) + @($failures)
        }
        [IO.File]::WriteAllText([string]$task.resultPath, (($value | ConvertTo-Json -Depth 20 -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        }
        }
        finally {
            Remove-Item -LiteralPath $claimedPath -Force -ErrorAction SilentlyContinue
        }
        $completedTaskCount++
        if ($exitWorkerAfterTask) { break }
    }
}
$encodedWorkerScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("& {`n$($workerScript.ToString())`n}"))
$powerShellPath = (Get-Process -Id $PID).Path
$completed = [Collections.Generic.List[object]]::new()
$workerCount = 0
$maxObservedConcurrency = 0

function Invoke-WorkerPhases {
    param(
        [Parameter(Mandatory = $true)][object[]] $PhaseSpecifications
    )

    $contexts = [Collections.Generic.List[object]]::new()
    foreach ($specification in $PhaseSpecifications) {
        $phaseTasks = [object[]]@($specification.tasks)
        if ($phaseTasks.Count -eq 0) { continue }
        $phaseName = [string]$specification.name
        $phaseRoot = Join-Path $workingFull $phaseName
        $queueRoot = Join-Path $phaseRoot 'queue'
        $resultsRoot = Join-Path $phaseRoot 'results'
        [void](New-Item -ItemType Directory -Path $queueRoot -ErrorAction Stop)
        [void](New-Item -ItemType Directory -Path $resultsRoot -ErrorAction Stop)
        $mappings = [Collections.Generic.List[object]]::new()
        for ($taskIndex = 0; $taskIndex -lt $phaseTasks.Count; $taskIndex++) {
            $task = $phaseTasks[$taskIndex]
            if ([bool]$task.isRecycleToken) {
                $payload = [ordered]@{
                    shardId = [string]$task.shardId
                    testFile = ''
                    testPath = ''
                    assignedDefinitions = [string[]]@()
                    filterSelectors = [string[]]@()
                    isRecycleToken = $true
                    requiresFreshWorker = $false
                    exitWorkerAfterTask = $true
                    resultPath = ''
                }
            }
            else {
                $resultPath = Join-Path $resultsRoot ('shard-{0:D4}.json' -f $taskIndex)
                $mappings.Add([pscustomobject]@{ task = $task; resultPath = $resultPath })
                $payload = [ordered]@{
                    shardId = [string]$task.shardId
                    testFile = [string]$task.testFile
                    testPath = $testFilesByRelativePath[[string]$task.testFile].FullName
                    assignedDefinitions = [string[]]@($task.assignedDefinitions)
                    filterSelectors = [string[]]@($task.filterSelectors)
                    isRecycleToken = $false
                    requiresFreshWorker = [bool]$task.requiresFreshWorker
                    exitWorkerAfterTask = [bool]$task.exitWorkerAfterTask
                    resultPath = $resultPath
                }
            }
            Write-JsonCreateNew -Path (Join-Path $queueRoot ('task-{0:D4}.json' -f $taskIndex)) -Value $payload
        }
        $contexts.Add([pscustomobject]@{
            name = $phaseName
            phaseRoot = $phaseRoot
            queueRoot = $queueRoot
            mappings = [object[]]$mappings.ToArray()
            deferInitialWorkers = [bool]$specification.deferInitialWorkers
            running = [Collections.Generic.List[object]]::new()
            launchState = [pscustomobject]@{ nextWorkerIndex = 0 }
        })
    }

    $startWorker = {
        param([Parameter(Mandatory = $true)] $Context)
        $workerIndex = [int]$Context.launchState.nextWorkerIndex
        $Context.launchState.nextWorkerIndex++
        $workerRoot = Join-Path $Context.phaseRoot ('worker-{0:D4}' -f $workerIndex)
        [void](New-Item -ItemType Directory -Path $workerRoot -ErrorAction Stop)
        $stdoutPath = Join-Path $workerRoot 'stdout.txt'
        $stderrPath = Join-Path $workerRoot 'stderr.txt'
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $powerShellPath
        $start.WorkingDirectory = $candidateRoot
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.Environment['SYP304_PESTER_MODULE'] = $moduleFull
        $start.Environment['SYP304_PESTER_VERSION'] = $ExpectedPesterVersion
        $start.Environment['SYP304_PESTER_QUEUE'] = $Context.queueRoot
        $start.Environment['SYP304_PESTER_WORKER_ROOT'] = $workerRoot
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedWorkerScript)) { [void]$start.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        [void]$process.Start()
        $Context.running.Add([pscustomobject]@{
            process = $process; stdoutTask = $process.StandardOutput.ReadToEndAsync(); stderrTask = $process.StandardError.ReadToEndAsync()
            stdoutPath = $stdoutPath; stderrPath = $stderrPath
        })
    }
    try {
        $phaseMaxObservedConcurrency = 0
        foreach ($context in $contexts) {
            if ([bool]$context.deferInitialWorkers) { continue }
            $runningCount = [int](($contexts | ForEach-Object { $_.running.Count } | Measure-Object -Sum).Sum)
            $availableSlots = $MaxConcurrency - $runningCount
            $queuedTaskCount = @([IO.Directory]::GetFiles($context.queueRoot, 'task-*.json', [IO.SearchOption]::TopDirectoryOnly)).Count
            $initialWorkerCount = [Math]::Min($availableSlots, $queuedTaskCount)
            for ($workerIndex = 0; $workerIndex -lt $initialWorkerCount; $workerIndex++) {
                & $startWorker $context
            }
        }
        $phaseMaxObservedConcurrency = [int](($contexts | ForEach-Object { $_.running.Count } | Measure-Object -Sum).Sum)
        while (@($contexts | Where-Object { $_.running.Count -gt 0 }).Count -gt 0) {
            $madeProgress = $false
            foreach ($context in $contexts) {
                $finished = @($context.running | Where-Object { $_.process.HasExited })
                foreach ($worker in $finished) {
                    $madeProgress = $true
                    $worker.process.WaitForExit()
                    $stdout = $worker.stdoutTask.GetAwaiter().GetResult()
                    $stderr = $worker.stderrTask.GetAwaiter().GetResult()
                    [IO.File]::WriteAllText($worker.stdoutPath, $stdout, $utf8NoBom)
                    [IO.File]::WriteAllText($worker.stderrPath, $stderr, $utf8NoBom)
                    if ($worker.process.ExitCode -ne 0) {
                        $diagnostic = if ([string]::IsNullOrWhiteSpace($stderr)) { $stdout } else { $stderr }
                        if ($diagnostic.Length -gt 1200) { $diagnostic = $diagnostic.Substring(0, 1200) }
                        throw "Pester worker process failed with exit code $($worker.process.ExitCode): $diagnostic"
                    }
                    [void]$context.running.Remove($worker)
                    $worker.process.Dispose()
                }
            }
            if ($madeProgress) {
                $runningCount = [int](($contexts | ForEach-Object { $_.running.Count } | Measure-Object -Sum).Sum)
                $availableSlots = $MaxConcurrency - $runningCount
                foreach ($context in $contexts) {
                    if ($availableSlots -le 0) { break }
                    $queuedTaskCount = @([IO.Directory]::GetFiles($context.queueRoot, 'task-*.json', [IO.SearchOption]::TopDirectoryOnly)).Count
                    $uncoveredTaskCount = [Math]::Max(0, $queuedTaskCount - $context.running.Count)
                    $replacementCount = [Math]::Min($availableSlots, $uncoveredTaskCount)
                    for ($replacementIndex = 0; $replacementIndex -lt $replacementCount; $replacementIndex++) {
                        & $startWorker $context
                    }
                    if ($replacementCount -gt 0) {
                        $availableSlots -= $replacementCount
                    }
                }
            }
            $runningCount = [int](($contexts | ForEach-Object { $_.running.Count } | Measure-Object -Sum).Sum)
            $phaseMaxObservedConcurrency = [Math]::Max($phaseMaxObservedConcurrency, $runningCount)
            if (-not $madeProgress) { Start-Sleep -Milliseconds 50 }
        }
    }
    finally {
        foreach ($context in $contexts) {
            foreach ($worker in @($context.running)) {
                try {
                    if (-not $worker.process.HasExited) { $worker.process.Kill($true) }
                    $worker.process.WaitForExit()
                }
                catch { }
                finally { $worker.process.Dispose() }
            }
        }
    }
    $phaseResults = [Collections.Generic.List[object]]::new()
    $phaseWorkerTotal = 0
    foreach ($context in $contexts) {
        if (@([IO.Directory]::GetFiles($context.queueRoot, 'task-*.json', [IO.SearchOption]::TopDirectoryOnly)).Count -ne 0) {
            throw "Pester phase left unclaimed tasks: $($context.name)"
        }
        foreach ($mapping in $context.mappings) {
            if (-not (Test-Path -LiteralPath $mapping.resultPath -PathType Leaf)) {
                throw "Pester worker did not produce a shard result: $($mapping.task.shardId)"
            }
            $phaseResults.Add((Read-WorkerResult -Path $mapping.resultPath -ExpectedTask $mapping.task))
        }
        $phaseWorkerTotal += [int]$context.launchState.nextWorkerIndex
    }
    return [pscustomobject]@{
        results = [object[]]$phaseResults.ToArray()
        workerCount = $phaseWorkerTotal
        maxObservedConcurrency = $phaseMaxObservedConcurrency
    }
}

$priorityTasks = [object[]]@($tasks | Where-Object { $prioritySet.Contains([string]$_.testFile) })
$exclusiveTasks = [object[]]@($tasks | Where-Object { $exclusiveSet.Contains([string]$_.testFile) })
$parallelTasks = [object[]]@($tasks | Where-Object {
    -not $exclusiveSet.Contains([string]$_.testFile) -and -not $prioritySet.Contains([string]$_.testFile)
})
$regularTasks = [object[]]@($priorityTasks) + [object[]]@($parallelTasks)
$regularPhaseTasks = [Collections.Generic.List[object]]::new()
foreach ($task in $priorityTasks) { $regularPhaseTasks.Add($task) }
$recycleWorkerCount = if ($regularTasks.Count -gt 0) { [Math]::Min($exclusiveTasks.Count, $MaxConcurrency) } else { 0 }
for ($recycleIndex = 0; $recycleIndex -lt $recycleWorkerCount; $recycleIndex++) {
    $regularPhaseTasks.Add([pscustomobject]@{
        shardId = "worker-recycle::token-$('{0:D2}' -f ($recycleIndex + 1))"
        testFile = ''
        assignedDefinitions = [string[]]@()
        filterSelectors = [string[]]@()
        isRecycleToken = $true
        requiresFreshWorker = $false
        exitWorkerAfterTask = $true
    })
}
foreach ($task in $parallelTasks) { $regularPhaseTasks.Add($task) }
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
try {
    $phaseSpecifications = [Collections.Generic.List[object]]::new()
    if ($exclusiveTasks.Count -gt 0) {
        $phaseSpecifications.Add([pscustomobject]@{
            name = 'phase-0001-exclusive'
            tasks = $exclusiveTasks
            deferInitialWorkers = $regularTasks.Count -gt 0
        })
    }
    if ($regularPhaseTasks.Count -gt 0) {
        $phaseSpecifications.Add([pscustomobject]@{
            name = 'phase-0002-bounded'
            tasks = [object[]]$regularPhaseTasks.ToArray()
            deferInitialWorkers = $false
        })
    }
    $phase = Invoke-WorkerPhases -PhaseSpecifications ([object[]]$phaseSpecifications.ToArray())
    foreach ($result in $phase.results) { $completed.Add($result) }
    $workerCount += $phase.workerCount
    $maxObservedConcurrency = [Math]::Max($maxObservedConcurrency, $phase.maxObservedConcurrency)
}
finally { $stopwatch.Stop() }

$expectedTaskIds = [string[]]@($tasks | ForEach-Object { [string]$_.shardId })
$completedTaskIds = [string[]]@($completed | ForEach-Object { [string]$_.shardId })
[Array]::Sort($expectedTaskIds, [StringComparer]::Ordinal)
[Array]::Sort($completedTaskIds, [StringComparer]::Ordinal)
if (-not (Test-OrdinalSequenceEqual -Left $completedTaskIds -Right $expectedTaskIds)) { throw 'Pester worker results do not cover the exact shard inventory.' }
foreach ($relative in $testFiles) {
    $expectedDefinitions = [string[]]@($definitionsByFile[$relative] | ForEach-Object { [string]$_.id })
    $executedDefinitions = [string[]]@($completed | Where-Object { [string]$_.testFile -ceq $relative } | ForEach-Object { [string[]]@($_.executedDefinitions) })
    [Array]::Sort($expectedDefinitions, [StringComparer]::Ordinal)
    [Array]::Sort($executedDefinitions, [StringComparer]::Ordinal)
    if (-not (Test-OrdinalSequenceEqual -Left $executedDefinitions -Right $expectedDefinitions)) {
        throw "Pester shards do not cover the exact discovered definition inventory: $relative"
    }
}

$failures = @($completed | ForEach-Object { @($_.failures) })
$shardedFileCount = @($plans | Where-Object { $_.groups.Count -gt 1 }).Count
$aggregate = [ordered]@{
    marker = 'atlassian-pester-result-v3'; testFileCount = $testFiles.Count; testFiles = $testFiles
    discoveredDefinitionCount = $discoveredDefinitionCount; shardedFileCount = $shardedFileCount
    duplicateSelectorFileCount = $duplicateSelectorFiles.Count
    priorityTestFiles = $priorityTestFiles; priorityShardCount = $priorityTasks.Count; priorityScheduling = 'queue-front'
    fineGrainedTestFiles = $fineGrainedTestFiles
    exclusiveTestFiles = $exclusiveTestFiles; exclusiveShardCount = $exclusiveTasks.Count
    schedulerMode = 'persistent-work-stealing'
    shardCount = $completed.Count; workerCount = $workerCount; maxCasesPerShard = $MaxCasesPerShard
    maxConcurrency = $MaxConcurrency; maxObservedConcurrency = $maxObservedConcurrency
    elapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
    TotalCount = [int64](($completed | Measure-Object -Property TotalCount -Sum).Sum)
    PassedCount = [int64](($completed | Measure-Object -Property PassedCount -Sum).Sum)
    SkippedCount = [int64](($completed | Measure-Object -Property SkippedCount -Sum).Sum)
    FailedCount = [int64](($completed | Measure-Object -Property FailedCount -Sum).Sum)
    FailedContainersCount = [int64](($completed | Measure-Object -Property FailedContainersCount -Sum).Sum)
    failures = $failures
}
if ($aggregate.TotalCount -lt $discoveredDefinitionCount -or
    $aggregate.PassedCount + $aggregate.SkippedCount + $aggregate.FailedCount -ne $aggregate.TotalCount) {
    throw 'Aggregate Pester counts are invalid.'
}
Write-JsonCreateNew -Path $resultFull -Value $aggregate
