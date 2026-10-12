#requires -Version 7.2
# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:StandardCoreV2PreparationProfileSha256 = '029f6ed4e54e1a575987fb0e443e725079b4a082fba8bd76bb998a74922992e1'
$script:StandardCoreV2AuthorityCommit = 'ff85d5f80fe795b96354e753074b5ce59ad04ecd'
$script:StandardCoreV2AuthorityArchiveSha256 = '3dc38613f2e2316ad8fcc79d4bf48d0b03fd8398f8dacc72d156abcbce95ea9d'
$script:StandardCoreV2AuthorityRepository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
$script:StandardCoreSourceRepository = 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git'
$script:StandardCoreV2GitOperationContext = $null
$script:StandardCoreV2DirectGitTimeoutSeconds = 3600
$script:StandardCoreV2GitCleanupTimeoutMilliseconds = 5000
$script:StandardCoreV2GitTextOutputLimitBytes = 32L * 1024L * 1024L
$script:StandardCoreV2GitArchiveLimitBytes = 256L * 1024L * 1024L

function Get-StandardCoreV2Sha256 {
    param([Parameter(Mandatory)][string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Assert-StandardCoreV2NoReparseAncestors {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Context)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath)) { throw "$Context is missing: $fullPath" }
    $cursor = $fullPath
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$Context contains a reparse point: $cursor" }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -ceq $cursor) { break }
        $cursor = $parent
    }
}

function Assert-StandardCoreV2PathWithin {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $Context)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, $comparison)) { throw "$Context must be a child of its owned root." }
    return $fullPath
}

function New-StandardCoreV2GitProcessStartInfo {
    param([Parameter(Mandatory)][string] $GitPath, [Parameter(Mandatory)][string[]] $Arguments, [string] $WorkingDirectory)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = [IO.Path]::GetFullPath($GitPath)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false, $true)
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $startInfo.WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory) }
    foreach ($name in @($startInfo.Environment.Keys)) {
        if ([string]$name -match '^GIT_') { [void]$startInfo.Environment.Remove([string]$name) }
    }
    $startInfo.Environment['GIT_CONFIG_NOSYSTEM'] = '1'
    $startInfo.Environment['GIT_CONFIG_GLOBAL'] = 'NUL'
    $startInfo.Environment['GIT_ATTR_NOSYSTEM'] = '1'
    $startInfo.Environment['GIT_NO_REPLACE_OBJECTS'] = '1'
    $startInfo.Environment['GIT_NO_LAZY_FETCH'] = '1'
    [void]$startInfo.ArgumentList.Add('-c')
    [void]$startInfo.ArgumentList.Add('core.longpaths=true')
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add([string]$argument) }
    return $startInfo
}

function Set-StandardCoreV2GitOperationContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Diagnostics.Stopwatch] $Stopwatch,
        [Parameter(Mandatory)][ValidateRange(1, 14400)][int] $OperationTimeoutSeconds
    )
    if (-not $Stopwatch.IsRunning) { throw 'The protected Git operation stopwatch must already be running.' }
    $script:StandardCoreV2GitOperationContext = [pscustomobject]@{
        Stopwatch = $Stopwatch
        OperationTimeoutSeconds = $OperationTimeoutSeconds
    }
}

function Clear-StandardCoreV2GitOperationContext {
    $script:StandardCoreV2GitOperationContext = $null
}

function Get-StandardCoreV2GitRemainingMilliseconds {
    param(
        [Parameter(Mandatory)][Diagnostics.Stopwatch] $ProcessStopwatch,
        [Parameter(Mandatory)][string] $Context
    )
    $operationContext = $script:StandardCoreV2GitOperationContext
    if ($null -ne $operationContext) {
        if ($operationContext.Stopwatch -isnot [Diagnostics.Stopwatch] -or -not $operationContext.Stopwatch.IsRunning -or
            [int]$operationContext.OperationTimeoutSeconds -lt 1 -or [int]$operationContext.OperationTimeoutSeconds -gt 14400) {
            throw 'The protected Git operation deadline context is malformed.'
        }
        $timeoutSeconds = [int]$operationContext.OperationTimeoutSeconds
        $elapsedMilliseconds = [long]$operationContext.Stopwatch.ElapsedMilliseconds
    }
    else {
        $timeoutSeconds = $script:StandardCoreV2DirectGitTimeoutSeconds
        $elapsedMilliseconds = [long]$ProcessStopwatch.ElapsedMilliseconds
    }
    $remainingMilliseconds = ([long]$timeoutSeconds * 1000L) - $elapsedMilliseconds
    if ($remainingMilliseconds -le 0) {
        throw "Trusted Git operation deadline expired before '$Context'; timeoutSeconds=$timeoutSeconds; elapsedMilliseconds=$elapsedMilliseconds."
    }
    return [int][Math]::Min([long][int]::MaxValue, $remainingMilliseconds)
}

function Get-StandardCoreV2GitElapsedMilliseconds {
    param([Parameter(Mandatory)][Diagnostics.Stopwatch] $ProcessStopwatch)
    $operationContext = $script:StandardCoreV2GitOperationContext
    if ($null -ne $operationContext -and $operationContext.Stopwatch -is [Diagnostics.Stopwatch]) {
        return [long]$operationContext.Stopwatch.ElapsedMilliseconds
    }
    return [long]$ProcessStopwatch.ElapsedMilliseconds
}

function Wait-StandardCoreV2GitTasks {
    param(
        [Parameter(Mandatory)][Diagnostics.Stopwatch] $ProcessStopwatch,
        [Parameter(Mandatory)][System.Threading.Tasks.Task[]] $Tasks,
        [Parameter(Mandatory)][string] $Context
    )
    if ($Tasks.Count -eq 0) { return }
    $remainingMilliseconds = Get-StandardCoreV2GitRemainingMilliseconds -ProcessStopwatch $ProcessStopwatch -Context $Context
    $allTasks = [System.Threading.Tasks.Task]::WhenAll($Tasks)
    if (-not $allTasks.Wait($remainingMilliseconds)) {
        $elapsedMilliseconds = Get-StandardCoreV2GitElapsedMilliseconds -ProcessStopwatch $ProcessStopwatch
        throw [TimeoutException]::new("Trusted Git operation deadline expired while waiting for $Context; elapsedMilliseconds=$elapsedMilliseconds.")
    }
    $allTasks.GetAwaiter().GetResult()
}

function Stop-StandardCoreV2GitProcess {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Threading.Tasks.Task[]] $Tasks
    )
    $cleanupWatch = [Diagnostics.Stopwatch]::StartNew()
    $killVerified = $true
    try {
        if (-not $Process.HasExited) { $Process.Kill($true) }
    }
    catch {
        try { if (-not $Process.HasExited) { $killVerified = $false } } catch { $killVerified = $false }
    }
    $remainingMilliseconds = [Math]::Max(0, $script:StandardCoreV2GitCleanupTimeoutMilliseconds - [int]$cleanupWatch.ElapsedMilliseconds)
    try {
        if (-not $Process.HasExited -and $remainingMilliseconds -gt 0) { [void]$Process.WaitForExit($remainingMilliseconds) }
    }
    catch { }
    foreach ($task in $Tasks) {
        if ($null -eq $task -or $task.IsCompleted) { continue }
        $remainingMilliseconds = [Math]::Max(0, $script:StandardCoreV2GitCleanupTimeoutMilliseconds - [int]$cleanupWatch.ElapsedMilliseconds)
        if ($remainingMilliseconds -le 0) { break }
        try { [void]$task.Wait($remainingMilliseconds) } catch { }
    }
    $processExited = $false
    try { $processExited = $Process.HasExited } catch { }
    $streamsDrained = @($Tasks | Where-Object { $null -ne $_ -and -not $_.IsCompleted }).Count -eq 0
    return [bool]($killVerified -and $processExited -and $streamsDrained)
}

