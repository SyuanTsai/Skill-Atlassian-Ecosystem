# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [string] $RepositoryRoot,
    [string] $ArtifactsRoot = $(
        if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP }
        else { [IO.Path]::GetTempPath() }
    ),
    [string] $AuthorityArchivePath,
    [string] $BaseCommit,
    [string] $ExpectedGoRuntimeVersion = $env:STANDARD_GO_RUNTIME_VERSION,
    [string] $OutputPath,
    [switch] $EnableSemanticScan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-NoDuplicateJsonProperties {
    param([Parameter(Mandatory = $true)][System.Text.Json.JsonElement] $Element, [string] $Context = '$')
    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) { throw "$Context contains duplicate JSON property '$($property.Name)'." }
            Assert-NoDuplicateJsonProperties -Element $property.Value -Context "$Context.$($property.Name)"
        }
    }
    elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            Assert-NoDuplicateJsonProperties -Element $item -Context "$Context[$index]"
            $index++
        }
    }
}

function Read-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Context
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Context is missing: $Path" }
    try {
        $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true))
        $document = [System.Text.Json.JsonDocument]::Parse($text)
        try { Assert-NoDuplicateJsonProperties -Element $document.RootElement -Context $Context }
        finally { $document.Dispose() }
        return $text | ConvertFrom-Json -Depth 100
    }
    catch { throw "$Context is not valid unambiguous UTF-8 JSON: $($_.Exception.Message)" }
}

function Assert-Sha256 {
    param($Value, [string] $Context)
    if ($Value -isnot [string] -or [string]$Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Context must be a lowercase SHA-256 value."
    }
}

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Context
    )
    if ($Object -isnot [pscustomobject] -or $null -eq $Object.PSObject.Properties[$Name]) {
        throw "$Context is missing required property '$Name'."
    }
    return ,$Object.PSObject.Properties[$Name].Value
}

function Get-ValidationSecurityAction {
    param(
        [Parameter(Mandatory = $true)] $Policy,
        [Parameter(Mandatory = $true)][string] $Severity,
        [Parameter(Mandatory = $true)][string] $Context
    )
    $matches = @($Policy.security.severity | Where-Object { $_.level -ceq $Severity })
    if ($matches.Count -ne 1 -or $matches[0].action -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$matches[0].action)) {
        throw "$Context has no unique central action for severity '$Severity'."
    }
    return [string]$matches[0].action
}

function ConvertTo-ValidationSecurityFinding {
    param(
        [Parameter(Mandatory = $true)] $Policy,
        [Parameter(Mandatory = $true)][string] $ReportedSeverity,
        [Parameter(Mandatory = $true)][string] $Stage,
        [Parameter(Mandatory = $true)][string] $SkillId,
        [Parameter(Mandatory = $true)] $Issue
    )
    $severityAliases = [ordered]@{
        critical = 'critical'
        high = 'high'
        medium = 'medium'
        low = 'low'
        informational = 'informational'
        info = 'informational'
    }
    $severityKey = $ReportedSeverity.ToLowerInvariant()
    if (-not $severityAliases.Contains($severityKey)) {
        throw "$Stage returned unsupported severity '$ReportedSeverity' for '$SkillId'."
    }
    $severity = [string]$severityAliases[$severityKey]
    $action = Get-ValidationSecurityAction -Policy $Policy -Severity $severity -Context $Stage
    [pscustomobject][ordered]@{
        stage = $Stage
        skillId = $SkillId
        severity = $severity
        action = $action
        issue = $Issue
    }
}

function Test-PathEqual {
    param([string] $Left, [string] $Right)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return [IO.Path]::GetFullPath($Left).Equals([IO.Path]::GetFullPath($Right), $comparison)
}

function Test-PathWithinOrEqual {
    param([string] $Path, [string] $Root)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return $fullPath.Equals($fullRoot, $comparison) -or
        $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, $comparison)
}

function Assert-NoReparseAncestors {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Context,
        [string] $Boundary
    )
    $currentPath = [IO.Path]::GetFullPath($Path)
    $boundaryPath = if ([string]::IsNullOrWhiteSpace($Boundary)) {
        ''
    }
    else {
        [IO.Path]::GetFullPath($Boundary)
    }
    while (-not [string]::IsNullOrWhiteSpace($currentPath)) {
        $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Context is backed by a reparse point: $currentPath"
        }
        if ([string]::IsNullOrWhiteSpace($boundaryPath) -or (Test-PathEqual -Left $currentPath -Right $boundaryPath)) {
            break
        }
        $parentPath = Split-Path -Parent $currentPath
        if ([string]::IsNullOrWhiteSpace($parentPath) -or (Test-PathEqual -Left $parentPath -Right $currentPath)) { break }
        $currentPath = $parentPath
    }
    if (-not [string]::IsNullOrWhiteSpace($boundaryPath) -and
        -not (Test-PathWithinOrEqual -Path $Path -Root $boundaryPath)) {
        throw "$Context is outside its controlled boundary: $Path"
    }
}

function Get-FileByteSha256 {
    param(
        [Parameter(Mandatory = $true)][string] $Path
    )
    $bytes = [IO.File]::ReadAllBytes($Path)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($hasher.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $hasher.Dispose()
    }
}

function Get-DescendantProcessIds {
    param(
        [Parameter(Mandatory = $true)][int] $RootProcessId
    )
    $processes = @()
    if ($IsWindows) {
        try {
            $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{
                    processId = [int]$_.ProcessId
                    parentProcessId = [int]$_.ParentProcessId
                }
            })
        }
        catch {
            throw "Could not enumerate Windows child processes for process-tree cleanup: $($_.Exception.Message)"
        }
    }
    else {
        foreach ($entry in @(Get-ChildItem -LiteralPath '/proc' -Directory -ErrorAction SilentlyContinue)) {
            if ([string]$entry.Name -notmatch '^[0-9]+$') { continue }
            try {
                $stat = [IO.File]::ReadAllText((Join-Path $entry.FullName 'stat'))
            }
            catch {
                continue
            }
            if ($stat -cmatch '^[0-9]+\s+\(.*\)\s+\S+\s+(?<parentProcessId>[0-9]+)\s') {
                $processes += [pscustomobject]@{
                    processId = [int]$entry.Name
                    parentProcessId = [int]$Matches.parentProcessId
                }
            }
        }
    }

    $frontier = @($RootProcessId)
    $descendantIds = [Collections.Generic.List[int]]::new()
    while ($frontier.Count -gt 0) {
        $next = [Collections.Generic.List[int]]::new()
        foreach ($process in $processes) {
            $processId = [int]$process.processId
            if ($frontier -contains [int]$process.parentProcessId -and
                -not $descendantIds.Contains($processId)) {
                [void]$descendantIds.Add($processId)
                [void]$next.Add($processId)
            }
        }
        $frontier = @($next.ToArray())
    }
    return @($descendantIds.ToArray())
}

function Get-UnixProcessGroupId {
    param(
        [Parameter(Mandatory = $true)][int] $ProcessId
    )
    if ($IsWindows) { return 0 }
    if ($ProcessId -le 0) { throw 'Unix process-group inspection requires a positive process id.' }
    $statPath = Join-Path '/proc' "$ProcessId/stat"
    try {
        $stat = [IO.File]::ReadAllText($statPath)
    }
    catch {
        throw "Could not inspect Unix process group for process ${ProcessId}: $($_.Exception.Message)"
    }
    if ($stat -notmatch '^[0-9]+\s+\(.*\)\s+\S+\s+[0-9]+\s+(?<processGroupId>[0-9]+)\s') {
        throw "Could not parse Unix process group for process $ProcessId."
    }
    return [int]$Matches.processGroupId
}

function Get-UnixProcessGroupProcessIds {
    param(
        [Parameter(Mandatory = $true)][int] $ProcessGroupId
    )
    if ($IsWindows) { return @() }
    if ($ProcessGroupId -le 0) { throw 'Unix process-group enumeration requires a positive process-group id.' }
    $members = [Collections.Generic.List[int]]::new()
    foreach ($entry in @(Get-ChildItem -LiteralPath '/proc' -Directory -ErrorAction SilentlyContinue)) {
        if ([string]$entry.Name -notmatch '^[0-9]+$') { continue }
        try {
            $stat = [IO.File]::ReadAllText((Join-Path $entry.FullName 'stat'))
        }
        catch {
            continue
        }
        if ($stat -cmatch '^[0-9]+\s+\(.*\)\s+\S+\s+[0-9]+\s+(?<processGroupId>[0-9]+)\s' -and
            [int]$Matches.processGroupId -eq $ProcessGroupId) {
            [void]$members.Add([int]$entry.Name)
        }
    }
    return @($members.ToArray())
}

function Test-ProcessIdExists {
    param(
        [Parameter(Mandatory = $true)][int] $ProcessId
    )
    if ($ProcessId -le 0) { return $false }
    if ($IsWindows) {
        try {
            Get-Process -Id $ProcessId -ErrorAction Stop | Out-Null
            return $true
        }
        catch {
            return $false
        }
    }
    return Test-Path -LiteralPath (Join-Path '/proc' ([string]$ProcessId)) -PathType Container
}

function Add-ObservedProcessIds {
    param(
        [Parameter(Mandatory = $true)][int] $RootProcessId,
        [Parameter(Mandatory = $true)] $ObservedProcessIds,
        [Parameter()][int] $ProcessGroupId = 0
    )
    foreach ($processId in @(Get-DescendantProcessIds -RootProcessId $RootProcessId)) {
        if ($processId -ne $RootProcessId) { [void]$ObservedProcessIds.Add([int]$processId) }
    }
    if (-not $IsWindows -and $ProcessGroupId -gt 0) {
        foreach ($processId in @(Get-UnixProcessGroupProcessIds -ProcessGroupId $ProcessGroupId)) {
            if ($processId -ne $RootProcessId) { [void]$ObservedProcessIds.Add([int]$processId) }
        }
    }
}

function Stop-ProcessTree {
    param(
        [Parameter(Mandatory = $true)][int] $RootProcessId,
        [Parameter()][int] $ProcessGroupId = 0,
        [Parameter()][AllowEmptyCollection()][int[]] $ObservedProcessIds = @()
    )
    if ($RootProcessId -le 0) { throw 'Process-tree cleanup requires a positive root process id.' }
    $taskKillPath = $null
    $killPath = $null
    if ($IsWindows) {
        $taskKillPath = Join-Path $env:SystemRoot 'System32/taskkill.exe'
        if (-not (Test-Path -LiteralPath $taskKillPath -PathType Leaf)) {
            throw "Windows process-tree cleanup command is missing: $taskKillPath"
        }
    }
    else {
        $killCommand = Get-Command kill -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $killPath = [IO.Path]::GetFullPath([string]$killCommand.Path)
        if ($ProcessGroupId -le 0) {
            $ProcessGroupId = Get-UnixProcessGroupId -ProcessId $RootProcessId
        }
        if ($ProcessGroupId -le 0) {
            throw 'Unix process-tree cleanup requires a positive process-group id.'
        }
    }

    for ($round = 0; $round -lt 3; $round++) {
        $descendants = @(Get-DescendantProcessIds -RootProcessId $RootProcessId)
        $groupMembers = if ($IsWindows) { @() } else { @(Get-UnixProcessGroupProcessIds -ProcessGroupId $ProcessGroupId) }
        $targets = @($descendants + $groupMembers + $ObservedProcessIds |
            Where-Object { [int]$_ -gt 0 -and [int]$_ -ne $RootProcessId } |
            Sort-Object -Unique -Descending)
        if ($IsWindows) {
            foreach ($processId in $targets) {
                & $taskKillPath /PID $processId /F 2>$null | Out-Null
            }
            & $taskKillPath /PID $RootProcessId /T /F 2>$null | Out-Null
        }
        else {
            $signal = if ($round -eq 2) { '-KILL' } else { '-TERM' }
            & $killPath $signal "-$ProcessGroupId" 2>$null | Out-Null
            foreach ($processId in $targets) {
                & $killPath $signal ([string]$processId) 2>$null | Out-Null
            }
        }
        Start-Sleep -Milliseconds 100
        $remaining = @(Get-DescendantProcessIds -RootProcessId $RootProcessId)
        $remainingObserved = @($ObservedProcessIds | Where-Object { Test-ProcessIdExists -ProcessId ([int]$_) })
        $remainingGroupMembers = if ($IsWindows) { @() } else { @(Get-UnixProcessGroupProcessIds -ProcessGroupId $ProcessGroupId) }
        if ($remaining.Count -eq 0 -and $remainingObserved.Count -eq 0 -and $remainingGroupMembers.Count -eq 0) { return }
    }
    throw "Could not terminate the complete candidate process boundary rooted at process $RootProcessId."
}

function Get-RunnerCommandFileSnapshot {
    param(
        [Parameter(Mandatory = $true)][string[]] $Names
    )
    $snapshot = [ordered]@{}
    foreach ($name in $Names) {
        $path = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if ([string]::IsNullOrWhiteSpace($path)) {
            $snapshot[$name] = [pscustomobject][ordered]@{
                path = ''
                exists = $false
                sha256 = ''
            }
            continue
        }
        $fullPath = [IO.Path]::GetFullPath($path)
        $exists = Test-Path -LiteralPath $fullPath -PathType Leaf
        $hash = ''
        if ($exists) {
            Assert-NoReparseAncestors -Path $fullPath -Context "Protected $name command file"
            $hash = Get-FileByteSha256 -Path $fullPath
        }
        $snapshot[$name] = [pscustomobject][ordered]@{
            path = $fullPath
            exists = [bool]$exists
            sha256 = $hash
        }
    }
    return $snapshot
}

function Assert-RunnerCommandFilesUnchanged {
    param(
        [Parameter(Mandatory = $true)] $Before,
        [Parameter(Mandatory = $true)][string[]] $Names
    )
    foreach ($name in $Names) {
        $beforeEntry = $Before[$name]
        $path = [string]$beforeEntry.path
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $exists = Test-Path -LiteralPath $path -PathType Leaf
        if ([bool]$beforeEntry.exists -ne [bool]$exists) {
            throw "Protected $name command file was created or removed by candidate code."
        }
        if ($exists) {
            Assert-NoReparseAncestors -Path $path -Context "Protected $name command file"
            $actualHash = Get-FileByteSha256 -Path $path
            if ($actualHash -cne [string]$beforeEntry.sha256) {
                throw "Protected $name command file changed while candidate code was running."
            }
        }
    }
}

function ConvertTo-NativeProcessArgumentString {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]] $Arguments
    )
    $rendered = foreach ($argument in $Arguments) {
        $value = [string]$argument
        $builder = [Text.StringBuilder]::new()
        [void]$builder.Append([char]34)
        $backslashCount = 0
        for ($index = 0; $index -lt $value.Length; $index++) {
            $character = $value[$index]
            if ($character -eq [char]92) {
                $backslashCount++
                continue
            }
            if ($character -eq [char]34) {
                [void]$builder.Append([char]92, ($backslashCount * 2) + 1)
                [void]$builder.Append([char]34)
                $backslashCount = 0
                continue
            }
            if ($backslashCount -gt 0) {
                [void]$builder.Append([char]92, $backslashCount)
                $backslashCount = 0
            }
            [void]$builder.Append($character)
        }
        if ($backslashCount -gt 0) {
            [void]$builder.Append([char]92, $backslashCount * 2)
        }
        [void]$builder.Append([char]34)
        $builder.ToString()
    }
    return ($rendered -join ' ')
}
function Resolve-ReportedFilePath {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $SkillRoot,
        [Parameter(Mandatory = $true)][string[]] $ExpectedInventoryPaths,
        [Parameter(Mandatory = $true)][string] $Context
    )
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { throw "$Context must be a non-empty path string." }
    $candidate = [string]$Value
    if ($candidate -cmatch '^file:') {
        $uri = $null
        if (-not [Uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$uri) -or -not $uri.IsFile) {
            throw "$Context must be a local Skill path."
        }
        $candidate = $uri.LocalPath
    }
    elseif (-not [IO.Path]::IsPathRooted($candidate) -and $candidate -cmatch '^[a-zA-Z][a-zA-Z0-9+.-]*:') {
        throw "$Context must be a local Skill path."
    }
    if (-not [IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path $SkillRoot $candidate }
    $fullPath = Assert-PathWithinRoot -Path $candidate -Root $SkillRoot -Context $Context
    foreach ($relativePath in $ExpectedInventoryPaths) {
        if (Test-PathEqual -Left $fullPath -Right (Join-Path $SkillRoot $relativePath)) { return $fullPath }
    }
    throw "$Context does not identify a file in the candidate-bound Skill inventory: $fullPath"
}

function Assert-SkillSpectorReport {
    param($Report, [string] $SkillRoot, [string] $SkillId, [string[]] $ExpectedInventoryPaths)
    $executionSuccessful = Get-RequiredProperty -Object $Report -Name 'execution_successful' -Context 'SkillSpector report'
    $completeness = Get-RequiredProperty -Object $Report -Name 'analysis_completeness' -Context 'SkillSpector report'
    $coverage = Get-RequiredProperty -Object $completeness -Name 'coverage_percent' -Context 'SkillSpector completeness'
    $numericTypes = @([byte], [sbyte], [int16], [uint16], [int], [uint32], [long], [uint64], [single], [double], [decimal])
    $coverageIsNumeric = $false
    foreach ($type in $numericTypes) { if ($coverage -is $type) { $coverageIsNumeric = $true; break } }
    if ($executionSuccessful -isnot [bool] -or -not $executionSuccessful -or
        (Get-RequiredProperty -Object $completeness -Name 'execution_successful' -Context 'SkillSpector completeness') -isnot [bool] -or
        -not (Get-RequiredProperty -Object $completeness -Name 'execution_successful' -Context 'SkillSpector completeness') -or
        (Get-RequiredProperty -Object $completeness -Name 'is_complete' -Context 'SkillSpector completeness') -isnot [bool] -or
        -not (Get-RequiredProperty -Object $completeness -Name 'is_complete' -Context 'SkillSpector completeness') -or
        (Get-RequiredProperty -Object $completeness -Name 'status' -Context 'SkillSpector completeness') -isnot [string] -or
        (Get-RequiredProperty -Object $completeness -Name 'status' -Context 'SkillSpector completeness') -cne 'complete' -or
        -not $coverageIsNumeric -or $coverage -ne 100) {
        throw "SkillSpector did not prove complete static analysis for '$SkillId'."
    }
    foreach ($name in @('ledger_exceptions', 'scope_exclusions', 'limitations')) {
        $items = Get-RequiredProperty -Object $completeness -Name $name -Context 'SkillSpector completeness'
        if ($items -isnot [array] -or @($items).Count -ne 0) {
            $detail = ConvertTo-Json -InputObject $items -Depth 12 -Compress
            throw "SkillSpector reported incomplete '$name' evidence for '$SkillId': $detail"
        }
    }
    $skill = Get-RequiredProperty -Object $Report -Name 'skill' -Context 'SkillSpector report'
    $reportedName = Get-RequiredProperty -Object $skill -Name 'name' -Context 'SkillSpector skill identity'
    $reportedSource = Get-RequiredProperty -Object $skill -Name 'source' -Context 'SkillSpector skill identity'
    if ($reportedName -isnot [string] -or $reportedName -cne $SkillId -or
        $reportedSource -isnot [string] -or -not (Test-PathEqual -Left $reportedSource -Right $SkillRoot)) {
        throw "SkillSpector report identity does not match '$SkillId'."
    }
    $components = Get-RequiredProperty -Object $Report -Name 'components' -Context 'SkillSpector report'
    if ($components -isnot [array] -or @($components).Count -ne $ExpectedInventoryPaths.Count) {
        throw "SkillSpector did not cover the exact candidate-bound inventory for '$SkillId'."
    }
    $observed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($component in @($components)) {
        $path = Get-RequiredProperty -Object $component -Name 'path' -Context 'SkillSpector component'
        if ($path -isnot [string] -or -not ($ExpectedInventoryPaths -ccontains $path) -or -not $observed.Add($path)) {
            throw "SkillSpector did not cover the exact candidate-bound inventory for '$SkillId'."
        }
    }
    $issues = Get-RequiredProperty -Object $Report -Name 'issues' -Context 'SkillSpector report'
    if ($issues -isnot [array]) { throw "SkillSpector issues must be an array for '$SkillId'." }
    return @($issues)
}