function Receive-StandardCoreV2GitBoundedProcessStreams {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $Process,
        [Parameter(Mandatory)][Diagnostics.Stopwatch] $ProcessStopwatch,
        [Parameter(Mandatory)][IO.Stream] $StandardOutputDestination,
        [Parameter(Mandatory)][long] $StandardOutputLimitBytes,
        [Parameter(Mandatory)][IO.MemoryStream] $StandardErrorDestination,
        [Parameter(Mandatory)][long] $StandardErrorLimitBytes,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[System.Threading.Tasks.Task]] $Tasks,
        [Parameter(Mandatory)][string] $Context,
        [Parameter()][string[]] $StandardInputNulSeparatedText = @()
    )
    if ($StandardOutputLimitBytes -le 0 -or $StandardErrorLimitBytes -le 0) {
        throw 'Trusted Git output limits must be positive byte counts.'
    }

    $bufferSize = 65536
    $stdoutBuffer = [byte[]]::new($bufferSize)
    $stderrBuffer = [byte[]]::new($bufferSize)
    $stdoutCount = 0L
    $stderrCount = 0L
    $stdoutWriteCount = 0
    $stdoutWriteTask = $null
    $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
    $stdoutTask = $Process.StandardOutput.BaseStream.ReadAsync($stdoutBuffer, 0, $stdoutBuffer.Length, [Threading.CancellationToken]::None)
    $stderrTask = $Process.StandardError.BaseStream.ReadAsync($stderrBuffer, 0, $stderrBuffer.Length, [Threading.CancellationToken]::None)
    $exitTask = $Process.WaitForExitAsync()
    $exitPending = $true
    $Tasks.Add($stdoutTask)
    $Tasks.Add($stderrTask)
    $Tasks.Add($exitTask)

    $inputPaths = [string[]]@($StandardInputNulSeparatedText)
    $inputState = [pscustomobject]@{ Index = 0; Buffer = $null; WriteTask = $null; Closed = $false }

    $startNextInputWrite = {
        if ($inputState.Index -ge $inputPaths.Length) {
            $Process.StandardInput.Close()
            $inputState.Closed = $true
            return
        }
        $path = [string]$inputPaths[$inputState.Index]
        if ($path.IndexOf([char]0) -ge 0) { throw 'Trusted Git stdin path contains a NUL character.' }
        $pathBytes = $strictUtf8.GetBytes($path)
        $inputState.Buffer = [byte[]]::new($pathBytes.Length + 1)
        [Buffer]::BlockCopy($pathBytes, 0, $inputState.Buffer, 0, $pathBytes.Length)
        $inputState.Buffer[$inputState.Buffer.Length - 1] = 0
        $inputState.WriteTask = $Process.StandardInput.BaseStream.WriteAsync($inputState.Buffer, 0, $inputState.Buffer.Length, [Threading.CancellationToken]::None)
        $Tasks.Add($inputState.WriteTask)
        $inputState.Index++
    }

    if ($inputPaths.Length -eq 0) {
        $Process.StandardInput.Close()
        $inputState.Closed = $true
    }
    else {
        & $startNextInputWrite
    }

    while ($null -ne $stdoutTask -or $null -ne $stdoutWriteTask -or $null -ne $stderrTask -or $null -ne $inputState.WriteTask -or $exitPending) {
        $activeTasks = [Collections.Generic.List[System.Threading.Tasks.Task]]::new()
        $activeKinds = [Collections.Generic.List[string]]::new()
        if ($null -ne $stdoutTask) { $activeTasks.Add($stdoutTask); $activeKinds.Add('stdout') }
        if ($null -ne $stdoutWriteTask) { $activeTasks.Add($stdoutWriteTask); $activeKinds.Add('stdout-write') }
        if ($null -ne $stderrTask) { $activeTasks.Add($stderrTask); $activeKinds.Add('stderr') }
        if ($null -ne $inputState.WriteTask) { $activeTasks.Add($inputState.WriteTask); $activeKinds.Add('stdin') }
        if ($exitPending) { $activeTasks.Add($exitTask); $activeKinds.Add('exit') }
        if ($activeTasks.Count -eq 0) { break }

        $remainingMilliseconds = Get-StandardCoreV2GitRemainingMilliseconds -ProcessStopwatch $ProcessStopwatch -Context "$Context stream pump"
        $completedIndex = [System.Threading.Tasks.Task]::WaitAny($activeTasks.ToArray(), $remainingMilliseconds)
        if ($completedIndex -lt 0) {
            $elapsedMilliseconds = Get-StandardCoreV2GitElapsedMilliseconds -ProcessStopwatch $ProcessStopwatch
            throw [TimeoutException]::new("Trusted Git operation deadline expired while waiting for $Context stream pump; elapsedMilliseconds=$elapsedMilliseconds.")
        }

        switch ($activeKinds[$completedIndex]) {
            'stdout' {
                $completedTask = $stdoutTask
                [void]$Tasks.Remove([System.Threading.Tasks.Task]$completedTask)
                $bytesRead = [int]$completedTask.GetAwaiter().GetResult()
                $stdoutTask = $null
                if ($bytesRead -gt 0) {
                    if ($stdoutCount -gt ($StandardOutputLimitBytes - [long]$bytesRead)) {
                        throw "$Context stdout output exceeded the $StandardOutputLimitBytes-byte limit."
                    }
                    $stdoutWriteCount = $bytesRead
                    $stdoutWriteTask = $StandardOutputDestination.WriteAsync($stdoutBuffer, 0, $bytesRead, [Threading.CancellationToken]::None)
                    $Tasks.Add($stdoutWriteTask)
                }
            }
            'stdout-write' {
                $completedTask = $stdoutWriteTask
                [void]$Tasks.Remove([System.Threading.Tasks.Task]$completedTask)
                $completedTask.GetAwaiter().GetResult()
                $stdoutCount += [long]$stdoutWriteCount
                $stdoutWriteCount = 0
                $stdoutWriteTask = $null
                $stdoutTask = $Process.StandardOutput.BaseStream.ReadAsync($stdoutBuffer, 0, $stdoutBuffer.Length, [Threading.CancellationToken]::None)
                $Tasks.Add($stdoutTask)
            }
            'stderr' {
                $completedTask = $stderrTask
                [void]$Tasks.Remove([System.Threading.Tasks.Task]$completedTask)
                $bytesRead = [int]$completedTask.GetAwaiter().GetResult()
                $stderrTask = $null
                if ($bytesRead -gt 0) {
                    if ($stderrCount -gt ($StandardErrorLimitBytes - [long]$bytesRead)) {
                        throw "$Context stderr output exceeded the $StandardErrorLimitBytes-byte limit."
                    }
                    $StandardErrorDestination.Write($stderrBuffer, 0, $bytesRead)
                    $stderrCount += [long]$bytesRead
                    $stderrTask = $Process.StandardError.BaseStream.ReadAsync($stderrBuffer, 0, $stderrBuffer.Length, [Threading.CancellationToken]::None)
                    $Tasks.Add($stderrTask)
                }
            }
            'stdin' {
                $completedTask = $inputState.WriteTask
                [void]$Tasks.Remove([System.Threading.Tasks.Task]$completedTask)
                $completedTask.GetAwaiter().GetResult()
                $inputState.WriteTask = $null
                $inputState.Buffer = $null
                & $startNextInputWrite
            }
            'exit' {
                $exitTask.GetAwaiter().GetResult()
                [void]$Tasks.Remove([System.Threading.Tasks.Task]$exitTask)
                $exitPending = $false
            }
        }
    }
    if (-not $inputState.Closed) { $Process.StandardInput.Close() }
    return [pscustomobject]@{ StandardOutputBytes = $stdoutCount; StandardErrorBytes = $stderrCount }
}

function Invoke-StandardCoreV2GitText {
    param(
        [Parameter(Mandatory)][string] $GitPath,
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter()][int[]] $AllowedExitCodes = @(0),
        [Parameter()][string] $WorkingDirectory,
        [Parameter()][string[]] $StandardInputNulSeparatedText = @()
    )
    $startInfo = New-StandardCoreV2GitProcessStartInfo -GitPath $GitPath -Arguments $Arguments -WorkingDirectory $WorkingDirectory
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $processWatch = [Diagnostics.Stopwatch]::StartNew()
    $started = $false
    $tasks = [Collections.Generic.List[System.Threading.Tasks.Task]]::new()
    $output = $null
    $errorTextStream = $null
    try {
        [void](Get-StandardCoreV2GitRemainingMilliseconds -ProcessStopwatch $processWatch -Context 'Git process start')
        if (-not $process.Start()) { throw 'Could not start the trusted Git process.' }
        $started = $true
        $output = [IO.MemoryStream]::new()
        $errorTextStream = [IO.MemoryStream]::new()
        [void](Receive-StandardCoreV2GitBoundedProcessStreams -Process $process -ProcessStopwatch $processWatch `
            -StandardOutputDestination $output -StandardOutputLimitBytes $script:StandardCoreV2GitTextOutputLimitBytes `
            -StandardErrorDestination $errorTextStream -StandardErrorLimitBytes $script:StandardCoreV2GitTextOutputLimitBytes `
            -Tasks $tasks -Context 'Git text' -StandardInputNulSeparatedText $StandardInputNulSeparatedText)
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        $outputText = $utf8.GetString($output.GetBuffer(), 0, [int]$output.Length)
        $errorText = $utf8.GetString($errorTextStream.GetBuffer(), 0, [int]$errorTextStream.Length)
        if ($process.ExitCode -notin $AllowedExitCodes) { throw "Trusted Git failed ($($Arguments -join ' '), exit=$($process.ExitCode)): $errorText" }
        return [pscustomobject]@{ ExitCode = [int]$process.ExitCode; StdOut = [string]$outputText; StdErr = [string]$errorText }
    }
    catch {
        $cause = $_.Exception.Message
        if ($started) {
            $processId = [int]$process.Id
            $cleanupVerified = Stop-StandardCoreV2GitProcess -Process $process -Tasks $tasks.ToArray()
            $elapsedMilliseconds = Get-StandardCoreV2GitElapsedMilliseconds -ProcessStopwatch $processWatch
            $cleanupLabel = if ($cleanupVerified) { 'verified' } else { 'unverified' }
            throw "Trusted Git operation failed: $cause; processId=$processId; elapsedMilliseconds=$elapsedMilliseconds; cleanup=$cleanupLabel."
        }
        throw
    }
    finally {
        if ($null -ne $output) { $output.Dispose() }
        if ($null -ne $errorTextStream) { $errorTextStream.Dispose() }
        $process.Dispose()
    }
}

function Get-StandardCoreV2GitBlobSha256 {
    param([Parameter(Mandatory)][string] $GitPath, [Parameter(Mandatory)][string] $RepositoryRoot, [Parameter(Mandatory)][string] $ObjectId)
    if ($ObjectId -cnotmatch '^[0-9a-f]{40}$') { throw 'The expected Git blob identity is malformed.' }
    $arguments = @('--no-replace-objects', '-C', $RepositoryRoot, 'cat-file', 'blob', $ObjectId)
    $startInfo = New-StandardCoreV2GitProcessStartInfo -GitPath $GitPath -Arguments $arguments
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $hasher = [Security.Cryptography.SHA256]::Create()
    $hashDestination = [Security.Cryptography.CryptoStream]::new([IO.Stream]::Null, $hasher, [Security.Cryptography.CryptoStreamMode]::Write, $true)
    $errorTextStream = [IO.MemoryStream]::new()
    $processWatch = [Diagnostics.Stopwatch]::StartNew()
    $started = $false
    $tasks = [Collections.Generic.List[System.Threading.Tasks.Task]]::new()
    try {
        [void](Get-StandardCoreV2GitRemainingMilliseconds -ProcessStopwatch $processWatch -Context 'Git blob hash process start')
        if (-not $process.Start()) { throw 'Could not start the trusted Git blob reader.' }
        $started = $true
        [void](Receive-StandardCoreV2GitBoundedProcessStreams -Process $process -ProcessStopwatch $processWatch `
            -StandardOutputDestination $hashDestination -StandardOutputLimitBytes ([long]::MaxValue) `
            -StandardErrorDestination $errorTextStream -StandardErrorLimitBytes $script:StandardCoreV2GitTextOutputLimitBytes `
            -Tasks $tasks -Context 'Git blob hash')
        $hashDestination.FlushFinalBlock()
        $errorText = [Text.UTF8Encoding]::new($false, $true).GetString($errorTextStream.GetBuffer(), 0, [int]$errorTextStream.Length)
        if ($process.ExitCode -ne 0) { throw "Trusted Git blob read failed (exit=$($process.ExitCode)): $errorText" }
        return ([Convert]::ToHexString($hasher.Hash)).ToLowerInvariant()
    }
    catch {
        $cause = $_.Exception.Message
        if ($started) {
            $processId = [int]$process.Id
            $cleanupVerified = Stop-StandardCoreV2GitProcess -Process $process -Tasks $tasks.ToArray()
            $elapsedMilliseconds = Get-StandardCoreV2GitElapsedMilliseconds -ProcessStopwatch $processWatch
            $cleanupLabel = if ($cleanupVerified) { 'verified' } else { 'unverified' }
            throw "Trusted Git blob hash failed: $cause; processId=$processId; elapsedMilliseconds=$elapsedMilliseconds; cleanup=$cleanupLabel."
        }
        throw
    }
    finally { $hashDestination.Dispose(); $errorTextStream.Dispose(); $hasher.Dispose(); $process.Dispose() }
}

function Write-StandardCoreV2GitBlob {
    param(
        [Parameter(Mandatory)][string] $GitPath,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][string] $ObjectId,
        [Parameter(Mandatory)][string] $Destination
    )
    if ($ObjectId -cnotmatch '^[0-9a-f]{40}$') { throw 'The expected Git blob identity is malformed.' }
    $startInfo = New-StandardCoreV2GitProcessStartInfo -GitPath $GitPath `
        -Arguments @('--no-replace-objects', '-C', $RepositoryRoot, 'cat-file', 'blob', $ObjectId)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $file = $null
    $errorTextStream = $null
    $processWatch = [Diagnostics.Stopwatch]::StartNew()
    $started = $false
    $tasks = [Collections.Generic.List[System.Threading.Tasks.Task]]::new()
    try {
        $file = [IO.FileStream]::new($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        [void](Get-StandardCoreV2GitRemainingMilliseconds -ProcessStopwatch $processWatch -Context 'Git blob materialization process start')
        if (-not $process.Start()) { throw 'Could not start the trusted Git blob materializer.' }
        $started = $true
        $errorTextStream = [IO.MemoryStream]::new()
        [void](Receive-StandardCoreV2GitBoundedProcessStreams -Process $process -ProcessStopwatch $processWatch `
            -StandardOutputDestination $file -StandardOutputLimitBytes ([long]::MaxValue) `
            -StandardErrorDestination $errorTextStream -StandardErrorLimitBytes $script:StandardCoreV2GitTextOutputLimitBytes `
            -Tasks $tasks -Context 'Git blob materialization')
        $file.Flush($true)
        $errorText = [Text.UTF8Encoding]::new($false, $true).GetString($errorTextStream.GetBuffer(), 0, [int]$errorTextStream.Length)
        if ($process.ExitCode -ne 0) { throw "Trusted Git blob materialization failed (exit=$($process.ExitCode)): $errorText" }
    }
    catch {
        $cause = $_.Exception.Message
        if ($started) {
            $processId = [int]$process.Id
            $cleanupVerified = Stop-StandardCoreV2GitProcess -Process $process -Tasks $tasks.ToArray()
            $elapsedMilliseconds = if ($null -ne $script:StandardCoreV2GitOperationContext) { Get-StandardCoreV2GitElapsedMilliseconds -ProcessStopwatch $processWatch } else { [long]$processWatch.ElapsedMilliseconds }
            $cleanupLabel = if ($cleanupVerified) { 'verified' } else { 'unverified' }
            $cause = "Trusted Git blob materialization failed: $cause; processId=$processId; elapsedMilliseconds=$elapsedMilliseconds; cleanup=$cleanupLabel."
        }
        if ($null -ne $file) {
            try { $file.Dispose(); $file = $null } catch { }
            try { [IO.File]::Delete($Destination) } catch { }
        }
        throw $cause
    }
    finally {
        if ($null -ne $file) { $file.Dispose() }
        if ($null -ne $errorTextStream) { $errorTextStream.Dispose() }
        $process.Dispose()
    }
}