function Assert-SkillValidatorReport {
    param($Report, [string] $SkillRoot, [string[]] $ExpectedInventoryPaths, [string] $SkillId)
    $skillDirectory = Get-RequiredProperty -Object $Report -Name 'skill_dir' -Context 'skill-validator report'
    $passed = Get-RequiredProperty -Object $Report -Name 'passed' -Context 'skill-validator report'
    $errors = Get-RequiredProperty -Object $Report -Name 'errors' -Context 'skill-validator report'
    $warnings = Get-RequiredProperty -Object $Report -Name 'warnings' -Context 'skill-validator report'
    $results = Get-RequiredProperty -Object $Report -Name 'results' -Context 'skill-validator report'
    if ($skillDirectory -isnot [string] -or -not (Test-PathEqual -Left $skillDirectory -Right $SkillRoot) -or
        $passed -isnot [bool] -or -not $passed -or
        ($errors -isnot [int] -and $errors -isnot [long]) -or [int64]$errors -ne 0 -or
        ($warnings -isnot [int] -and $warnings -isnot [long]) -or [int64]$warnings -ne 0 -or
        $results -isnot [array] -or @($results).Count -le 0) {
        throw "skill-validator did not produce a clean candidate-bound report for '$SkillId'."
    }
    foreach ($result in @($results)) {
        $level = Get-RequiredProperty -Object $result -Name 'level' -Context 'skill-validator result'
        $category = Get-RequiredProperty -Object $result -Name 'category' -Context 'skill-validator result'
        $message = Get-RequiredProperty -Object $result -Name 'message' -Context 'skill-validator result'
        if ($level -isnot [string] -or $level -cnotin @('pass', 'info', 'warning', 'error') -or $level -in @('warning', 'error') -or
            $category -isnot [string] -or [string]::IsNullOrWhiteSpace($category) -or
            $message -isnot [string] -or [string]::IsNullOrWhiteSpace($message)) {
            throw "skill-validator returned a malformed or blocking result for '$SkillId'."
        }
        if ($null -ne $result.PSObject.Properties['file']) {
            [void](Resolve-ReportedFilePath -Value $result.file -SkillRoot $SkillRoot -ExpectedInventoryPaths $ExpectedInventoryPaths -Context 'skill-validator result file')
        }
        if ($null -ne $result.PSObject.Properties['line'] -and
            (($result.line -isnot [int] -and $result.line -isnot [long]) -or [int64]$result.line -le 0)) {
            throw "skill-validator returned an invalid line for '$SkillId'."
        }
    }
}

function Assert-SkillToolsReport {
    param($Report, [string] $SkillRoot, [string[]] $ExpectedInventoryPaths, [string] $SkillId)
    $version = Get-RequiredProperty -Object $Report -Name 'version' -Context 'skill-tools SARIF'
    $runs = Get-RequiredProperty -Object $Report -Name 'runs' -Context 'skill-tools SARIF'
    if ($version -isnot [string] -or $version -cne '2.1.0' -or $runs -isnot [array] -or @($runs).Count -ne 1) {
        throw "skill-tools did not produce SARIF 2.1.0 for '$SkillId'."
    }
    $run = $runs[0]
    $driver = Get-RequiredProperty -Object (Get-RequiredProperty -Object $run -Name 'tool' -Context 'skill-tools SARIF run') -Name 'driver' -Context 'skill-tools SARIF tool'
    $driverName = Get-RequiredProperty -Object $driver -Name 'name' -Context 'skill-tools SARIF driver'
    $rules = Get-RequiredProperty -Object $driver -Name 'rules' -Context 'skill-tools SARIF driver'
    $results = Get-RequiredProperty -Object $run -Name 'results' -Context 'skill-tools SARIF run'
    if ($driverName -isnot [string] -or $driverName -cne 'skill-tools' -or $rules -isnot [array] -or
        $results -isnot [array]) {
        throw "skill-tools SARIF is incomplete for '$SkillId'."
    }
    $ruleById = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($rule in @($rules)) {
        $ruleId = Get-RequiredProperty -Object $rule -Name 'id' -Context 'skill-tools SARIF rule'
        if ($ruleId -isnot [string] -or [string]::IsNullOrWhiteSpace($ruleId) -or $ruleById.ContainsKey($ruleId)) {
            throw "skill-tools SARIF rule metadata is malformed for '$SkillId'."
        }
        $ruleById.Add($ruleId, $rule)
    }
    foreach ($result in @($results)) {
        $ruleId = Get-RequiredProperty -Object $result -Name 'ruleId' -Context 'skill-tools SARIF result'
        if ($ruleId -isnot [string] -or -not $ruleById.ContainsKey($ruleId)) { throw "skill-tools SARIF references an unknown rule for '$SkillId'." }
        $effectiveLevel = if ($null -ne $result.PSObject.Properties['level']) { $result.level } else {
            $configuration = Get-RequiredProperty -Object $ruleById[$ruleId] -Name 'defaultConfiguration' -Context 'skill-tools SARIF rule'
            Get-RequiredProperty -Object $configuration -Name 'level' -Context 'skill-tools SARIF rule default'
        }
        if ($effectiveLevel -isnot [string] -or $effectiveLevel -cnotin @('none', 'note', 'warning', 'error') -or $effectiveLevel -ceq 'error') {
            throw "skill-tools SARIF contains a malformed or error-level result for '$SkillId'."
        }
        $message = Get-RequiredProperty -Object $result -Name 'message' -Context 'skill-tools SARIF result'
        $messageText = Get-RequiredProperty -Object $message -Name 'text' -Context 'skill-tools SARIF message'
        $locations = Get-RequiredProperty -Object $result -Name 'locations' -Context 'skill-tools SARIF result'
        if ($messageText -isnot [string] -or [string]::IsNullOrWhiteSpace($messageText) -or $locations -isnot [array] -or @($locations).Count -le 0) {
            throw "skill-tools SARIF lacks candidate-bound evidence for '$SkillId'."
        }
        foreach ($location in @($locations)) {
            $physical = Get-RequiredProperty -Object $location -Name 'physicalLocation' -Context 'skill-tools SARIF location'
            $artifact = Get-RequiredProperty -Object $physical -Name 'artifactLocation' -Context 'skill-tools SARIF physical location'
            $uri = Get-RequiredProperty -Object $artifact -Name 'uri' -Context 'skill-tools SARIF artifact location'
            [void](Resolve-ReportedFilePath -Value $uri -SkillRoot $SkillRoot -ExpectedInventoryPaths $ExpectedInventoryPaths -Context 'skill-tools SARIF artifact location')
        }
    }
}

function Assert-PathWithinRoot {
    param([string] $Path, [string] $Root, [string] $Context)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $fullPath.StartsWith($fullRoot, $comparison)) { throw "$Context escapes its controlled root: $fullPath" }
    return $fullPath
}

function Assert-ReceiptFile {
    param(
        [Parameter(Mandatory = $true)] $Receipt,
        [Parameter(Mandatory = $true)][string] $PathProperty,
        [Parameter(Mandatory = $true)][string] $HashProperty,
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [Parameter(Mandatory = $true)][string] $Context
    )
    $pathValue = $Receipt.PSObject.Properties[$PathProperty]
    $hashValue = $Receipt.PSObject.Properties[$HashProperty]
    if ($null -eq $pathValue -or $pathValue.Value -isnot [string] -or
        $null -eq $hashValue -or $hashValue.Value -isnot [string]) {
        throw "$Context receipt does not provide $PathProperty/$HashProperty."
    }
    Assert-Sha256 -Value ([string]$hashValue.Value) -Context "$Context receipt file hash"
    $path = Assert-PathWithinRoot -Path ([string]$pathValue.Value) -Root $InstallRoot -Context $Context
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$Context installed file is missing: $path" }
    Assert-NoReparseAncestors -Path $path -Context "$Context installed file" -Boundary $InstallRoot
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
    if ($actual -cne [string]$hashValue.Value) { throw "$Context installed file changed after resolution." }
    return $path
}