function Assert-StandardCoreV2GitAttributeTransforms {
    param(
        [Parameter(Mandatory)][string] $GitPath,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Revision,
        [Parameter(Mandatory)] $Tree,
        [Parameter(Mandatory)][string[]] $RejectedAttributeNames
    )
    $attributePaths = [string[]]@($Tree.Keys)
    [Array]::Sort($attributePaths, [StringComparer]::Ordinal)
    $attrArgs = @('--no-replace-objects', '-C', $Root, 'check-attr', '--source', $Revision, '-z', '--all', '--stdin')
    $attributes = Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments $attrArgs -StandardInputNulSeparatedText $attributePaths
    $attributeTokens = @($attributes.StdOut.Split([char]0))
    for ($index = 0; $index + 2 -lt $attributeTokens.Count; $index += 3) {
        $name = [string]$attributeTokens[$index + 1]
        $value = [string]$attributeTokens[$index + 2]
        if ($RejectedAttributeNames -ccontains $name -and $value -cnotin @('unspecified', 'unset')) {
            throw "Candidate Git attributes apply an export or working-tree transform ('$name=$value')."
        }
    }
}

function New-StandardCoreV2GitArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $GitPath,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][string] $OwnedRoot,
        [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $Revision
    )
    $repository = [IO.Path]::GetFullPath($RepositoryRoot)
    $owned = [IO.Path]::GetFullPath($OwnedRoot)
    $archivePath = Assert-StandardCoreV2PathWithin -Path $Destination -Root $owned -Context 'Source archive destination'
    Assert-StandardCoreV2NoReparseAncestors -Path $repository -Context 'Source archive Git metadata root'
    if (Test-Path -LiteralPath $archivePath) { throw 'Source archive destination already exists; FileMode.CreateNew is required.' }

    $topLevel = (Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('--no-replace-objects', '-C', $repository, 'rev-parse', '--show-toplevel')).StdOut.Trim()
    $head = (Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('--no-replace-objects', '-C', $repository, 'rev-parse', '--verify', 'HEAD^{commit}')).StdOut.Trim()
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not [IO.Path]::GetFullPath($topLevel).Equals($repository, $comparison) -or $head -cne $Revision) {
        throw 'Source archive repository top-level or HEAD differs from the bound source revision.'
    }
    $origins = (Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('-C', $repository, 'config', '--local', '--get-all', 'remote.origin.url') -AllowedExitCodes @(0, 1)).StdOut
    if (@($origins -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -ne 0) {
        throw 'Source archive metadata repository must have no origin remotes.'
    }
    $format = (Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('-C', $repository, 'rev-parse', '--show-object-format=storage')).StdOut.Trim()
    if ($format -cne 'sha1') { throw 'Source archive requires the pinned SHA-1 Git object format.' }

    $tree = Get-StandardCoreV2GitTree -GitPath $GitPath -Root $repository -Revision $Revision
    Assert-StandardCoreV2GitAttributeTransforms -GitPath $GitPath -Root $repository -Revision $Revision `
        -Tree $tree -RejectedAttributeNames @('export-ignore', 'export-subst')

    $parent = Split-Path -Parent $archivePath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Source archive parent must already exist under its owned root.' }
    Assert-StandardCoreV2NoReparseAncestors -Path $parent -Context 'Source archive parent'
    $startInfo = New-StandardCoreV2GitProcessStartInfo -GitPath $GitPath `
        -Arguments @('--no-replace-objects', '-C', $repository, '-c', 'core.autocrlf=false', 'archive', '--format=tar', $Revision)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $file = $null
    $errorTextStream = $null
    $createdByThisCall = $false
    $processWatch = [Diagnostics.Stopwatch]::StartNew()
    $started = $false
    $tasks = [Collections.Generic.List[System.Threading.Tasks.Task]]::new()
    try {
        $file = [IO.FileStream]::new($archivePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $createdByThisCall = $true
        [void](Get-StandardCoreV2GitRemainingMilliseconds -ProcessStopwatch $processWatch -Context 'Git archive process start')
        if (-not $process.Start()) { throw 'Could not start the trusted Git archive process.' }
        $started = $true
        $errorTextStream = [IO.MemoryStream]::new()
        [void](Receive-StandardCoreV2GitBoundedProcessStreams -Process $process -ProcessStopwatch $processWatch `
            -StandardOutputDestination $file -StandardOutputLimitBytes $script:StandardCoreV2GitArchiveLimitBytes `
            -StandardErrorDestination $errorTextStream -StandardErrorLimitBytes $script:StandardCoreV2GitTextOutputLimitBytes `
            -Tasks $tasks -Context 'Git archive')
        [void](Get-StandardCoreV2GitRemainingMilliseconds -ProcessStopwatch $processWatch -Context 'Git archive flush')
        $file.Flush($true)
        $errorText = [Text.UTF8Encoding]::new($false, $true).GetString($errorTextStream.GetBuffer(), 0, [int]$errorTextStream.Length)
        if ($process.ExitCode -ne 0) { throw "Trusted Git archive failed (exit=$($process.ExitCode)): $errorText" }
        if ($file.Length -eq 0) { throw 'Trusted Git archive returned an empty byte stream.' }
        $archiveLength = [long]$file.Length
        $file.Dispose()
        $file = $null
        [void](Get-StandardCoreV2GitRemainingMilliseconds -ProcessStopwatch $processWatch -Context 'Git archive SHA-256')
        $archiveSha256 = Get-StandardCoreV2Sha256 -Path $archivePath
        [void](Get-StandardCoreV2GitRemainingMilliseconds -ProcessStopwatch $processWatch -Context 'Git archive completion')
        return [pscustomobject][ordered]@{
            path = $archivePath
            revision = $Revision
            length = $archiveLength
            sha256 = $archiveSha256
        }
    }
    catch {
        $cause = $_.Exception.Message
        if ($started) {
            $processId = [int]$process.Id
            $cleanupVerified = Stop-StandardCoreV2GitProcess -Process $process -Tasks $tasks.ToArray()
            $elapsedMilliseconds = Get-StandardCoreV2GitElapsedMilliseconds -ProcessStopwatch $processWatch
            $cleanupLabel = if ($cleanupVerified) { 'verified' } else { 'unverified' }
            $cause = "Trusted Git archive failed: $cause; processId=$processId; elapsedMilliseconds=$elapsedMilliseconds; cleanup=$cleanupLabel."
        }
        if ($createdByThisCall -and $null -ne $file) {
            try { $file.Dispose(); $file = $null } catch { }
            try { [IO.File]::Delete($archivePath) } catch { }
        }
        throw $cause
    }
    finally {
        if ($null -ne $file) { $file.Dispose() }
        if ($null -ne $errorTextStream) { $errorTextStream.Dispose() }
        $process.Dispose()
    }
}

function Read-StandardCoreV2StrictJson {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Context)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $offset = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes, $offset, $bytes.Length - $offset)
    $document = [System.Text.Json.JsonDocument]::Parse($text)
    try {
        $checkDuplicate = {
            param([System.Text.Json.JsonElement] $Element, [string] $At)
            if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
                $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                foreach ($property in $Element.EnumerateObject()) {
                    if (-not $names.Add($property.Name)) { throw "$At contains a duplicate JSON property '$($property.Name)'" }
                    & $checkDuplicate $property.Value "$At.$($property.Name)"
                }
            }
            elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                $index = 0
                foreach ($item in $Element.EnumerateArray()) { & $checkDuplicate $item "$At[$index]"; $index++ }
            }
        }
        & $checkDuplicate $document.RootElement '$'
    }
    finally { $document.Dispose() }
    return $text | ConvertFrom-Json -Depth 60 -ErrorAction Stop
}

function Assert-StandardCoreV2ExactProperties {
    param([Parameter(Mandatory)] $Value, [Parameter(Mandatory)][string[]] $Names, [Parameter(Mandatory)][string] $Context)
    $actual = @($Value.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($actual.Count -ne $Names.Count -or @($Names | Where-Object { $actual -cnotcontains $_ }).Count -gt 0 -or
        @($actual | Where-Object { $Names -cnotcontains $_ }).Count -gt 0) {
        throw "$Context has an invalid property set."
    }
}

function Get-StandardCoreV2ToolInstallParent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string] $RunId)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    return [IO.Path]::GetFullPath((Join-Path $tempRoot "corev2-$RunId"))
}

function Get-StandardCoreV2SkillSpectorPathHeadroom {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $InstallParent, [Parameter(Mandatory)][string] $DeepArtifactsInstallParent)
    $probeLeaf = 'ss-000000000000'
    $suffix = Join-Path 'venv/Lib/site-packages' (('p' * 96) + '.probe')
    $currentProbe = [IO.Path]::GetFullPath((Join-Path (Join-Path $InstallParent $probeLeaf) $suffix))
    $deepProbe = [IO.Path]::GetFullPath((Join-Path (Join-Path $DeepArtifactsInstallParent $probeLeaf) $suffix))
    $limitExclusive = 248
    if ($currentProbe.Length -ge $limitExclusive) { throw "Deterministic SkillSpector install parent leaves insufficient Windows path headroom: $($currentProbe.Length) characters." }
    return [pscustomobject][ordered]@{
        limitExclusive = $limitExclusive
        currentProbePath = $currentProbe
        currentProbeLength = $currentProbe.Length
        currentHeadroom = $limitExclusive - $currentProbe.Length
        deepArtifactsProbePath = $deepProbe
        deepArtifactsProbeLength = $deepProbe.Length
        deepArtifactsWouldPass = ($deepProbe.Length -lt $limitExclusive)
    }
}

function Assert-StandardCoreV2ResolverReceiptPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Receipt,
        [Parameter(Mandatory)][string] $ExpectedInstallParent,
        [Parameter(Mandatory)][string] $ExpectedRunId,
        [Parameter(Mandatory)][string] $CandidateRoot,
        [Parameter(Mandatory)][string] $ArtifactsRoot
    )
    $tool = [string]$Receipt.toolName
    if ($tool -cnotin @('skill-validator','skill-tools','skillspector')) { throw 'Resolver receipt names an unsupported source tool.' }
    if ($ExpectedRunId -cnotmatch '^[0-9a-f]{32}$' -or [int]$Receipt.schemaVersion -ne 1 -or
        [string]$Receipt.resolutionRunId -cne $ExpectedRunId -or $Receipt.frozenForRun -isnot [bool] -or -not $Receipt.frozenForRun -or
        [string]$Receipt.installedClosureSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "Resolver receipt does not bind the current run or complete installed closure: $tool"
    }
    $installParent = [IO.Path]::GetFullPath($ExpectedInstallParent).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $installRoot = [IO.Path]::GetFullPath([string]$Receipt.installRoot)
    $candidate = [IO.Path]::GetFullPath($CandidateRoot)
    $artifacts = [IO.Path]::GetFullPath($ArtifactsRoot)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $installDirectory = [IO.DirectoryInfo]::new($installRoot)
    $expectedLeafPattern = switch ($tool) {
        'skill-validator' { '^skill-validator-[0-9a-f]{32}$' }
        'skill-tools' { '^skill-tools-[0-9a-f]{32}$' }
        'skillspector' { '^ss-[0-9a-f]{12}$' }
    }
    if ($null -eq $installDirectory.Parent -or -not $installDirectory.Parent.FullName.Equals($installParent,$comparison) -or
        [IO.Path]::GetFileName($installRoot) -cnotmatch $expectedLeafPattern) {
        throw "Resolver receipt install root is not a direct run-owned tool child for $tool."
    }
    Assert-StandardCoreV2NoReparseAncestors -Path $installParent -Context 'Resolver tool install parent'
    Assert-StandardCoreV2NoReparseAncestors -Path $installRoot -Context "Resolver tool install root $tool"
    foreach ($name in @('executablePath')) {
        $path = [IO.Path]::GetFullPath([string]$Receipt.$name)
        if (-not ($path.Equals($installRoot,$comparison) -or $path.StartsWith($installRoot.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar,$comparison))) {
            throw "Resolver receipt executable escaped its exact install root: $tool"
        }
        Assert-StandardCoreV2NoReparseAncestors -Path $path -Context "Resolver receipt $tool executable"
        if ((Get-StandardCoreV2Sha256 -Path $path) -cne [string]$Receipt.executableSha256) { throw "Resolver receipt executable hash changed: $tool" }
    }
    if ($tool -ceq 'skill-tools') {
        foreach ($name in @('nodePath','entryPointPath')) {
            if (-not $Receipt.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$Receipt.$name)) { throw "Resolver receipt omits skill-tools $name." }
        }
        $nodePath = [IO.Path]::GetFullPath([string]$Receipt.nodePath)
        $entryPath = [IO.Path]::GetFullPath([string]$Receipt.entryPointPath)
        foreach ($root in @($candidate,$artifacts)) {
            $fullRoot = $root.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
            if ($nodePath.Equals($fullRoot,$comparison) -or $nodePath.StartsWith($fullRoot+[IO.Path]::DirectorySeparatorChar,$comparison)) {
                throw 'Resolver Node runtime must remain outside candidate and ArtifactsRoot.'
            }
        }
        $installPrefix = $installRoot.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
        if (-not $entryPath.StartsWith($installPrefix,$comparison)) { throw 'Resolver skill-tools payload escaped its exact install root.' }
        if ([IO.Path]::GetFileName($nodePath).ToLowerInvariant() -notin @('node','node.exe','nodejs','nodejs.exe')) { throw 'Resolver skill-tools runtime is not an approved Node executable.' }
        Assert-StandardCoreV2NoReparseAncestors -Path $nodePath -Context 'Resolver Node runtime'
        Assert-StandardCoreV2NoReparseAncestors -Path $entryPath -Context 'Resolver skill-tools entry point'
        if ((Get-StandardCoreV2Sha256 -Path $nodePath) -cne [string]$Receipt.nodeSha256 -or
            (Get-StandardCoreV2Sha256 -Path $entryPath) -cne [string]$Receipt.entryPointSha256) { throw 'Resolver skill-tools runtime or entry-point hash changed.' }
        if ([string]$Receipt.launcher.runtimePath -cne [string]$Receipt.nodePath -or [string]$Receipt.launcher.runtimeSha256 -cne [string]$Receipt.nodeSha256 -or
            [string]$Receipt.launcher.payloadPath -cne [string]$Receipt.entryPointPath -or [string]$Receipt.launcher.payloadSha256 -cne [string]$Receipt.entryPointSha256) {
            throw 'Resolver skill-tools launcher differs from its runtime or payload receipt.'
        }
    }
    elseif ([string]$Receipt.launcher.kind -cne 'direct-executable') { throw "Resolver native tool does not use a direct executable: $tool" }
    return [pscustomobject]@{ toolName=$tool; installRoot=$installRoot; executablePath=[IO.Path]::GetFullPath([string]$Receipt.executablePath) }
}

function New-StandardCoreV2ResolverArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ResolverPath,
        [Parameter(Mandatory)][string] $PolicyPath,
        [Parameter(Mandatory)][ValidateSet('skill-validator', 'skill-tools', 'skillspector')][string] $ToolName,
        [Parameter(Mandatory)][string] $InstallRoot,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $OutputPath,
        [ValidateRange(1, 3600)][int] $AcquisitionTimeoutSeconds = 3600,
        [string] $ExpectedGoRuntimeVersion
    )
    if ($RunId -cnotmatch '^[0-9a-f]{32}$') { throw 'Resolver argument RunId must be a lowercase 32-character hexadecimal value.' }
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-File', [IO.Path]::GetFullPath($ResolverPath),
        '-PolicyPath', [IO.Path]::GetFullPath($PolicyPath), '-ToolName', $ToolName, '-Install',
        '-InstallRoot', [IO.Path]::GetFullPath($InstallRoot), '-RunId', $RunId,
        '-AcquisitionTimeoutSeconds', $AcquisitionTimeoutSeconds.ToString([Globalization.CultureInfo]::InvariantCulture),
        '-OutputPath', [IO.Path]::GetFullPath($OutputPath)
    )
    if (-not [string]::IsNullOrWhiteSpace($ExpectedGoRuntimeVersion)) {
        $arguments += @('-ExpectedGoRuntimeVersion', $ExpectedGoRuntimeVersion)
    }
    return [string[]]$arguments
}

function New-StandardCoreV2CoreRunnerArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $LiveCandidateRoot,
        [Parameter(Mandatory)][string] $RawCandidateRoot,
        [Parameter(Mandatory)][string] $RunnerPath,
        [Parameter(Mandatory)][string] $AdapterPath,
        [Parameter(Mandatory)][string] $ArtifactsRoot,
        [Parameter(Mandatory)][string] $OutputPath,
        [Parameter(Mandatory)][string] $SourceRepository,
        [Parameter(Mandatory)][string] $SourceRevision,
        [Parameter(Mandatory)][string] $BaseRevision,
        [Parameter(Mandatory)][string] $EventName,
        [Parameter(Mandatory)][string] $AuthorityRevision,
        [Parameter(Mandatory)][string] $TimeoutSeconds,
        [Parameter(Mandatory)][string] $TrustedToolRoot,
        [Parameter(Mandatory)][string] $RunId
    )
    $live = [IO.Path]::GetFullPath($LiveCandidateRoot)
    $raw = [IO.Path]::GetFullPath($RawCandidateRoot)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if ($live.Equals($raw,$comparison)) { throw 'Core v2 must run from the isolated raw candidate clone, not the live source checkout.' }
    return [string[]]@('-NoProfile','-NonInteractive','-File',[IO.Path]::GetFullPath($RunnerPath),
        '-CandidateRoot',$raw,'-AdapterPath',[IO.Path]::GetFullPath($AdapterPath),'-ArtifactsRoot',[IO.Path]::GetFullPath($ArtifactsRoot),'-OutputPath',[IO.Path]::GetFullPath($OutputPath),
        '-SourceRepository',$SourceRepository,'-SourceRevision',$SourceRevision,'-BaseRevision',$BaseRevision,'-EventName',$EventName,'-AuthorityRevision',$AuthorityRevision,
        '-TimeoutSeconds',$TimeoutSeconds,'-TrustedToolRoot',[IO.Path]::GetFullPath($TrustedToolRoot),'-SourceValidation','-RunId',$RunId)
}

function Read-StandardCoreV2PreparationProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ConfigPath)
    Assert-StandardCoreV2NoReparseAncestors -Path $ConfigPath -Context 'Standard Core v2 preparation profile'
    if ((Get-StandardCoreV2Sha256 -Path $ConfigPath) -cne $script:StandardCoreV2PreparationProfileSha256) {
        throw 'Dormant Standard Core v2 preparation profile bytes do not match the protected driver pin.'
    }
    $profile = Read-StandardCoreV2StrictJson -Path $ConfigPath -Context 'Standard Core v2 preparation profile'
    Assert-StandardCoreV2ExactProperties -Value $profile -Names @('schemaVersion', 'profile', 'status', 'activation', 'authority', 'source', 'sourceValidation', 'checks') -Context 'Standard Core v2 preparation profile'
    if ($profile.schemaVersion -ne 1 -or $profile.profile -cne 'standard-core-v2-source-validation-preparation' -or
        $profile.status -cne 'dormant' -or [string]$profile.authority.commit -cne $script:StandardCoreV2AuthorityCommit -or
        [string]$profile.authority.archiveSha256 -cne $script:StandardCoreV2AuthorityArchiveSha256 -or
        [string]$profile.authority.repository -cne $script:StandardCoreV2AuthorityRepository -or
        [string]$profile.source.repository -cne $script:StandardCoreSourceRepository -or
        [string]$profile.source.skillsRoot -cne 'skills' -or [string]$profile.source.activeSkillsSource -cne 'catalog/source.json') {
        throw 'Dormant Standard Core v2 preparation profile identity is invalid.'
    }
    if ($null -eq $profile.sourceValidation -or $profile.sourceValidation.requiredSlots -isnot [array] -or
        (@($profile.sourceValidation.requiredSlots) -join ';') -cne 'packageAdapter;skillValidator;skillTools;staticAnalyzer;frozenFiles;toolReceipts' -or
        [string]$profile.sourceValidation.testSelection -cne 'complete-unfiltered-candidate-tests' -or
        [string]$profile.sourceValidation.testCaseSidecar -cne 'repository-pester-case-inventory-v1.json') {
        throw 'Dormant Standard Core v2 source validation slots or Pester inventory contract are incomplete.'
    }
    $linkedPaths = @(
        'docs/standards/third-party-raw-skill-sources.md',
        'docs/standards/schemas/third-party-raw-skill-source-v1.schema.json',
        'docs/standards/examples/third-party-raw-skill-source-v1.json'
    )
    if ($profile.authority.files -isnot [array] -or @($profile.authority.files).Count -ne 32 -or
        [int]$profile.authority.ordinaryFileCount -ne 29 -or [int]$profile.authority.linkedThirdPartyFileCount -ne 3) {
        throw 'Dormant Standard Core v2 authority inventory is not the exact full32 tuple.'
    }
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $ordinary = 0
    $linked = 0
    foreach ($entry in $profile.authority.files) {
        Assert-StandardCoreV2ExactProperties -Value $entry -Names @('path', 'sha256', 'set') -Context 'Standard Core v2 authority tuple entry'
        $path = [string]$entry.path
        if ($path -cnotmatch '^[A-Za-z0-9._/-]+$' -or $path.Contains('..') -or -not $paths.Add($path) -or
            [string]$entry.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Dormant Standard Core v2 authority tuple contains an unsafe or duplicate entry.' }
        $expectedSet = if ($linkedPaths -ccontains $path) { 'linked-third-party-contract' } else { 'ordinary-core' }
        if ([string]$entry.set -cne $expectedSet) { throw "Dormant Standard Core v2 authority tuple classification differs for '$path'." }
        if ($expectedSet -eq 'ordinary-core') { $ordinary++ } else { $linked++ }
    }
    if ($ordinary -ne 29 -or $linked -ne 3) { throw 'Dormant Standard Core v2 authority tuple must contain 29 ordinary and 3 linked records.' }
    if ($profile.checks -isnot [array] -or @($profile.checks).Count -ne 2) { throw 'Dormant Standard Core v2 must declare exactly the general and Pester checks.' }
    $expectedIds = @('repository-general', 'repository-pester')
    for ($index = 0; $index -lt 2; $index++) {
        $check = $profile.checks[$index]
        Assert-StandardCoreV2ExactProperties -Value $check -Names @('id', 'kind', 'script', 'arguments') -Context 'Dormant Standard Core v2 check template'
        if ([string]$check.id -cne $expectedIds[$index] -or [string]$check.kind -cne @('general', 'pester')[$index] -or $check.arguments -isnot [array]) {
            throw 'Dormant Standard Core v2 check template identity is invalid.'
        }
    }
    if ([string]$profile.checks[0].script -cne 'scripts/Invoke-CoreRepositoryGeneral.ps1' -or
        @($profile.checks[0].arguments).Count -ne 2 -or
        [string]$profile.checks[0].arguments[0] -cne '-SourceBindingSha256' -or
        [string]$profile.checks[0].arguments[1] -cne '<source-binding-sha256>' -or
        [string]$profile.checks[1].script -cne 'scripts/Invoke-CorePester.ps1' -or
        @($profile.checks[1].arguments).Count -ne 0) {
        throw 'Dormant Standard Core v2 check arguments differ from the protected digest-only general and unfiltered Pester contracts.'
    }
    return $profile
}

function Resolve-StandardCoreV2Dispatch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $BoundParameters)

    $keys = @($BoundParameters.Keys | ForEach-Object { [string]$_ })
    $prepare = ($keys -ccontains 'PrepareSourceTools') -and [bool]$BoundParameters['PrepareSourceTools']
    $source = ($keys -ccontains 'SourceValidation') -and [bool]$BoundParameters['SourceValidation']
    $sourcePathBound = $keys -ccontains 'SourceToolsPath'
    $authorityRootBound = $keys -ccontains 'AuthorityRepositoryRoot'
    $trustedRootBound = $keys -ccontains 'TrustedToolRoot'
    $operationTimeoutBound = $keys -ccontains 'OperationTimeoutSeconds'

    if ($prepare -and $source) { throw 'PrepareSourceTools and SourceValidation are separate setup and execution requests.' }
    if (-not ($prepare -or $source)) {
        if ($sourcePathBound -or $authorityRootBound -or $trustedRootBound -or $operationTimeoutBound) {
            throw 'Core v2 source setup parameters require explicit PrepareSourceTools or SourceValidation selection.'
        }
        return [pscustomobject]@{ Mode = 'LegacyV1'; IsCoreV2 = $false }
    }

    if (($keys -ccontains 'SourceConformance') -and [bool]$BoundParameters['SourceConformance']) {
        throw 'SourceConformance cannot be combined with Core v2 source setup or validation.'
    }
    foreach ($name in @('ProtectedPesterServerProxy', 'ProtectedPesterSupervisor')) {
        if (($keys -ccontains $name) -and [bool]$BoundParameters[$name]) {
            throw "Core v2 source setup or validation cannot be combined with legacy '$name'."
        }
    }
    foreach ($name in @(
        'AuthorityArchivePath', 'BaseCommitInput', 'PesterWorkerPath', 'PesterTestsRoot', 'PesterModulePath',
        'PesterExpectedVersion', 'PesterMirrorRoot', 'PesterInstallRoot', 'PesterSupervisorPath',
        'PesterChildWritableRoot', 'PesterDiagnosticRoot', 'PesterRunnerSha256', 'PesterProxyPowerShellPath',
        'PesterProxyWorkingDirectory', 'PesterProxyDiagnosticRoot', 'PesterProxyChildWritableRoot',
        'PesterProxyReadOnlyPathsJson'
    )) {
        if ($keys -ccontains $name) { throw "Core v2 source setup or validation rejects legacy override '$name'." }
    }
    if (($keys -ccontains 'BaseCommitSource') -and [string]$BoundParameters['BaseCommitSource'] -cne 'caller-supplied') {
        throw 'Core v2 source setup or validation does not accept a legacy base-source override.'
    }
    if (($keys -ccontains 'SemanticCredentialNames') -and @($BoundParameters['SemanticCredentialNames']).Count -gt 0) {
        throw 'Core v2 source setup or validation does not accept legacy semantic credential names.'
    }
    if (-not $sourcePathBound -or [string]::IsNullOrWhiteSpace([string]$BoundParameters['SourceToolsPath'])) {
        throw 'Explicit Core v2 source setup or validation requires SourceToolsPath.'
    }
    if (-not $authorityRootBound -or [string]::IsNullOrWhiteSpace([string]$BoundParameters['AuthorityRepositoryRoot'])) {
        throw 'Explicit Core v2 source setup or validation requires AuthorityRepositoryRoot.'
    }
    foreach ($name in @('RepositoryRoot', 'TrustedToolRoot', 'BaseCommit')) {
        if (-not ($keys -ccontains $name) -or [string]::IsNullOrWhiteSpace([string]$BoundParameters[$name])) {
            throw "Explicit Core v2 source setup or validation requires $name."
        }
    }
    return [pscustomobject]@{ Mode = if ($prepare) { 'PrepareSourceTools' } else { 'SourceValidation' }; IsCoreV2 = $true }
}

function Get-StandardCoreV2RemainingSeconds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1,14400)][int] $OperationTimeoutSeconds,
        [Parameter(Mandatory)][ValidateRange(0,[long]::MaxValue)][long] $ElapsedMilliseconds,
        [Parameter(Mandatory)][string] $Context
    )
    $remainingMilliseconds=([long]$OperationTimeoutSeconds*1000)-$ElapsedMilliseconds
    $remainingSeconds=[long][Math]::Floor($remainingMilliseconds/1000.0)
    if($remainingSeconds -lt 1){throw "$Context exhausted the aggregate operation deadline; elapsedMilliseconds=$ElapsedMilliseconds; operationTimeoutSeconds=$OperationTimeoutSeconds."}
    return [int]$remainingSeconds
}

function Get-StandardCoreV2ChildBudget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1,14400)][int] $OperationTimeoutSeconds,
        [Parameter(Mandatory)][ValidateRange(1,3600)][int] $ChildLimitSeconds,
        [Parameter(Mandatory)][ValidateRange(0,[long]::MaxValue)][long] $ElapsedMilliseconds,
        [Parameter(Mandatory)][string] $Context
    )
    $remainingSeconds=Get-StandardCoreV2RemainingSeconds -OperationTimeoutSeconds $OperationTimeoutSeconds `
        -ElapsedMilliseconds $ElapsedMilliseconds -Context $Context
    return [int][Math]::Min($remainingSeconds,[long]$ChildLimitSeconds)
}

function Get-StandardCoreV2GitTree {
    param([Parameter(Mandatory)][string] $GitPath, [Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $Revision)
    $result = Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('--no-replace-objects', '-C', $Root, 'ls-tree', '-r', '-z', '--full-tree', $Revision)
    $entries = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $folded = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in @($result.StdOut.Split([char]0) | Where-Object { $_ -ne '' })) {
        if ([string]$record -cnotmatch '^(?<mode>100644|100755) blob (?<oid>[0-9a-f]{40})\t(?<path>[^\x00\r\n]+)$') { throw "Git tree contains an unsupported or malformed entry: $record" }
        $mode = [string]$Matches.mode
        $objectId = [string]$Matches.oid
        $path = [string]$Matches.path
        $unsafeSegments = @($path.Split('/') | Where-Object {
            $_ -in @('', '.', '..') -or $_ -match '[<>:"|?*]' -or $_.EndsWith('.') -or $_.EndsWith(' ') -or
            $_ -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$'
        })
        if ($path.StartsWith('/') -or $path.Contains('\') -or $unsafeSegments.Count -gt 0) {
            throw "Git tree contains a path that cannot be safely materialized: $path"
        }
        if (-not $folded.Add($path) -or -not $entries.TryAdd($path, [pscustomobject]@{ mode=$mode; objectId=$objectId })) {
            throw "Git tree contains a duplicate or case-colliding path: $path"
        }
    }
    if ($entries.Count -eq 0) { throw 'Git tree contains no tracked files.' }
    return $entries
}

function Assert-StandardCoreV2ProtectedCandidateFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $GitPath,
        [Parameter(Mandatory)][string] $CandidateRoot,
        [Parameter(Mandatory)][string] $ExpectedRevision,
        [Parameter(Mandatory)][object[]] $ProtectedFiles
    )
    if ($ExpectedRevision -cnotmatch '^[0-9a-f]{40}$' -or $ProtectedFiles.Count -eq 0) {
        throw 'Protected candidate file binding identity or inventory is malformed.'
    }
    $root = [IO.Path]::GetFullPath($CandidateRoot)
    Assert-StandardCoreV2NoReparseAncestors -Path $root -Context 'Protected candidate snapshot'
    $tree = Get-StandardCoreV2GitTree -GitPath $GitPath -Root $root -Revision $ExpectedRevision
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in $ProtectedFiles) {
        Assert-StandardCoreV2ExactProperties -Value $record -Names @('candidatePath', 'protectedPath', 'expectedMode', 'expectedSha256') -Context 'Protected candidate file pin'
        $relativePath = [string]$record.candidatePath
        $expectedMode = [string]$record.expectedMode
        $expectedSha256 = [string]$record.expectedSha256
        if ($relativePath -cnotmatch '^[A-Za-z0-9._/-]+$' -or $relativePath.StartsWith('/') -or $relativePath.Contains('\') -or
            @($relativePath.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0 -or
            $expectedMode -cnotmatch '^100(?:644|755)$' -or $expectedSha256 -cnotmatch '^[0-9a-f]{64}$' -or
            -not $seen.Add($relativePath)) {
            throw 'Protected candidate file pin contains an unsafe path, malformed identity, or duplicate entry.'
        }
        if (-not $tree.ContainsKey($relativePath)) { throw "Protected candidate commit omits pinned file '$relativePath'." }
        $entry = $tree[$relativePath]
        if ([string]$entry.mode -cne $expectedMode) { throw "Protected candidate mode differs from protected driver mode: $relativePath" }
        $candidatePath = Join-Path $root ($relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))
        Assert-StandardCoreV2NoReparseAncestors -Path $candidatePath -Context "Protected candidate file '$relativePath'"
        $candidateHash = Get-StandardCoreV2Sha256 -Path $candidatePath
        $candidateBlobHash = Get-StandardCoreV2GitBlobSha256 -GitPath $GitPath -RepositoryRoot $root -ObjectId ([string]$entry.objectId)
        if ($candidateBlobHash -cne $expectedSha256 -or $candidateHash -cne $expectedSha256) {
            throw "Protected candidate bytes differ from protected driver bytes: $relativePath"
        }
        $protectedPath = [IO.Path]::GetFullPath([string]$record.protectedPath)
        Assert-StandardCoreV2NoReparseAncestors -Path $protectedPath -Context "Protected driver file '$relativePath'"
        if ((Get-StandardCoreV2Sha256 -Path $protectedPath) -cne $expectedSha256) {
            throw "Protected candidate bytes differ from protected driver bytes: $relativePath"
        }
    }
    return [pscustomobject]@{ FileCount = $seen.Count; Revision = $ExpectedRevision }
}

function Assert-StandardCoreV2AuthorityTuple {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Profile,
        [Parameter(Mandatory)][string] $GitPath,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [switch] $RequireWorkingTree
    )
    $authority = $Profile.authority
    if ($null -eq $authority -or [string]$authority.commit -cnotmatch '^[0-9a-f]{40}$' -or
        [string]$authority.repository -cne $script:StandardCoreV2AuthorityRepository -or
        [string]$authority.archiveSha256 -cne $script:StandardCoreV2AuthorityArchiveSha256 -or
        $authority.files -isnot [array] -or @($authority.files).Count -ne 32 -or
        [int]$authority.ordinaryFileCount -ne 29 -or [int]$authority.linkedThirdPartyFileCount -ne 3) {
        throw 'Authority tuple profile is not the protected full32 identity.'
    }

    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    Assert-StandardCoreV2NoReparseAncestors -Path $root -Context 'Pinned authority repository root'
    $top = (Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('--no-replace-objects', '-C', $root, 'rev-parse', '--show-toplevel')).StdOut.Trim()
    $head = (Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('--no-replace-objects', '-C', $root, 'rev-parse', '--verify', 'HEAD^{commit}')).StdOut.Trim()
    $objectFormat = (Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('--no-replace-objects', '-C', $root, 'rev-parse', '--show-object-format=storage')).StdOut.Trim()
    $alternatePath = (Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('-C', $root, 'rev-parse', '--git-path', 'objects/info/alternates')).StdOut.Trim()
    if (-not [IO.Path]::IsPathRooted($alternatePath)) { $alternatePath = Join-Path $root $alternatePath }
    $originResult = Invoke-StandardCoreV2GitText -GitPath $GitPath `
        -Arguments @('-C', $root, 'config', '--local', '--get-all', 'remote.origin.url') -AllowedExitCodes @(0, 1)
    [string[]]$origins = @($originResult.StdOut -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not [IO.Path]::GetFullPath($top).Equals($root, $comparison) -or
        $head -cne [string]$authority.commit -or $objectFormat -cne 'sha1' -or
        (Test-Path -LiteralPath $alternatePath) -or $origins.Count -ne 1 -or
        $origins[0] -cne [string]$authority.repository) {
        throw 'Authority Git root, origin, revision, or object-store identity differs from the pinned tuple.'
    }

    $linkedPaths = @(
        'docs/standards/third-party-raw-skill-sources.md',
        'docs/standards/schemas/third-party-raw-skill-source-v1.schema.json',
        'docs/standards/examples/third-party-raw-skill-source-v1.json'
    )
    $expectedFiles = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $ordinaryCount = 0
    $linkedCount = 0
    foreach ($record in $authority.files) {
        Assert-StandardCoreV2ExactProperties -Value $record -Names @('path', 'sha256', 'set') -Context 'Pinned authority file tuple entry'
        $relativePath = [string]$record.path
        $expectedSet = if ($linkedPaths -ccontains $relativePath) { 'linked-third-party-contract' } else { 'ordinary-core' }
        if ($relativePath -cnotmatch '^[A-Za-z0-9._/-]+$' -or $relativePath.Contains('..') -or
            [string]$record.sha256 -cnotmatch '^[0-9a-f]{64}$' -or [string]$record.set -cne $expectedSet -or
            -not $expectedFiles.TryAdd($relativePath, $record)) {
            throw 'Pinned authority file tuple contains a malformed, unsafe, or duplicate path/hash record.'
        }
        if ($expectedSet -ceq 'ordinary-core') { $ordinaryCount++ } else { $linkedCount++ }
    }
    if ($ordinaryCount -ne 29 -or $linkedCount -ne 3) { throw 'Pinned authority file tuple does not contain exactly 29 ordinary and 3 linked records.' }

    $tree = Get-StandardCoreV2GitTree -GitPath $GitPath -Root $root -Revision ([string]$authority.commit)
    foreach ($relativePath in $expectedFiles.Keys) {
        if (-not $tree.ContainsKey($relativePath)) { throw "Pinned authority commit omits tuple path '$relativePath'." }
        $entry = $tree[$relativePath]
        $actualHash = Get-StandardCoreV2GitBlobSha256 -GitPath $GitPath -RepositoryRoot $root -ObjectId ([string]$entry.objectId)
        if ($actualHash -cne [string]$expectedFiles[$relativePath].sha256) {
            throw "Pinned authority raw Git blob SHA-256 differs for '$relativePath'."
        }
        if ($RequireWorkingTree) {
            $worktreePath = Join-Path $root ($relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))
            if (-not (Test-Path -LiteralPath $worktreePath -PathType Leaf)) { throw "Pinned authority worktree omits '$relativePath'." }
            Assert-StandardCoreV2NoReparseAncestors -Path $worktreePath -Context "Pinned authority worktree file '$relativePath'"
            $worktreeHash = Get-StandardCoreV2Sha256 -Path $worktreePath
            if ($worktreeHash -cne [string]$expectedFiles[$relativePath].sha256) {
                throw "Pinned authority raw worktree SHA-256 differs for '$relativePath'."
            }
            $worktreeBlob = (Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @(
                    '--no-replace-objects', '-C', $root, 'hash-object', '--no-filters', '--', $worktreePath
                )).StdOut.Trim()
            if ($worktreeBlob -cne [string]$entry.objectId) {
                throw "Pinned authority worktree bytes do not match the raw Git blob for '$relativePath'."
            }
        }
    }
    return [pscustomobject]@{
        RepositoryRoot = $root
        Repository = [string]$authority.repository
        Commit = [string]$authority.commit
        FileCount = $expectedFiles.Count
        OrdinaryFileCount = $ordinaryCount
        LinkedThirdPartyFileCount = $linkedCount
        ArchiveSha256 = [string]$authority.archiveSha256
    }
}

function New-StandardCoreV2AuthorityMaterialization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Profile,
        [Parameter(Mandatory)][string] $GitPath,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][string] $OwnedRoot,
        [Parameter(Mandatory)][string] $Destination
    )
    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $owned = [IO.Path]::GetFullPath($OwnedRoot)
    $destinationFull = Assert-StandardCoreV2PathWithin -Path $Destination -Root $owned -Context 'Pinned authority materialization destination'
    Assert-StandardCoreV2AuthorityTuple -Profile $Profile -GitPath $GitPath -RepositoryRoot $root | Out-Null
    if (Test-Path -LiteralPath $destinationFull) { throw 'Pinned authority materialization destination already exists.' }
    [void][IO.Directory]::CreateDirectory($destinationFull)
    Assert-StandardCoreV2NoReparseAncestors -Path $destinationFull -Context 'Pinned authority materialization root'
    $tree = Get-StandardCoreV2GitTree -GitPath $GitPath -Root $root -Revision ([string]$Profile.authority.commit)
    $materialized = [Collections.Generic.List[object]]::new()
    foreach ($record in $Profile.authority.files) {
        $relativePath = [string]$record.path
        if (-not $tree.ContainsKey($relativePath)) { throw "Pinned authority commit omits tuple path '$relativePath'." }
        $target = [IO.Path]::GetFullPath((Join-Path $destinationFull ($relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))))
        [void](Assert-StandardCoreV2PathWithin -Path $target -Root $destinationFull -Context "Pinned authority file '$relativePath'")
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        Assert-StandardCoreV2NoReparseAncestors -Path (Split-Path -Parent $target) -Context "Pinned authority file parent '$relativePath'"
        Write-StandardCoreV2GitBlob -GitPath $GitPath -RepositoryRoot $root -ObjectId ([string]$tree[$relativePath].objectId) -Destination $target
        Assert-StandardCoreV2NoReparseAncestors -Path $target -Context "Materialized pinned authority file '$relativePath'"
        $actualSha256 = Get-StandardCoreV2Sha256 -Path $target
        if ($actualSha256 -cne [string]$record.sha256) { throw "Materialized pinned authority raw bytes differ for '$relativePath'." }
        $materialized.Add([pscustomobject]@{ path=$relativePath; mode=[string]$tree[$relativePath].mode; sha256=$actualSha256; objectId=[string]$tree[$relativePath].objectId })
    }
    if ($materialized.Count -ne 32) { throw 'Pinned authority materialization did not produce the exact full32 tuple.' }
    return [pscustomobject]@{ Root=$destinationFull; Commit=[string]$Profile.authority.commit; FileCount=$materialized.Count; Files=@($materialized.ToArray()) }
}

function Assert-StandardCoreV2RawCheckout {
    param([Parameter(Mandatory)][string] $GitPath, [Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $Revision)
    $tree = Get-StandardCoreV2GitTree -GitPath $GitPath -Root $Root -Revision $Revision
    Assert-StandardCoreV2GitAttributeTransforms -GitPath $GitPath -Root $Root -Revision $Revision `
        -Tree $tree -RejectedAttributeNames @('filter', 'working-tree-encoding', 'ident', 'export-ignore', 'export-subst')
    foreach ($path in $tree.Keys) {
        $fullPath = Join-Path $Root ($path.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Raw candidate checkout is missing tracked file '$path'." }
        Assert-StandardCoreV2NoReparseAncestors -Path $fullPath -Context "Raw candidate file '$path'"
        $blobId = (Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('--no-replace-objects', '-C', $Root, 'hash-object', '--no-filters', '--', $fullPath)).StdOut.Trim()
        if ($blobId -cne [string]$tree[$path].objectId) { throw "Raw candidate checkout bytes differ from the committed Git blob for '$path'." }
    }
    $index = Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('--no-replace-objects', '-C', $Root, 'ls-files', '--stage', '-z')
    $indexEntries = @($index.StdOut.Split([char]0) | Where-Object { $_ -ne '' })
    if ($indexEntries.Count -ne $tree.Count) { throw 'Raw candidate checkout index inventory differs from the committed tree.' }
    foreach ($entry in $indexEntries) {
        if ([string]$entry -cnotmatch '^(?<mode>100644|100755) (?<oid>[0-9a-f]{40}) 0\t(?<path>[^\x00\r\n]+)$' -or
            -not $tree.ContainsKey([string]$Matches.path) -or [string]$Matches.mode -cne [string]$tree[[string]$Matches.path].mode -or
            [string]$Matches.oid -cne [string]$tree[[string]$Matches.path].objectId) {
            throw 'Raw candidate checkout index paths, modes, or blob identities differ from the committed tree.'
        }
    }
    $status = Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('--no-replace-objects', '-C', $Root, 'status', '--porcelain=v1', '--untracked-files=all')
    if (-not [string]::IsNullOrEmpty($status.StdOut)) { throw 'Raw candidate checkout is not clean after byte verification.' }
    return $tree
}

function New-StandardCoreV2RawCandidateClone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $GitPath,
        [Parameter(Mandatory)][string] $SourceRoot,
        [Parameter(Mandatory)][string] $OwnedRoot,
        [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][string] $ExpectedRevision,
        [string] $ExpectedSourceRepository = $script:StandardCoreSourceRepository
    )
    if ($ExpectedRevision -cnotmatch '^[0-9a-f]{40}$') { throw 'Raw candidate clone requires a full SHA-1 source revision.' }
    $source = [IO.Path]::GetFullPath($SourceRoot)
    $owned = [IO.Path]::GetFullPath($OwnedRoot)
    $destinationFull = Assert-StandardCoreV2PathWithin -Path $Destination -Root $owned -Context 'Raw candidate clone destination'
    Assert-StandardCoreV2NoReparseAncestors -Path $source -Context 'Source candidate Git root'
    if (Test-Path -LiteralPath $destinationFull) { throw 'Raw candidate clone destination already exists.' }
    $head = (Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('--no-replace-objects', '-C', $source, 'rev-parse', '--verify', 'HEAD^{commit}')).StdOut.Trim()
    if ($head -cne $ExpectedRevision) { throw 'Live candidate HEAD differs from the expected source revision.' }
    $originOutput = (Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('-C', $source, 'config', '--local', '--get-all', 'remote.origin.url')).StdOut
    [string[]]$origins = @($originOutput -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $originMatches = $false
    if ($origins.Count -eq 1) {
        if ($PSBoundParameters.ContainsKey('ExpectedSourceRepository')) {
            $originMatches = [string]$origins[0] -ceq $ExpectedSourceRepository
        }
        else {
            $withoutGitSuffix = if ($ExpectedSourceRepository.EndsWith('.git', [StringComparison]::Ordinal)) {
                $ExpectedSourceRepository.Substring(0, $ExpectedSourceRepository.Length - 4)
            }
            else { $ExpectedSourceRepository }
            $originMatches = [string]$origins[0] -ceq $ExpectedSourceRepository -or
                [string]$origins[0] -ceq $withoutGitSuffix
        }
    }
    if (-not $originMatches) { throw 'Live candidate origin is not the exact approved source repository.' }
    foreach ($diffArgs in @(@('diff', '--no-ext-diff', '--no-textconv', '--quiet', $ExpectedRevision, '--'), @('diff', '--no-ext-diff', '--no-textconv', '--cached', '--quiet', $ExpectedRevision, '--'))) {
        $diff = Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments (@('--no-replace-objects', '-C', $source) + $diffArgs) -AllowedExitCodes @(0, 1)
        if ($diff.ExitCode -ne 0) { throw 'Live candidate contains tracked content changes and cannot be validated as immutable source.' }
    }
    $untracked = Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('--no-replace-objects', '-C', $source, 'ls-files', '--others', '--exclude-standard', '-z')
    if (-not [string]::IsNullOrEmpty($untracked.StdOut)) { throw 'Live candidate contains untracked content and cannot be copied into an immutable source clone.' }

    $parent = Split-Path -Parent $destinationFull
    [void][IO.Directory]::CreateDirectory($parent)
    Assert-StandardCoreV2NoReparseAncestors -Path $parent -Context 'Raw candidate clone parent'
    $clone = Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('-c', 'core.autocrlf=false', 'clone', '--no-hardlinks', '--no-checkout', $source, $destinationFull)
    [void]$clone
    [void](Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('-C', $destinationFull, 'config', '--local', 'core.autocrlf', 'false'))
    [void](Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('-C', $destinationFull, 'config', '--local', 'core.eol', 'lf'))
    [void](Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('-C', $destinationFull, 'config', '--local', 'core.safecrlf', 'false'))
    [void](Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('-C', $destinationFull, 'config', '--local', 'remote.origin.url', $ExpectedSourceRepository))
    [void](Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('--no-replace-objects', '-C', $destinationFull, 'checkout', '--quiet', '--detach', $ExpectedRevision))
    $cloneHead = (Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('--no-replace-objects', '-C', $destinationFull, 'rev-parse', '--verify', 'HEAD^{commit}')).StdOut.Trim()
    if ($cloneHead -cne $ExpectedRevision) { throw 'Raw candidate clone checked out an unexpected revision.' }
    $tree = Assert-StandardCoreV2RawCheckout -GitPath $GitPath -Root $destinationFull -Revision $ExpectedRevision
    return [pscustomobject]@{ Root = $destinationFull; Revision = $cloneHead; Inventory = $tree; Origin = $ExpectedSourceRepository; CoreAutoCrlf = 'false' }
}

function New-StandardCoreV2GitMetadataClone {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $GitPath, [Parameter(Mandatory)][string] $RawCandidateRoot,
        [Parameter(Mandatory)][string] $OwnedRoot, [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][string] $ExpectedRevision, [Parameter(Mandatory)][string] $RunId)
    if ($RunId -cnotmatch '^[0-9a-f]{32}$' -or $ExpectedRevision -cnotmatch '^[0-9a-f]{40}$') { throw 'Git metadata clone identity is malformed.' }
    $owned = [IO.Path]::GetFullPath($OwnedRoot)
    $metadataRoot = Assert-StandardCoreV2PathWithin -Path $Destination -Root $owned -Context 'Git metadata clone destination'
    if (Test-Path -LiteralPath $metadataRoot) { throw 'Git metadata clone destination already exists.' }
    $sourceHead = (Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('--no-replace-objects', '-C', $RawCandidateRoot, 'rev-parse', '--verify', 'HEAD^{commit}')).StdOut.Trim()
    if ($sourceHead -cne $ExpectedRevision) { throw 'Git metadata source HEAD differs from the expected candidate revision.' }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $metadataRoot))
    [void](Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('-c', 'core.autocrlf=false', 'clone', '--no-hardlinks', '--no-checkout', $RawCandidateRoot, $metadataRoot))
    [void](Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('-C', $metadataRoot, 'config', '--local', 'core.autocrlf', 'false'))
    [void](Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('-C', $metadataRoot, 'config', '--local', 'core.eol', 'lf'))
    [void](Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('--no-replace-objects', '-C', $metadataRoot, 'update-ref', '--no-deref', 'HEAD', $ExpectedRevision))
    [void](Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('-C', $metadataRoot, 'remote', 'remove', 'origin'))
    $head = (Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('--no-replace-objects', '-C', $metadataRoot, 'rev-parse', '--verify', 'HEAD^{commit}')).StdOut.Trim()
    $top = (Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('--no-replace-objects', '-C', $metadataRoot, 'rev-parse', '--show-toplevel')).StdOut.Trim()
    if ($head -cne $ExpectedRevision -or -not [IO.Path]::GetFullPath($top).Equals($metadataRoot, $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }))) {
        throw 'Git metadata clone is not bound to the exact candidate commit and worktree root.'
    }
    $alternates = (Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('-C', $metadataRoot, 'rev-parse', '--git-path', 'objects/info/alternates')).StdOut.Trim()
    if (-not [IO.Path]::IsPathRooted($alternates)) { $alternates = Join-Path $metadataRoot $alternates }
    if (Test-Path -LiteralPath $alternates) { throw 'Git metadata clone must not use alternate object databases.' }
    Assert-StandardCoreV2NoReparseAncestors -Path (Join-Path $metadataRoot '.git') -Context 'Git metadata clone'
    $bindingPath = Join-Path $owned 'source-git-binding.json'
    $binding = [ordered]@{ schemaVersion = 1; runId = $RunId; sourceRevision = $ExpectedRevision; gitMetadataRoot = $metadataRoot }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $binding -Compress -Depth 4) + "`n")
    $stream = [IO.FileStream]::new($bindingPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    return [pscustomobject]@{ Root = $metadataRoot; BindingPath = $bindingPath; BindingSha256 = Get-StandardCoreV2Sha256 -Path $bindingPath; RunId = $RunId; Revision = $ExpectedRevision }
}

function Assert-StandardCoreV2SourceBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $SnapshotRoot, [Parameter(Mandatory)][string] $ExpectedSha256,
        [Parameter(Mandatory)][string] $RunId, [Parameter(Mandatory)][string] $MetadataRoot,
        [Parameter(Mandatory)][string] $GitPath)
    if ($ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$' -or $RunId -cnotmatch '^[0-9a-f]{32}$') { throw 'Source binding check identity is malformed.' }
    $snapshot = [IO.Path]::GetFullPath($SnapshotRoot)
    if ([IO.Path]::GetFileName($snapshot) -cne 'candidate') { throw 'Source binding check must run from the central candidate snapshot.' }
    $runRoot = Split-Path -Parent $snapshot
    if ([IO.Path]::GetFileName($runRoot) -cne $RunId) { throw 'Source binding candidate snapshot does not match the trusted core run identity.' }
    $runsRoot = Split-Path -Parent $runRoot
    if ([IO.Path]::GetFileName($runsRoot) -cne 'runs') { throw 'Source binding candidate snapshot is outside the canonical runs directory.' }
    $artifactsRoot = Split-Path -Parent $runsRoot
    $adapterRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $artifactsRoot) ".core-v2-adapter-$RunId"))
    $expectedMetadataRoot = [IO.Path]::GetFullPath((Join-Path $adapterRoot 'candidate-git'))
    $fullMetadataRoot = [IO.Path]::GetFullPath($MetadataRoot)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $fullMetadataRoot.Equals($expectedMetadataRoot, $comparison)) { throw 'Source binding metadata root differs from the exact derived candidate-git path.' }
    Assert-StandardCoreV2NoReparseAncestors -Path $snapshot -Context 'Source candidate snapshot'
    Assert-StandardCoreV2NoReparseAncestors -Path $adapterRoot -Context 'Source binding adapter root'
    $bindingPath = Join-Path $adapterRoot 'source-git-binding.json'
    Assert-StandardCoreV2NoReparseAncestors -Path $bindingPath -Context 'Source binding record'
    if ((Get-StandardCoreV2Sha256 -Path $bindingPath) -cne $ExpectedSha256) { throw 'Source binding record SHA-256 differs from the protected check argument.' }
    $binding = Read-StandardCoreV2StrictJson -Path $bindingPath -Context 'Source binding record'
    Assert-StandardCoreV2ExactProperties -Value $binding -Names @('schemaVersion', 'runId', 'sourceRevision', 'gitMetadataRoot') -Context 'Source binding record'
    if ($binding.schemaVersion -ne 1 -or [string]$binding.runId -cne $RunId -or
        [string]$binding.sourceRevision -cnotmatch '^[0-9a-f]{40}$' -or
        -not [IO.Path]::GetFullPath([string]$binding.gitMetadataRoot).Equals($expectedMetadataRoot, $comparison)) {
        throw 'Source binding record does not match the trusted run, revision, and derived metadata path.'
    }
    Assert-StandardCoreV2NoReparseAncestors -Path $expectedMetadataRoot -Context 'Bound candidate Git metadata root'
    $metadataTop = (Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('--no-replace-objects', '-C', $expectedMetadataRoot, 'rev-parse', '--show-toplevel')).StdOut.Trim()
    $metadataHead = (Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('--no-replace-objects', '-C', $expectedMetadataRoot, 'rev-parse', '--verify', 'HEAD^{commit}')).StdOut.Trim()
    $objectFormat = (Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('--no-replace-objects', '-C', $expectedMetadataRoot, 'rev-parse', '--show-object-format=storage')).StdOut.Trim()
    $alternates = (Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('-C', $expectedMetadataRoot, 'rev-parse', '--git-path', 'objects/info/alternates')).StdOut.Trim()
    if (-not [IO.Path]::IsPathRooted($alternates)) { $alternates = Join-Path $expectedMetadataRoot $alternates }
    $metadataOrigins = (Invoke-StandardCoreV2GitText -GitPath $GitPath -Arguments @('-C', $expectedMetadataRoot, 'config', '--local', '--get-all', 'remote.origin.url') -AllowedExitCodes @(0, 1)).StdOut
    [string[]]$metadataOriginValues = @($metadataOrigins -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if (-not [IO.Path]::GetFullPath($metadataTop).Equals($expectedMetadataRoot, $comparison) -or
        $metadataHead -cne [string]$binding.sourceRevision -or $objectFormat -cne 'sha1' -or
        (Test-Path -LiteralPath $alternates) -or $metadataOriginValues.Count -ne 0) {
        throw 'Bound Git metadata root does not match the source revision, object format, or standalone object-store contract.'
    }
    return [pscustomobject]@{ RunId = $RunId; SourceRevision = [string]$binding.sourceRevision; GitMetadataRoot = $expectedMetadataRoot; BindingPath = $bindingPath; BindingSha256 = $ExpectedSha256 }
}