function Assert-ExternalReceiptFile {
    param(
        [Parameter(Mandatory = $true)] $Receipt,
        [Parameter(Mandatory = $true)][string] $PathProperty,
        [Parameter(Mandatory = $true)][string] $HashProperty,
        [Parameter(Mandatory = $true)][string] $Context
    )
    $pathValue = $Receipt.PSObject.Properties[$PathProperty]
    $hashValue = $Receipt.PSObject.Properties[$HashProperty]
    if ($null -eq $pathValue -or $pathValue.Value -isnot [string] -or
        $null -eq $hashValue -or $hashValue.Value -isnot [string]) {
        throw "$Context receipt does not provide $PathProperty/$HashProperty."
    }
    if (-not [IO.Path]::IsPathRooted([string]$pathValue.Value)) {
        throw "$Context receipt path must be absolute."
    }
    Assert-Sha256 -Value ([string]$hashValue.Value) -Context "$Context receipt file hash"
    $path = [IO.Path]::GetFullPath([string]$pathValue.Value)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$Context runtime file is missing: $path" }
    Assert-NoReparseAncestors -Path $path -Context "$Context runtime file"
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
    if ($actual -cne [string]$hashValue.Value) { throw "$Context runtime file changed after resolution." }
    return $path
}

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory = $true)][string] $Command,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Arguments,
        [Parameter(Mandatory = $true)][string] $Context,
        [Parameter(Mandatory = $true)][string] $DiagnosticRoot,
        [Parameter()][AllowNull()][string] $StandardInput,
        [Parameter()][switch] $IsolateRunnerCommandFiles,
        [Parameter()][switch] $TerminateProcessTree,
        [Parameter()][switch] $ProtectRunnerCommandFiles
    )
    if (-not (Test-Path -LiteralPath $Command -PathType Leaf)) { throw "$Context executable is missing: $Command" }
    if ($ProtectRunnerCommandFiles -and -not $IsolateRunnerCommandFiles) {
        throw "$Context cannot protect runner command files without isolation."
    }
    $stderrPath = Join-Path $DiagnosticRoot ("stderr-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    $runnerCommandFileNames = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        @('GITHUB_ENV', 'GITHUB_PATH', 'GITHUB_OUTPUT', 'GITHUB_STATE', 'GITHUB_STEP_SUMMARY', 'BASH_ENV')
    }
    else {
        @(
            'GITHUB_ENV', 'GITHUB_PATH', 'GITHUB_OUTPUT', 'GITHUB_STATE', 'GITHUB_STEP_SUMMARY', 'BASH_ENV',
            'github_env', 'github_path', 'github_output', 'github_state', 'github_step_summary', 'bash_env'
        )
    }
    $previousRunnerCommandFileValues = [ordered]@{}
    $runnerCommandFileSnapshot = $null
    $runnerCommandFileIsolationStarted = $false
    $childProcess = $null
    $childProcessId = 0
    $childProcessGroupId = 0
    $observedDescendantProcessIds = [Collections.Generic.HashSet[int]]::new()
    $processTreeStopped = $false
    try {
        if ($ProtectRunnerCommandFiles) {
            $runnerCommandFileSnapshot = Get-RunnerCommandFileSnapshot -Names $runnerCommandFileNames
        }
        if ($IsolateRunnerCommandFiles) {
            $runnerCommandFileIsolationStarted = $true
            foreach ($name in $runnerCommandFileNames) {
                $previousRunnerCommandFileValues[$name] = [Environment]::GetEnvironmentVariable(
                    $name,
                    [EnvironmentVariableTarget]::Process
                )
                $isolatedPath = Join-Path $DiagnosticRoot ("isolated-{0}-{1}.txt" -f $name.ToLowerInvariant(), [guid]::NewGuid().ToString('N'))
                $isolatedStream = [IO.File]::Open(
                    $isolatedPath,
                    [IO.FileMode]::CreateNew,
                    [IO.FileAccess]::Write,
                    [IO.FileShare]::Read
                )
                try {
                    $isolatedStream.Flush($true)
                }
                finally {
                    $isolatedStream.Dispose()
                }
                Assert-NoReparseAncestors -Path $isolatedPath -Context "Isolated $name command file" -Boundary $DiagnosticRoot
                [Environment]::SetEnvironmentVariable($name, $isolatedPath, [EnvironmentVariableTarget]::Process)
            }
        }
        if ($TerminateProcessTree) {
            $nativeCommand = $Command
            $nativeArguments = @($Arguments)
            if (-not $IsWindows) {
                $setsidCommand = Get-Command setsid -CommandType Application -ErrorAction Stop | Select-Object -First 1
                $setsidPath = [IO.Path]::GetFullPath([string]$setsidCommand.Path)
                if (-not (Test-Path -LiteralPath $setsidPath -PathType Leaf)) {
                    throw "$Context process-group launcher is missing: $setsidPath"
                }
                Assert-NoReparseAncestors -Path $setsidPath -Context "$Context process-group launcher"
                $nativeCommand = $setsidPath
                $nativeArguments = @($Command) + @($Arguments)
            }
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $nativeCommand
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            if ($PSBoundParameters.ContainsKey('StandardInput')) {
                $startInfo.RedirectStandardInput = $true
            }
            $argumentListProperty = $startInfo.PSObject.Properties['ArgumentList']
            if ($null -ne $argumentListProperty) {
                foreach ($argument in $nativeArguments) {
                    [void]$startInfo.ArgumentList.Add([string]$argument)
                }
            }
            else {
                $startInfo.Arguments = ConvertTo-NativeProcessArgumentString -Arguments $nativeArguments
            }
            $startInfo.WorkingDirectory = [string](Get-Location).Path
            $childProcess = [Diagnostics.Process]::new()
            $childProcess.StartInfo = $startInfo
            if (-not $childProcess.Start()) { throw "$Context process could not be started: $Command" }
            $childProcessId = $childProcess.Id
            if (-not $IsWindows) {
                $childProcessGroupId = Get-UnixProcessGroupId -ProcessId $childProcessId
                $parentProcessGroupId = Get-UnixProcessGroupId -ProcessId $PID
                if ($childProcessGroupId -ne $childProcessId -or $childProcessGroupId -eq $parentProcessGroupId) {
                    throw "$Context process was not placed in a dedicated Unix process group."
                }
            }
            $stdoutTask = $childProcess.StandardOutput.ReadToEndAsync()
            $stderrTask = $childProcess.StandardError.ReadToEndAsync()
            if ($PSBoundParameters.ContainsKey('StandardInput')) {
                $childProcess.StandardInput.Write($StandardInput)
                $childProcess.StandardInput.Close()
            }
            Add-ObservedProcessIds -RootProcessId $childProcessId -ObservedProcessIds $observedDescendantProcessIds -ProcessGroupId $childProcessGroupId
            while (-not $childProcess.HasExited) {
                [void]$childProcess.WaitForExit(100)
                Add-ObservedProcessIds -RootProcessId $childProcessId -ObservedProcessIds $observedDescendantProcessIds -ProcessGroupId $childProcessGroupId
            }
            Add-ObservedProcessIds -RootProcessId $childProcessId -ObservedProcessIds $observedDescendantProcessIds -ProcessGroupId $childProcessGroupId
            Stop-ProcessTree -RootProcessId $childProcessId -ProcessGroupId $childProcessGroupId -ObservedProcessIds @($observedDescendantProcessIds)
            $processTreeStopped = $true
            if (-not $childProcess.WaitForExit(5000)) {
                throw "$Context process did not terminate after process-boundary cleanup."
            }
            if (-not $stdoutTask.Wait(5000) -or -not $stderrTask.Wait(5000)) {
                throw "$Context left redirected output handles open after process-tree cleanup."
            }
            $stdoutText = $stdoutTask.GetAwaiter().GetResult()
            $stderrText = $stderrTask.GetAwaiter().GetResult()
            $exitCode = $childProcess.ExitCode
        }
        else {
            $stdout = if ($PSBoundParameters.ContainsKey('StandardInput')) {
                $StandardInput | & $Command @Arguments 2> $stderrPath
            }
            else {
                @(& $Command @Arguments 2> $stderrPath)
            }
            $exitCode = $LASTEXITCODE
            $stdoutText = ($stdout | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
            $stderrText = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8 } else { '' }
        }
        if ($ProtectRunnerCommandFiles) {
            Assert-RunnerCommandFilesUnchanged -Before $runnerCommandFileSnapshot -Names $runnerCommandFileNames
        }
        if ($exitCode -ne 0) {
            throw ("$Context exited with code $exitCode." + [Environment]::NewLine +
                "STDOUT:" + [Environment]::NewLine + $stdoutText + [Environment]::NewLine +
                "STDERR:" + [Environment]::NewLine + $stderrText)
        }
        return $stdoutText
    }
    finally {
        try {
            if ($TerminateProcessTree -and $null -ne $childProcess -and $childProcessId -gt 0 -and -not $processTreeStopped) {
                Stop-ProcessTree -RootProcessId $childProcessId -ProcessGroupId $childProcessGroupId -ObservedProcessIds @($observedDescendantProcessIds)
                $processTreeStopped = $true
            }
        }
        finally {
            if ($runnerCommandFileIsolationStarted) {
                foreach ($name in $runnerCommandFileNames) {
                    if ($previousRunnerCommandFileValues.Contains($name)) {
                        [Environment]::SetEnvironmentVariable(
                            $name,
                            $previousRunnerCommandFileValues[$name],
                            [EnvironmentVariableTarget]::Process
                        )
                    }
                }
            }
            if ($null -ne $childProcess) { $childProcess.Dispose() }
            if (Test-Path -LiteralPath $stderrPath) { Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Test-SecurityRelevantSkillChange {
    param([string] $GitPath, [string] $RepositoryRoot, [string] $BaseCommit)
    if ([string]::IsNullOrWhiteSpace($BaseCommit)) {
        # Without an immutable comparison base, fail closed instead of skipping the semantic scan.
        return $true
    }
    $gitOutput = [string]((& $GitPath -C $RepositoryRoot diff --find-renames=100% --name-status -z "$BaseCommit...HEAD") -join '')
    if ($LASTEXITCODE -ne 0) { throw "Could not compare candidate with base commit '$BaseCommit'." }
    $tokens = @($gitOutput.Split([char]0) | Where-Object { $_ -ne '' })
    for ($index = 0; $index -lt $tokens.Count; $index++) {
        $status = [string]$tokens[$index]
        if ($status -cmatch '^R[0-9]{3}$' -or $status -cmatch '^C[0-9]{3}$') {
            if ($index + 2 -ge $tokens.Count) { throw 'Git returned an incomplete rename/copy status record.' }
            $oldPath = [string]$tokens[$index + 1]
            $newPath = [string]$tokens[$index + 2]
            if ($status -ceq 'R100' -and $oldPath -clike '.agents/skills/*' -and $newPath -clike 'skills/*') {
                $index += 2
                continue
            }
            if ($oldPath -clike 'skills/*' -or $newPath -clike 'skills/*') { return $true }
            $index += 2
            continue
        }
        if ($index + 1 -ge $tokens.Count) { throw 'Git returned an incomplete path status record.' }
        if ([string]$tokens[$index + 1] -clike 'skills/*') { return $true }
        $index++
    }
    return $false
}

$repoRoot = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
}
else { [IO.Path]::GetFullPath($RepositoryRoot) }
$supervisorRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$repositoryValidatorPath = Join-Path $supervisorRoot 'scripts/Test-Repository.ps1'
if (-not (Test-Path -LiteralPath $repositoryValidatorPath -PathType Leaf)) {
    throw "Trusted repository validator is missing: $repositoryValidatorPath"
}
Assert-NoReparseAncestors -Path $repositoryValidatorPath -Context 'Trusted repository validator' -Boundary $supervisorRoot
$gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
$gitPath = [IO.Path]::GetFullPath([string]$gitCommand.Path)

$candidateCommit = ([string](@(& $gitPath -C $repoRoot rev-parse HEAD 2>$null) | Select-Object -First 1)).Trim()
if ($LASTEXITCODE -ne 0 -or $candidateCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'Candidate must be an immutable Git commit.' }
$candidateTree = ([string](@(& $gitPath -C $repoRoot rev-parse "$candidateCommit^{tree}" 2>$null) | Select-Object -First 1)).Trim()
if ($LASTEXITCODE -ne 0 -or $candidateTree -cnotmatch '^[0-9a-f]{40}$') { throw 'Candidate must be bound to one immutable Git tree.' }
$dirty = @(& $gitPath -C $repoRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) {
    throw 'Canonical validation requires a clean candidate commit; commit or remove every tracked/untracked change first.'
}
$resolvedBaseCommit = ''
if (-not [string]::IsNullOrWhiteSpace($BaseCommit)) {
    $baseRevision = "$BaseCommit^{commit}"
    $baseOutput = @(& $gitPath -C $repoRoot rev-parse --verify --end-of-options $baseRevision 2>$null)
    if ($LASTEXITCODE -ne 0 -or $baseOutput.Count -ne 1 -or [string]$baseOutput[0] -cnotmatch '^[0-9a-f]{40}$') {
        throw "Base commit '$BaseCommit' does not resolve to one immutable commit."
    }
    $resolvedBaseCommit = ([string]$baseOutput[0]).Trim()
    & $gitPath -C $repoRoot merge-base --is-ancestor $resolvedBaseCommit $candidateCommit
    if ($LASTEXITCODE -ne 0 -or $resolvedBaseCommit -ceq $candidateCommit) {
        throw 'Base commit must be a distinct ancestor of the immutable candidate.'
    }
    $BaseCommit = $resolvedBaseCommit
}

$adapterPath = Join-Path $repoRoot 'config/standard-v1.json'
$adapter = Read-JsonFile -Path $adapterPath -Context 'Standard v1 repository adapter'
if ($adapter.schemaVersion -ne 1 -or $adapter.standardVersion -cne 'v1' -or $adapter.deviations -cne 'None') {
    throw 'Standard v1 repository adapter identity or deviation contract is invalid.'
}
if ($adapter.authority.repository -cne 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' -or
    $adapter.authority.commit -notmatch '^[0-9a-f]{40}$') {
    throw 'Standard authority repository or immutable commit is invalid.'
}
$expectedArchiveUrl = "https://codeload.github.com/SyuanTsai/SyuanTsai-AI-Instructions/zip/$($adapter.authority.commit)"
if ($adapter.authority.archiveUrl -cne $expectedArchiveUrl) { throw 'Standard authority archive URL is not the exact approved immutable codeload path.' }
Assert-Sha256 -Value $adapter.authority.archiveSha256 -Context 'Authority archive identity'

$artifactsRootPath = [IO.Path]::GetFullPath($ArtifactsRoot)
if (Test-PathWithinOrEqual -Path $artifactsRootPath -Root $repoRoot) {
    throw 'Artifacts root must be outside the candidate repository.'
}
[void](New-Item -ItemType Directory -Path $artifactsRootPath -Force)
$artifactsItem = Get-Item -LiteralPath $artifactsRootPath -Force
if (-not $artifactsItem.PSIsContainer -or ($artifactsItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Artifacts root must be a regular non-reparse directory.'
}
Assert-NoReparseAncestors -Path $artifactsRootPath -Context 'Artifacts root' -Boundary $artifactsRootPath
$runId = [guid]::NewGuid().ToString('N')
# Keep the on-disk prefix short enough for Windows venv and wheel paths; evidence retains the full run ID.
$runRoot = Join-Path $artifactsRootPath "sgv1-$($runId.Substring(0, 12))"
$authorityExtractRoot = Join-Path $runRoot 'authority'
$installRoot = Join-Path $runRoot 'tools'
if (Test-Path -LiteralPath $runRoot) { throw 'Run-owned artifacts path unexpectedly already exists.' }
[void](New-Item -ItemType Directory -Path $runRoot)
Assert-NoReparseAncestors -Path $runRoot -Context 'Run-owned artifacts path' -Boundary $artifactsRootPath
[void](New-Item -ItemType Directory -Path $authorityExtractRoot -Force)
[void](New-Item -ItemType Directory -Path $installRoot -Force)

# Bind the exact package/file inventory before any scanner is acquired or executed.
$integrityReportPath = Join-Path $runRoot 'candidate-integrity.json'
$integrityJson = & $repositoryValidatorPath -RepositoryRoot $repoRoot -OutputPath $integrityReportPath | Select-Object -Last 1
$integrityReport = $integrityJson | ConvertFrom-Json -Depth 100
if ($integrityReport.result -cne 'passed' -or [int]$integrityReport.activeSkillCount -le 0) {
    throw 'Candidate integrity verification did not bind a non-empty active Skill inventory.'
}
$skillIds = @($integrityReport.skills | ForEach-Object { [string]$_.skillId })
$skillsRoot = Join-Path $repoRoot 'skills'

$archivePath = Join-Path $runRoot 'authority.zip'
if ([string]::IsNullOrWhiteSpace($AuthorityArchivePath)) {
    Invoke-WebRequest -Uri $adapter.authority.archiveUrl -OutFile $archivePath
}
else {
    $suppliedArchive = [IO.Path]::GetFullPath($AuthorityArchivePath)
    if (-not (Test-Path -LiteralPath $suppliedArchive -PathType Leaf)) { throw 'Supplied authority archive does not exist.' }
    Copy-Item -LiteralPath $suppliedArchive -Destination $archivePath
}
$archiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
if ($archiveHash -cne [string]$adapter.authority.archiveSha256) { throw 'Authority archive SHA-256 does not match the approved immutable snapshot.' }
Expand-Archive -LiteralPath $archivePath -DestinationPath $authorityExtractRoot
$authorityRoots = @(Get-ChildItem -LiteralPath $authorityExtractRoot -Directory)
if ($authorityRoots.Count -ne 1 -or ($authorityRoots[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Authority archive must contain exactly one non-reparse repository root.'
}
$authorityRoot = $authorityRoots[0].FullName

$authorityFiles = @()
$seenAuthorityPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($entry in @($adapter.authority.files)) {
    if ($entry.path -isnot [string] -or [string]$entry.path -cnotmatch '^[a-zA-Z0-9._/-]+$' -or
        [string]$entry.path -match '(^|/)\.\.?(/|$)' -or -not $seenAuthorityPaths.Add([string]$entry.path)) {
        throw 'Authority file inventory contains an unsafe or duplicate path.'
    }
    Assert-Sha256 -Value $entry.sha256 -Context "Authority file '$($entry.path)' identity"
    $authorityFile = Assert-PathWithinRoot -Path (Join-Path $authorityRoot ([string]$entry.path)) -Root $authorityRoot -Context 'Authority file'
    if (-not (Test-Path -LiteralPath $authorityFile -PathType Leaf)) { throw "Authority file is missing: $($entry.path)" }
    $fileHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $authorityFile).Hash.ToLowerInvariant()
    if ($fileHash -cne [string]$entry.sha256) { throw "Authority file identity mismatch: $($entry.path)" }
    $authorityFiles += [pscustomobject][ordered]@{ path = [string]$entry.path; sha256 = $fileHash }
}
$requiredAuthorityFiles = @(
    'docs/standards/README.md',
    'docs/standards/managed-skill-lifecycle.md',
    'docs/standards/schemas/managed-skill-lifecycle-v1.schema.json',
    'docs/standards/skill-repository-standard.md',
    'docs/standards/skill-repository-review-matrix.md',
    'docs/standards/upstream-interoperability.md',
    'docs/standards/validation-security-gate.json',
    'docs/standards/validation-toolchain.json',
    'docs/standards/schemas/validation-security-gate-v1.schema.json',
    'docs/standards/schemas/source-inventory-v2.schema.json',
    'docs/standards/schemas/openai-agent-metadata.schema.json',
    'scripts/Invoke-StandardAuthorityGate.ps1',
    'scripts/Resolve-StandardValidationTool.ps1',
    'scripts/Resolve-PythonWheelClosure.py'
)
foreach ($required in $requiredAuthorityFiles) {
    if (-not $seenAuthorityPaths.Contains($required)) { throw "Authority inventory does not bind required file '$required'." }
}

$standardPath = Join-Path $authorityRoot 'docs/standards/skill-repository-standard.md'
$standardText = Get-Content -LiteralPath $standardPath -Raw -Encoding UTF8
if ($standardText -cnotmatch '(?m)^# Agent Skill Repository Standard v1$' -or $standardText -cnotmatch '(?m)^Status: \*\*Normative\*\*$') {
    throw 'Verified authority snapshot does not identify normative Standard v1.'
}
$resolverPath = Join-Path $authorityRoot 'scripts/Resolve-StandardValidationTool.ps1'
$policyPath = Join-Path $authorityRoot 'docs/standards/validation-toolchain.json'
$authorityGatePath = Join-Path $authorityRoot 'scripts/Invoke-StandardAuthorityGate.ps1'
$validationSecurityGatePath = Join-Path $authorityRoot 'docs/standards/validation-security-gate.json'
. $authorityGatePath -DefineFunctionsOnly
$validationSecurityGate = Assert-AuthorityValidationSecurityGate `
    -Policy (Read-JsonFile -Path $validationSecurityGatePath -Context 'Validation/security gate policy')
$validationSecurityGatePolicySha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $validationSecurityGatePath).Hash.ToLowerInvariant()

$policyReceiptPath = Join-Path $runRoot 'policy.json'
& $resolverPath -PolicyPath $policyPath -ValidatePolicyOnly -OutputPath $policyReceiptPath | Out-Host
$policyReceipt = Read-JsonFile -Path $policyReceiptPath -Context 'Validation tool policy receipt'
if ($policyReceipt.policy -cne 'latest-stable-per-validation-run' -or
    $policyReceipt.sourceTrust.enforcement -cne 'exact-approved-source' -or
    $policyReceipt.recordResolvedIdentityWhenAvailable -ne $true) {
    throw 'Validation tool policy receipt does not preserve the central trust contract.'
}

$expectedSources = [ordered]@{
    'skillspector' = 'NVIDIA/SkillSpector'
    'skill-validator' = 'github.com/agent-ecosystem/skill-validator/cmd/skill-validator'
    'skill-tools' = 'npm:skill-tools'
    'pester' = 'PowerShellGallery:Pester'
}
$receipts = [ordered]@{}
foreach ($toolName in $expectedSources.Keys) {
    $receiptPath = Join-Path $runRoot "receipt-$toolName.json"
    & $resolverPath -PolicyPath $policyPath -ToolName $toolName -Install -InstallRoot $installRoot -ExpectedGoRuntimeVersion $ExpectedGoRuntimeVersion -OutputPath $receiptPath | Out-Host
    $receipt = Read-JsonFile -Path $receiptPath -Context "$toolName resolver receipt"
    if ($receipt.toolName -cne $toolName -or $receipt.source -cne $expectedSources[$toolName] -or
        $receipt.channel -cne 'latest-stable' -or $receipt.frozenForRun -ne $true -or
        [string]::IsNullOrWhiteSpace([string]$receipt.resolvedVersion) -or
        [string]::IsNullOrWhiteSpace([string]$receipt.resolvedIdentity)) {
        throw "$toolName receipt does not bind the approved frozen latest-stable identity."
    }
    $receipts[$toolName] = $receipt
    if ($toolName -ceq 'skillspector') {
        Remove-Item -LiteralPath 'Env:GITHUB_TOKEN' -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:GH_TOKEN' -Force -ErrorAction SilentlyContinue
    }
}

$skillSpectorPath = Assert-ReceiptFile -Receipt $receipts.skillspector -PathProperty 'executablePath' -HashProperty 'executableSha256' -InstallRoot $installRoot -Context 'SkillSpector'
$skillValidatorPath = Assert-ReceiptFile -Receipt $receipts.'skill-validator' -PathProperty 'executablePath' -HashProperty 'executableSha256' -InstallRoot $installRoot -Context 'skill-validator'
$skillToolsNodePath = Assert-ExternalReceiptFile -Receipt $receipts.'skill-tools' -PathProperty 'nodePath' -HashProperty 'nodeSha256' -Context 'skill-tools Node'
$skillToolsEntryPoint = Assert-ReceiptFile -Receipt $receipts.'skill-tools' -PathProperty 'entryPointPath' -HashProperty 'entryPointSha256' -InstallRoot $installRoot -Context 'skill-tools entry point'
$pesterModulePath = Assert-ReceiptFile -Receipt $receipts.pester -PathProperty 'modulePath' -HashProperty 'executableSha256' -InstallRoot $installRoot -Context 'Pester module'

$securityFindings = @()
$securityBlockers = @()
$securityHumanReview = @()
$securityTracked = @()
$staticReports = @()
$staticFindingCount = 0
$skillValidatorReports = @()
$skillValidatorCheckReports = @()
$skillToolsReports = @()
$skillToolsRouteReports = @()

# Stage 3: Package Validation. This must complete before any SkillSpector scan.
foreach ($skillId in $skillIds) {
    $skillRoot = Join-Path $repoRoot "skills/$skillId"
    $skillIntegrity = @($integrityReport.skills | Where-Object { $_.skillId -ceq $skillId })
    if ($skillIntegrity.Count -ne 1) { throw "Candidate integrity evidence is ambiguous for '$skillId'." }
    $expectedInventoryPaths = @($skillIntegrity[0].files | ForEach-Object { [string]$_.path })
    $validatorOutput = Invoke-NativeChecked -Command $skillValidatorPath -Arguments @('-o', 'json', 'validate', 'structure', '--allow-dirs=agents', $skillRoot) -Context "skill-validator package validation for $skillId" -DiagnosticRoot $runRoot
    $validatorReportPath = Join-Path $runRoot "skill-validator-$skillId.json"
    [IO.File]::WriteAllText($validatorReportPath, $validatorOutput + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    $validatorReport = Read-JsonFile -Path $validatorReportPath -Context "skill-validator package validation report for $skillId"
    Assert-SkillValidatorReport -Report $validatorReport -SkillRoot $skillRoot -ExpectedInventoryPaths $expectedInventoryPaths -SkillId $skillId
    $skillValidatorReports += [pscustomobject][ordered]@{ skillId = $skillId; report = [IO.Path]::GetFileName($validatorReportPath) }

    $checkOutput = Invoke-NativeChecked -Command $skillValidatorPath -Arguments @('check', '--strict', '--allow-dirs=agents', '-o', 'json', $skillRoot) -Context "skill-validator full check for $skillId" -DiagnosticRoot $runRoot
    $checkReportPath = Join-Path $runRoot "skill-validator-check-$skillId.json"
    [IO.File]::WriteAllText($checkReportPath, $checkOutput + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    $checkReport = Read-JsonFile -Path $checkReportPath -Context "skill-validator full check report for $skillId"
    Assert-SkillValidatorReport -Report $checkReport -SkillRoot $skillRoot -ExpectedInventoryPaths $expectedInventoryPaths -SkillId $skillId
    $skillValidatorCheckReports += [pscustomobject][ordered]@{ skillId = $skillId; report = [IO.Path]::GetFileName($checkReportPath) }
}

# Stage 4: SkillSpector Static.
foreach ($skillId in $skillIds) {
    $skillRoot = Join-Path $repoRoot "skills/$skillId"
    $skillIntegrity = @($integrityReport.skills | Where-Object { $_.skillId -ceq $skillId })
    if ($skillIntegrity.Count -ne 1) { throw "Candidate integrity evidence is ambiguous for '$skillId'." }
    $expectedInventoryPaths = @($skillIntegrity[0].files | ForEach-Object { [string]$_.path })
    $reportPath = Join-Path $runRoot "skillspector-static-$skillId.json"
    [void](Invoke-NativeChecked -Command $skillSpectorPath -Arguments @('scan', $skillRoot, '--no-llm', '--format', 'json', '--output', $reportPath) -Context "SkillSpector static scan for $skillId" -DiagnosticRoot $runRoot)
    $report = Read-JsonFile -Path $reportPath -Context "SkillSpector static report for $skillId"
    $issues = @(Assert-SkillSpectorReport -Report $report -SkillRoot $skillRoot -SkillId $skillId -ExpectedInventoryPaths $expectedInventoryPaths)
    foreach ($issue in $issues) {
        $reportedSeverity = Get-RequiredProperty -Object $issue -Name 'severity' -Context 'SkillSpector issue'
        if ($reportedSeverity -isnot [string] -or [string]::IsNullOrWhiteSpace($reportedSeverity)) {
            throw "SkillSpector returned an issue without severity for '$skillId'."
        }
        $finding = ConvertTo-ValidationSecurityFinding `
            -Policy $validationSecurityGate `
            -ReportedSeverity ([string]$reportedSeverity) `
            -Stage 'skillspector-static' `
            -SkillId $skillId `
            -Issue $issue
        $securityFindings += $finding
        $staticFindingCount++
        switch ([string]$finding.action) {
            'BLOCK' { $securityBlockers += $finding }
            'HUMAN_REVIEW_REQUIRED' { $securityHumanReview += $finding; $securityBlockers += $finding }
            'RECORD_AND_TRACK' { $securityTracked += $finding }
            default { throw "Central validation/security gate returned unsupported action '$($finding.action)'." }
        }
    }
    $staticReports += [pscustomobject][ordered]@{ skillId = $skillId; report = [IO.Path]::GetFileName($reportPath); findings = $issues.Count; files = $expectedInventoryPaths.Count }
}

# Stage 5: Repository Tests.
$repositoryReportPath = Join-Path $runRoot 'repository-validation.json'
$repositoryJson = & $repositoryValidatorPath -RepositoryRoot $repoRoot -OutputPath $repositoryReportPath | Select-Object -Last 1
$repositoryReport = $repositoryJson | ConvertFrom-Json -Depth 100
if ($repositoryReport.result -cne 'passed' -or [int]$repositoryReport.activeSkillCount -ne $skillIds.Count) {
    throw 'Repository validation did not cover the exact active Skill inventory.'
}
foreach ($skillId in $skillIds) {
    $before = @($integrityReport.skills | Where-Object { $_.skillId -ceq $skillId })
    $after = @($repositoryReport.skills | Where-Object { $_.skillId -ceq $skillId })
    if ($before.Count -ne 1 -or $after.Count -ne 1 -or $before[0].contentSha256 -cne $after[0].contentSha256) {
        throw "Candidate Skill '$skillId' changed between integrity verification and repository validation."
    }
}
$diffArguments = if (-not [string]::IsNullOrWhiteSpace($BaseCommit)) {
    @('-C', $repoRoot, 'diff', '--check', "$BaseCommit...HEAD")
}
else {
    # A missing event base must validate the complete committed candidate,
    # not only the final commit. All supported GitHub repositories use the
    # SHA-1 object format, whose canonical empty tree object is stable.
    $emptyTreeObject = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'
    @('-C', $repoRoot, 'diff', '--check', $emptyTreeObject, 'HEAD')
}
$diffOutput = @(& $gitPath @diffArguments 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Whitespace validation failed for the candidate event range.`n$($diffOutput -join [Environment]::NewLine)"
}

foreach ($skillId in $skillIds) {
    $skillRoot = Join-Path $repoRoot "skills/$skillId"
    $expectedInventoryPaths = @(
        @($repositoryReport.skills | Where-Object { $_.skillId -ceq $skillId })[0].files |
            ForEach-Object { [string]$_.path }
    )
    $toolsOutput = Invoke-NativeChecked -Command $skillToolsNodePath -Arguments @($skillToolsEntryPoint, 'check', $skillRoot, '--format', 'sarif', '--fail-on', 'warning', '--min-score', '91') -Context "skill-tools repository test for $skillId" -DiagnosticRoot $runRoot
    $toolsReportPath = Join-Path $runRoot "skill-tools-$skillId.sarif.json"
    [IO.File]::WriteAllText($toolsReportPath, $toolsOutput + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    $toolsReport = Read-JsonFile -Path $toolsReportPath -Context "skill-tools report for $skillId"
    Assert-SkillToolsReport -Report $toolsReport -SkillRoot $skillRoot -ExpectedInventoryPaths $expectedInventoryPaths -SkillId $skillId
    $skillToolsReports += [pscustomobject][ordered]@{ skillId = $skillId; report = [IO.Path]::GetFileName($toolsReportPath) }
}

$routeCases = @(
    [pscustomobject]@{ query = 'Update Jira issue PROJ-123 and assign it to me'; expected = 'work-with-jira' },
    [pscustomobject]@{ query = 'My Jira API token returns 401; validate authentication'; expected = 'configure-jira-api-access' },
    [pscustomobject]@{ query = 'Configure Jira environment variables for GitHub Copilot in my IDE and validate authentication'; expected = 'configure-jira-api-access' },
    [pscustomobject]@{ query = 'In GitHub Copilot IDE, read Jira issue PROJ-123 using my verified REST setup'; expected = 'work-with-jira' },
    [pscustomobject]@{ query = 'My BITBUCKET API environment settings are missing before a pull request review'; expected = 'configure-bitbucket-api-access' },
    [pscustomobject]@{ query = 'My Bitbucket API token returns 401; validate authentication without showing secrets'; expected = 'configure-bitbucket-api-access' },
    [pscustomobject]@{ query = 'Publish this approved requirements analysis to Confluence'; expected = 'publish-requirements-to-confluence' },
    [pscustomobject]@{ query = 'My CONFLUENCE API environment settings are missing before requirements publishing'; expected = 'configure-confluence-api-access' },
    [pscustomobject]@{ query = 'Resolve my missing Confluence Cloud ID and scoped API base URL safely'; expected = 'configure-confluence-api-access' },
    [pscustomobject]@{ query = 'Review Bitbucket PR 42 and draft comments without publishing'; expected = 'review-bitbucket-pull-request' }
)
foreach ($routeCase in $routeCases) {
    $routeOutput = Invoke-NativeChecked -Command $skillToolsNodePath -Arguments @(
        $skillToolsEntryPoint, 'route', [string]$routeCase.query, '--skills', $skillsRoot, '--top-k', '1', '--format', 'json'
    ) -Context "skill-tools route for '$($routeCase.query)'" -DiagnosticRoot $runRoot
    $routePath = Join-Path $runRoot ("skill-tools-route-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    [IO.File]::WriteAllText($routePath, $routeOutput + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    # PowerShell unwraps a one-item JSON array during assignment. Normalize the
    # result before enforcing the contract so a valid top-k=1 result is not
    # mistaken for a non-array value on the hosted runner.
    $routeResults = @(Read-JsonFile -Path $routePath -Context "skill-tools route report for '$($routeCase.query)'")
    if ($routeResults.Count -ne 1) {
        throw "skill-tools route did not return exactly one result for '$($routeCase.query)'."
    }
    $routeSkill = Get-RequiredProperty -Object @($routeResults)[0] -Name 'skill' -Context 'skill-tools route result'
    if ($routeSkill -isnot [string] -or $routeSkill -cne [string]$routeCase.expected) {
        throw "skill-tools route selected '$routeSkill' for '$($routeCase.query)'; expected '$($routeCase.expected)'."
    }
    $skillToolsRouteReports += [pscustomobject][ordered]@{
        query = [string]$routeCase.query
        expected = [string]$routeCase.expected
        selected = [string]$routeSkill
        report = [IO.Path]::GetFileName($routePath)
    }
}

# Candidate tests are untrusted code. Run them in a child PowerShell process so
# a test cannot terminate this validator before the post-test integrity checks.
$pesterRunnerPath = Join-Path $runRoot 'invoke-pester-isolated.ps1'
$pesterResultPath = Join-Path $runRoot 'pester-result.json'
$pesterRunnerScript = @'
#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $TestsRoot,
    [Parameter(Mandatory = $true)][string] $PesterModulePath,
    [Parameter(Mandatory = $true)][string] $ExpectedPesterVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$testsRoot = [IO.Path]::GetFullPath($TestsRoot)
$pesterModulePath = [IO.Path]::GetFullPath($PesterModulePath)
$requiredPesterTests = @(
    'InterT10_runs the existing repository contract validator',
    'InterT20_runs standalone export validation',
    'InterT30_runs all offline API credential and access-path checks'
)
$resultMarker = ([Console]::In.ReadToEnd()).TrimEnd([char]13, [char]10)
if ($resultMarker -notmatch '^SGV1-Pester-Result-[0-9a-f]{32}:$') {
    throw 'The isolated Pester supervisor did not receive a valid one-time completion marker.'
}
if (-not (Test-Path -LiteralPath $testsRoot -PathType Container)) { throw "Pester tests root is missing: $testsRoot" }
if (-not (Test-Path -LiteralPath $pesterModulePath -PathType Leaf)) { throw "Pester module manifest is missing: $pesterModulePath" }

Remove-Module Pester -Force -ErrorAction SilentlyContinue
Import-Module -Name $pesterModulePath -Force -ErrorAction Stop
$loadedPester = Get-Module Pester | Select-Object -First 1
if ($null -eq $loadedPester -or [string]$loadedPester.Version -cne $ExpectedPesterVersion) {
    throw 'The exact frozen Pester module was not imported in the isolated test process.'
}
$result = Invoke-Pester -Path $testsRoot -PassThru
if ($null -eq $result -or [int64]$result.TotalCount -le 0 -or [int64]$result.FailedCount -ne 0 -or
    [int64]$result.SkippedCount -ne 0 -or
    [int64]$result.PassedCount + [int64]$result.SkippedCount -ne [int64]$result.TotalCount) {
    throw 'Pester repository regression did not complete successfully.'
}
foreach ($requiredTest in $requiredPesterTests) {
    $matches = @($result.Tests | Where-Object {
        [string]$_.Name -ceq $requiredTest -and [string]$_.Result -ceq 'Passed'
    })
    if ($matches.Count -ne 1) {
        throw "Required Pester bridge test '$requiredTest' did not complete exactly once with Passed status."
    }
}

$summary = [ordered]@{
    result = 'passed'
    pesterVersion = [string]$loadedPester.Version
    totalCount = [int64]$result.TotalCount
    passedCount = [int64]$result.PassedCount
    failedCount = [int64]$result.FailedCount
    skippedCount = [int64]$result.SkippedCount
    requiredTests = @($requiredPesterTests)
}
Write-Output ($resultMarker + ($summary | ConvertTo-Json -Depth 20 -Compress))
'@
[IO.File]::WriteAllText($pesterRunnerPath, $pesterRunnerScript + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
Assert-NoReparseAncestors -Path $pesterRunnerPath -Context 'Run-owned isolated Pester runner' -Boundary $runRoot
$powerShellExecutableName = if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }
$powerShellPath = Join-Path $PSHOME $powerShellExecutableName
if (-not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) { throw "PowerShell child executable is missing: $powerShellPath" }
Assert-NoReparseAncestors -Path $powerShellPath -Context 'PowerShell child executable'

# Required bridge scripts are executed directly by the trusted supervisor.
# Candidate Pester test names are supplemental coverage, not the sole proof
# that the repository, standalone-export, and API contracts ran.
$trustedBridgeRoot = Join-Path $supervisorRoot 'tests'
$bridgeScriptPaths = @(
    Join-Path $trustedBridgeRoot 'validate-repository.ps1'
    Join-Path $trustedBridgeRoot 'validate-repository-standalone.ps1'
    Join-Path $trustedBridgeRoot 'validate-api-access.ps1'
)
$bridgeValidationReports = @()
foreach ($bridgeScriptPath in $bridgeScriptPaths) {
    if (-not (Test-Path -LiteralPath $bridgeScriptPath -PathType Leaf)) {
        throw "Required bridge script is missing: $bridgeScriptPath"
    }
    Assert-NoReparseAncestors -Path $bridgeScriptPath -Context 'Trusted bridge script' -Boundary $supervisorRoot
    $bridgeCompletionMarker = 'SGV1-Bridge-{0}' -f ([guid]::NewGuid().ToString('N'))
    $bridgeOutput = Invoke-NativeChecked -Command $powerShellPath -Arguments @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $bridgeScriptPath,
        '-RepositoryRoot', $repoRoot,
        '-CompletionMarker', $bridgeCompletionMarker
    ) -Context "Direct bridge validation for $([IO.Path]::GetFileName($bridgeScriptPath))" -DiagnosticRoot $runRoot -IsolateRunnerCommandFiles
    $bridgeCompletionLines = @($bridgeOutput -split "`r?`n" | Where-Object {
        $_ -ceq $bridgeCompletionMarker
    })
    if ($bridgeCompletionLines.Count -ne 1) {
        throw "Trusted bridge '$([IO.Path]::GetFileName($bridgeScriptPath))' exited successfully without exactly one protected completion marker."
    }
    $bridgeValidationReports += [pscustomobject][ordered]@{
        script = [IO.Path]::GetFileName($bridgeScriptPath)
        result = 'passed'
        outputLineCount = @($bridgeOutput).Count
    }
}

$pesterResultMarker = 'SGV1-Pester-Result-{0}:' -f ([guid]::NewGuid().ToString('N'))
$pesterOutput = Invoke-NativeChecked -Command $powerShellPath -Arguments @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $pesterRunnerPath,
    '-TestsRoot', (Join-Path $repoRoot 'tests'),
    '-PesterModulePath', $pesterModulePath,
    '-ExpectedPesterVersion', [string]$receipts.pester.resolvedVersion
 ) -Context 'Isolated Pester repository regression' -DiagnosticRoot $runRoot -StandardInput $pesterResultMarker -IsolateRunnerCommandFiles -TerminateProcessTree -ProtectRunnerCommandFiles
$pesterResultLines = @($pesterOutput -split "`r?`n" | Where-Object {
    $_.StartsWith($pesterResultMarker, [StringComparison]::Ordinal)
})
if ($pesterResultLines.Count -ne 1) {
    throw 'Isolated Pester exited without exactly one supervisor-owned completion result.'
}
[IO.File]::WriteAllText(
    $pesterResultPath,
    $pesterResultLines[0].Substring($pesterResultMarker.Length) + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false)
)
$pesterResult = Read-JsonFile -Path $pesterResultPath -Context 'Isolated Pester result'
if ($pesterResult.result -cne 'passed' -or
    $pesterResult.pesterVersion -cne [string]$receipts.pester.resolvedVersion -or
    [int64]$pesterResult.TotalCount -le 0 -or [int64]$pesterResult.FailedCount -ne 0 -or
    [int64]$pesterResult.SkippedCount -ne 0 -or
    [int64]$pesterResult.PassedCount + [int64]$pesterResult.SkippedCount -ne [int64]$pesterResult.TotalCount) {
    throw 'Isolated Pester repository regression result was missing, mismatched, or incomplete.'
}
$expectedPesterTests = @(
    'InterT10_runs the existing repository contract validator',
    'InterT20_runs standalone export validation',
    'InterT30_runs all offline API credential and access-path checks'
)
$actualPesterTests = @($pesterResult.requiredTests)
if ($pesterResult.requiredTests -isnot [array] -or $actualPesterTests.Count -ne $expectedPesterTests.Count) {
    throw 'Isolated Pester result did not include the complete required bridge-test manifest.'
}
for ($testIndex = 0; $testIndex -lt $expectedPesterTests.Count; $testIndex++) {
    if ([string]$actualPesterTests[$testIndex] -cne $expectedPesterTests[$testIndex]) {
        throw 'Isolated Pester result bridge-test manifest did not match the protected required suite.'
    }
}

$postPesterRepositoryReportPath = Join-Path $runRoot 'repository-validation-post-pester.json'
$postPesterCandidateCommit = ([string](@(& $gitPath -C $repoRoot rev-parse HEAD 2>$null) | Select-Object -First 1)).Trim()
if ($LASTEXITCODE -ne 0 -or $postPesterCandidateCommit -cne $candidateCommit) {
    throw "Candidate commit changed during repository tests; expected '$candidateCommit' but found '$postPesterCandidateCommit'."
}
$postPesterTree = ([string](@(& $gitPath -C $repoRoot rev-parse "$postPesterCandidateCommit^{tree}" 2>$null) | Select-Object -First 1)).Trim()
if ($LASTEXITCODE -ne 0 -or $postPesterTree -cne $candidateTree) {
    throw 'Candidate Git tree changed during repository tests.'
}
$postPesterIndexState = @(& $gitPath -C $repoRoot ls-files -v)
if ($LASTEXITCODE -ne 0 -or @($postPesterIndexState | Where-Object { [string]$_ -notmatch '^H ' }).Count -ne 0) {
    throw 'Candidate Git index contains assume-unchanged or other non-normal entries after repository tests.'
}
$postPesterRepositoryJson = & $repositoryValidatorPath -RepositoryRoot $repoRoot -OutputPath $postPesterRepositoryReportPath | Select-Object -Last 1
$postPesterRepositoryReport = $postPesterRepositoryJson | ConvertFrom-Json -Depth 100
if ($postPesterRepositoryReport.result -cne 'passed' -or [int]$postPesterRepositoryReport.activeSkillCount -ne $skillIds.Count) {
    throw 'Post-Pester repository validation did not cover the exact active Skill inventory.'
}
foreach ($skillId in $skillIds) {
    $before = @($integrityReport.skills | Where-Object { $_.skillId -ceq $skillId })
    $after = @($postPesterRepositoryReport.skills | Where-Object { $_.skillId -ceq $skillId })
    if ($before.Count -ne 1 -or $after.Count -ne 1 -or $before[0].contentSha256 -cne $after[0].contentSha256) {
        throw "Candidate Skill '$skillId' changed during repository tests."
    }
}
$postPesterDirty = @(& $gitPath -C $repoRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $postPesterDirty.Count -ne 0) {
    throw 'Candidate changed during repository tests; post-Pester evidence is not bound to a clean commit.'
}
$repositoryReport = $postPesterRepositoryReport

# Standard CI is deliberately credential-free and deterministic.  The LLM-backed
# SkillSpector stage is an explicit supplemental review, never an implicit network
# dependency of the required gate.  Static findings remain governed above and
# still block according to the central security policy.
$semanticTriggerCandidate = $staticFindingCount -gt 0 -or (Test-SecurityRelevantSkillChange -GitPath $gitPath -RepositoryRoot $repoRoot -BaseCommit $BaseCommit)
$semanticTriggered = [bool]$EnableSemanticScan -and $semanticTriggerCandidate
$semanticReports = @()
if ($semanticTriggered) {
    # Candidate Pester code runs before this stage and can write to run-owned
    # tool directories. Rebind the scanner path and receipt hash immediately
    # before semantic execution so a test cannot substitute the scanner.
    $skillSpectorPath = Assert-ReceiptFile -Receipt $receipts.skillspector -PathProperty 'executablePath' -HashProperty 'executableSha256' -InstallRoot $installRoot -Context 'SkillSpector semantic scanner'
    foreach ($skillId in $skillIds) {
        $skillRoot = Join-Path $repoRoot "skills/$skillId"
        $expectedInventoryPaths = @(
            @($repositoryReport.skills | Where-Object { $_.skillId -ceq $skillId })[0].files |
                ForEach-Object { [string]$_.path }
        )
        $semanticPath = Join-Path $runRoot "skillspector-semantic-$skillId.json"
        [void](Invoke-NativeChecked -Command $skillSpectorPath -Arguments @('scan', $skillRoot, '--format', 'json', '--output', $semanticPath) -Context "SkillSpector semantic scan for $skillId" -DiagnosticRoot $runRoot)
        $semanticReport = Read-JsonFile -Path $semanticPath -Context "SkillSpector semantic report for $skillId"
        try {
            $semanticIssues = @(Assert-SkillSpectorReport -Report $semanticReport -SkillRoot $skillRoot -SkillId $skillId -ExpectedInventoryPaths $expectedInventoryPaths)
        }
        catch {
            throw "Triggered SkillSpector semantic scan did not complete for '$skillId': $($_.Exception.Message)"
        }
        foreach ($issue in $semanticIssues) {
            $reportedSeverity = Get-RequiredProperty -Object $issue -Name 'severity' -Context 'SkillSpector semantic issue'
            if ($reportedSeverity -isnot [string] -or [string]::IsNullOrWhiteSpace($reportedSeverity)) {
                throw "SkillSpector semantic scan returned an issue without severity for '$skillId'."
            }
            $finding = ConvertTo-ValidationSecurityFinding `
                -Policy $validationSecurityGate `
                -ReportedSeverity ([string]$reportedSeverity) `
                -Stage 'conditional-semantic-scan' `
                -SkillId $skillId `
                -Issue $issue
            $securityFindings += $finding
            switch ([string]$finding.action) {
                'BLOCK' { $securityBlockers += $finding }
                'HUMAN_REVIEW_REQUIRED' { $securityHumanReview += $finding; $securityBlockers += $finding }
                'RECORD_AND_TRACK' { $securityTracked += $finding }
                default { throw "Central validation/security gate returned unsupported action '$($finding.action)'." }
            }
        }
        $semanticReports += [pscustomobject][ordered]@{ skillId = $skillId; report = [IO.Path]::GetFileName($semanticPath); findings = $semanticIssues.Count }
    }
}

$summary = [pscustomobject][ordered]@{
    schemaVersion = 1
    standardVersion = 'v1'
    runId = $runId
    authority = [ordered]@{
        repository = [string]$adapter.authority.repository
        commit = [string]$adapter.authority.commit
        archiveSha256 = $archiveHash
        files = $authorityFiles
    }
    canonicalGate = [ordered]@{
        policy = [string]$validationSecurityGate.policy
        policyPath = 'docs/standards/validation-security-gate.json'
        policySha256 = $validationSecurityGatePolicySha256
        stageIds = @($validationSecurityGate.stages | ForEach-Object { [string]$_.id })
    }
    candidate = [ordered]@{
        repository = 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git'
        commit = $candidateCommit
        baseCommit = $resolvedBaseCommit
    }
    tools = @($expectedSources.Keys | ForEach-Object {
        [pscustomobject][ordered]@{
            toolName = $_
            source = [string]$receipts[$_].source
            version = [string]$receipts[$_].resolvedVersion
            resolvedIdentity = [string]$receipts[$_].resolvedIdentity
        }
    })
    skills = @($repositoryReport.skills | ForEach-Object { [pscustomobject][ordered]@{ skillId = $_.skillId; contentSha256 = $_.contentSha256 } })
    security = [ordered]@{
        result = if (@($securityBlockers).Count -eq 0) { 'passed' } else { 'blocked' }
        findings = $securityFindings
        humanReviewRequired = $securityHumanReview
        blockingFindings = $securityBlockers
        trackedFindings = $securityTracked
    }
    stages = [ordered]@{
        controlledAcquisition = 'passed'
        integrityVerification = 'passed'
        packageValidation = [ordered]@{ structure = $skillValidatorReports; fullCheck = $skillValidatorCheckReports }
        skillspectorStatic = $staticReports
        repositoryTests = [ordered]@{
            repositoryValidation = 'passed'
            bridgeScripts = $bridgeValidationReports
            skillTools = $skillToolsReports
            routing = $skillToolsRouteReports
            pester = [ordered]@{ result = 'passed'; total = [int]$pesterResult.TotalCount; passed = [int]$pesterResult.PassedCount; skipped = [int]$pesterResult.SkippedCount }
        }
        conditionalSemanticScan = [ordered]@{ requested = [bool]$EnableSemanticScan; triggered = $semanticTriggered; reports = $semanticReports }
        aiReview = 'required-before-release'
        humanApproval = 'required-before-release'
        publishOrInstall = 'blocked-until-approved-release'
        postInstallVerification = 'required-after-install'
    }
    deviations = 'None'
    result = if (@($securityBlockers).Count -eq 0) { 'passed' } else { 'blocked' }
}
$summaryJson = $summary | ConvertTo-Json -Depth 100
$summaryPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-Path $runRoot 'conformance-report.json'
}
else {
    Assert-PathWithinRoot -Path ([IO.Path]::GetFullPath($OutputPath)) -Root $artifactsRootPath -Context 'Conformance output'
}
$summaryDirectory = Split-Path -Parent $summaryPath
if (-not [string]::IsNullOrWhiteSpace($summaryDirectory)) {
    [void](New-Item -ItemType Directory -Path $summaryDirectory -Force)
    Assert-NoReparseAncestors -Path $summaryDirectory -Context 'Conformance output directory' -Boundary $artifactsRootPath
}
if (Test-Path -LiteralPath $summaryPath) { throw 'Conformance output path already exists; evidence must not overwrite prior content.' }
[IO.File]::WriteAllText($summaryPath, $summaryJson + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
if (@($securityBlockers).Count -gt 0) {
    Write-Host "Atlassian Ecosystem Standard v1 canonical validation blocked by the central security gate. Evidence: $summaryPath"
}
else {
    Write-Host "Atlassian Ecosystem Standard v1 canonical validation passed. Evidence: $summaryPath"
}
$summaryJson
if (@($securityBlockers).Count -gt 0) {
    throw 'Canonical validation/security gate blocked the candidate; resolve central findings and obtain required Human Review before release or install.'
}