function Assert-StandardCoreV2UpstreamAdapterReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Report,
        [Parameter(Mandatory)][string] $ExpectedPackageRoot,
        [Parameter(Mandatory)][string] $ExpectedSourceRepository,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $ExpectedSourceRevision,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string] $ExpectedArchiveSha256
    )
    $reportProperties = @('schemaVersion','policy','adapterVersion','status','packageRoot','surfaces','bundledSkills',
        'candidateIdentity','componentInventory','componentInventorySha256','decision')
    if ($Report -isnot [pscustomobject]) { throw 'Upstream adapter report must be a JSON object.' }
    Assert-StandardCoreV2ExactProperties -Value $Report -Names $reportProperties -Context 'Upstream adapter report'
    if (($Report.schemaVersion -isnot [int] -and $Report.schemaVersion -isnot [long]) -or [int64]$Report.schemaVersion -ne 1 -or
        [string]$Report.policy -cne 'upstream-interoperability-adapter-v1' -or
        [string]$Report.adapterVersion -cne 'upstream-interoperability-adapter-v1') {
        throw 'Upstream adapter report schema or policy identity is invalid.'
    }
    $expectedRoot = [IO.Path]::GetFullPath($ExpectedPackageRoot)
    $reportRoot = [IO.Path]::GetFullPath([string]$Report.packageRoot)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $reportRoot.Equals($expectedRoot, $comparison)) { throw 'Upstream adapter report package root differs from the central candidate snapshot.' }
    if ($Report.surfaces -isnot [array] -or $Report.bundledSkills -isnot [array] -or $Report.componentInventory -isnot [array]) {
        throw 'Upstream adapter report surfaces, bundled skills, and component inventory must be arrays.'
    }
    $allowedSurfaces = @('plugin','mcp','app','marketplace')
    $surfaceSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($surface in $Report.surfaces) {
        if ($surface -isnot [string] -or $allowedSurfaces -cnotcontains [string]$surface -or -not $surfaceSet.Add([string]$surface)) {
            throw "Upstream adapter report contains an unknown or duplicate surface '$surface'."
        }
    }
    if ([string]$Report.status -cne 'passed' -and [string]$Report.status -cne 'not-applicable') {
        throw 'Upstream adapter report status must be passed or not-applicable.'
    }
    $expectedDecision = if ([string]$Report.status -ceq 'passed') { 'PASS' } else { 'NOT_APPLICABLE' }
    if ([string]$Report.decision -cne $expectedDecision) { throw 'Upstream adapter report decision does not match its status.' }

    $componentNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $componentHashes = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($component in $Report.componentInventory) {
        if ($component -isnot [pscustomobject]) { throw 'Upstream adapter component inventory item must be an object.' }
        Assert-StandardCoreV2ExactProperties -Value $component -Names @('path','sha256') -Context 'Upstream adapter component'
        $relativePath = [string]$component.path
        $componentHash = [string]$component.sha256
        if ($relativePath -cnotmatch '^[^/\\\x00-\x1F]+(?:/[^/\\\x00-\x1F]+)*$' -or
            @($relativePath -split '/' | Where-Object { $_ -ceq '.' -or $_ -ceq '..' }).Count -gt 0 -or
            $componentHash -cnotmatch '^[0-9a-f]{64}$' -or -not $componentNames.Add($relativePath)) {
            throw 'Upstream adapter component inventory contains a malformed or duplicate path or hash.'
        }
        $componentPath = [IO.Path]::GetFullPath((Join-Path $expectedRoot ($relativePath -replace '/', [IO.Path]::DirectorySeparatorChar)))
        [void](Assert-StandardCoreV2PathWithin -Path $componentPath -Root $expectedRoot -Context 'Upstream adapter component path')
        Assert-StandardCoreV2NoReparseAncestors -Path $componentPath -Context 'Upstream adapter component'
        $componentItem = Get-Item -Force -LiteralPath $componentPath -ErrorAction Stop
        if ($componentItem.PSIsContainer -or
            ([IO.FileAttributes]$componentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            (Get-StandardCoreV2Sha256 -Path $componentPath) -cne $componentHash) {
            throw "Upstream adapter component changed after validation: $relativePath"
        }
        $componentHashes.Add($relativePath, $componentHash)
    }
    $sortedComponentPaths = [string[]]@($componentHashes.Keys)
    [Array]::Sort($sortedComponentPaths, [StringComparer]::Ordinal)
    $canonical = [Text.StringBuilder]::new()
    foreach ($relativePath in $sortedComponentPaths) {
        [void]$canonical.Append($relativePath).Append("`t").Append($componentHashes[$relativePath]).Append("`n")
    }
    $componentDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical.ToString()))).ToLowerInvariant()
    if ([string]$Report.componentInventorySha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$Report.componentInventorySha256 -cne $componentDigest) {
        throw 'Upstream adapter component inventory digest is invalid.'
    }

    foreach ($bundle in $Report.bundledSkills) {
        if ($bundle -isnot [pscustomobject]) { throw 'Upstream adapter bundled Skill entry must be an object.' }
        Assert-StandardCoreV2ExactProperties -Value $bundle -Names @('path','inventory') -Context 'Upstream adapter bundled Skill'
        $skillPath = [string]$bundle.path
        if ($skillPath -cnotmatch '^\./skills/[a-z0-9]+(?:-[a-z0-9]+)*$' -or $skillPath.Substring(9).Length -gt 64 -or
            $bundle.inventory -isnot [array] -or @($bundle.inventory).Count -eq 0) {
            throw 'Upstream adapter bundled Skill inventory is malformed.'
        }
        $normalizedSkillPath = $skillPath.Substring(2)
        foreach ($resource in $bundle.inventory) {
            if ($resource -isnot [string] -or [string]$resource -cnotmatch '^[^/\\\x00-\x1F]+(?:/[^/\\\x00-\x1F]+)*$' -or
                @(([string]$resource -split '/') | Where-Object { $_ -ceq '.' -or $_ -ceq '..' }).Count -gt 0 -or
                -not $componentHashes.ContainsKey("$normalizedSkillPath/$resource")) {
                throw 'Upstream adapter bundled Skill resource is absent from the validated component inventory.'
            }
        }
    }

    if ([string]$Report.status -ceq 'passed') {
        if ($Report.surfaces.Count -eq 0 -or $null -eq $Report.candidateIdentity -or $Report.candidateIdentity -isnot [pscustomobject]) {
            throw 'Upstream adapter PASS must include detected surfaces and a candidate identity.'
        }
        Assert-StandardCoreV2ExactProperties -Value $Report.candidateIdentity `
            -Names @('sourceRepository','sourceRevision','archiveSha256','packageSha256') -Context 'Upstream adapter candidate identity'
        if ([string]$Report.candidateIdentity.sourceRepository -cne $ExpectedSourceRepository -or
            [string]$Report.candidateIdentity.sourceRevision -cne $ExpectedSourceRevision -or
            [string]$Report.candidateIdentity.archiveSha256 -cne $ExpectedArchiveSha256 -or
            [string]$Report.candidateIdentity.packageSha256 -cne $componentDigest) {
            throw 'Upstream adapter candidate identity does not bind the expected source archive and component inventory.'
        }
    }
    else {
        if ($Report.surfaces.Count -ne 0 -or $Report.bundledSkills.Count -ne 0 -or $Report.componentInventory.Count -ne 0 -or
            $null -ne $Report.candidateIdentity) {
            throw 'Upstream adapter NOT_APPLICABLE must have no surfaces, bundled Skills, components, or candidate identity.'
        }
    }
    return $Report
}

function Remove-StandardCoreConsumedBootstrapSignal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CandidateRoot, [Parameter(Mandatory)][string] $ReleasePath,
        [Parameter(Mandatory)][string] $BootstrapCommand, [Parameter(Mandatory)][string] $VerifiedPowerShellExecutable)
    $root = [IO.Path]::GetFullPath($CandidateRoot)
    if (-not [IO.Path]::IsPathFullyQualified($ReleasePath) -or
        -not [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ReleasePath)).Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($ReleasePath) -cnotmatch '^b-[0-9a-f]{32}\.sig$') {
        throw 'Core bootstrap signal is not the exact candidate-root transport file.'
    }
    if (-not [IO.Path]::IsPathFullyQualified($BootstrapCommand) -or
        -not [IO.Path]::GetFullPath($BootstrapCommand).Equals([IO.Path]::GetFullPath($VerifiedPowerShellExecutable), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Core bootstrap command differs from the verified PowerShell executable.'
    }
    $signal = [IO.Path]::GetFullPath($ReleasePath)
    Assert-StandardCoreV2NoReparseAncestors -Path $signal -Context 'Core bootstrap signal'
    $expected = [Text.UTF8Encoding]::new($false).GetBytes('release' + [Environment]::NewLine)
    $actual = [IO.File]::ReadAllBytes($signal)
    if (-not [Linq.Enumerable]::SequenceEqual[byte]($actual, $expected)) { throw 'Core bootstrap signal bytes differ from the consumed release payload.' }
    [IO.File]::Delete($signal)
    if (Test-Path -LiteralPath $signal) { throw 'Core bootstrap signal cleanup failed.' }
}

Export-ModuleMember -Function @(
    'Get-StandardCoreV2Sha256', 'Assert-StandardCoreV2NoReparseAncestors', 'Invoke-StandardCoreV2GitText',
    'Set-StandardCoreV2GitOperationContext', 'Clear-StandardCoreV2GitOperationContext',
    'Read-StandardCoreV2StrictJson', 'Assert-StandardCoreV2ExactProperties', 'Get-StandardCoreV2GitBlobSha256',
    'Get-StandardCoreV2ToolInstallParent', 'Get-StandardCoreV2SkillSpectorPathHeadroom',
    'Assert-StandardCoreV2ResolverReceiptPaths', 'New-StandardCoreV2ResolverArguments', 'New-StandardCoreV2CoreRunnerArguments',
    'Read-StandardCoreV2PreparationProfile', 'Resolve-StandardCoreV2Dispatch', 'Get-StandardCoreV2GitTree', 'Write-StandardCoreV2GitBlob',
    'Assert-StandardCoreV2AuthorityTuple', 'New-StandardCoreV2AuthorityMaterialization', 'Assert-StandardCoreV2RawCheckout', 'New-StandardCoreV2RawCandidateClone',
    'Assert-StandardCoreV2ProtectedCandidateFiles',
    'New-StandardCoreV2GitMetadataClone', 'Assert-StandardCoreV2SourceBinding',
    'New-StandardCoreV2GitArchive',
    'Assert-StandardCoreV2UpstreamAdapterReport',
    'Remove-StandardCoreConsumedBootstrapSignal', 'Get-StandardCoreV2ChildBudget', 'Get-StandardCoreV2RemainingSeconds'
)
