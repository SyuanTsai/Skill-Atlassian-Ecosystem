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
    $expectedHash = '1cca364cf34927eea12b28395ac7135ca706a689bf3d55ae5218fe051c5729fe'
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
    $maxOutputBytes = 32L * 1024L * 1024L
    $reportOutputPath = $null
    $outputArgumentIndexes = [Collections.Generic.List[int]]::new()
    for ($argumentIndex = 0; $argumentIndex -lt $Arguments.Length; $argumentIndex++) {
        if ([string]$Arguments[$argumentIndex] -ceq '--output') { $outputArgumentIndexes.Add($argumentIndex) }
    }
    if ($outputArgumentIndexes.Count -gt 1) { throw "$Context has more than one --output report path." }
    if ($outputArgumentIndexes.Count -eq 1) {
        $outputArgumentIndex = $outputArgumentIndexes[0]
        if ($outputArgumentIndex -ge ($Arguments.Length - 1) -or [string]::IsNullOrWhiteSpace([string]$Arguments[$outputArgumentIndex + 1])) {
            throw "$Context has no path after its --output option."
        }
        $reportOutputPath = [IO.Path]::GetFullPath([string]$Arguments[$outputArgumentIndex + 1])
        $pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if (-not [IO.Path]::GetDirectoryName($reportOutputPath).Equals($workingDirectory, $pathComparison)) {
            throw "$Context --output report must be inside its run-owned working directory."
        }
    }
    $evidenceId = [guid]::NewGuid().ToString('N')
    $stdoutPath = [IO.Path]::GetFullPath((Join-Path $workingDirectory "native-raw-$Mode-$evidenceId.stdout.bin"))
    $stderrPath = [IO.Path]::GetFullPath((Join-Path $workingDirectory "native-raw-$Mode-$evidenceId.stderr.bin"))
    $stdoutFile = $null
    $stderrFile = $null
    $stdoutPump = $null
    $stderrPump = $null
    $pumpCancellation = [Threading.CancellationTokenSource]::new()
    $reportOverflow = $false
    $reportByteCount = 0L
    $reportKillError = ''
    $reportCleanupVerified = $false
    $reportProcessId = 0
    try {
        $stdoutFile = [IO.File]::Open($stdoutPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $stderrFile = [IO.File]::Open($stderrPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        if (-not $process.Start()) { throw "$Context process could not start." }
        $reportProcessId = [int]$process.Id
        $process.StandardInput.Close()

        # Each independent PowerShell runspace drains one raw pipe. The cap applies
        # before any bytes hit disk, and the first excess byte kills the full tree.
        $boundedPumpScript = @'
 param([IO.Stream] $InputStream, [IO.FileStream] $OutputStream, [long] $Limit, [Diagnostics.Process] $ParentProcess, [Threading.CancellationToken] $CancellationToken, [Collections.Concurrent.ConcurrentDictionary[string,bool]] $OverflowState)
$buffer = [byte[]]::new(65536)
$written = 0L
$overflow = $false
$killError = ''
$readError = ''
$cancelled = $false
try {
    while ($true) {
        $readTask = $InputStream.ReadAsync($buffer, 0, $buffer.Length, $CancellationToken)
        $read = [int]$readTask.GetAwaiter().GetResult()
        if ($read -eq 0) { break }
        $remaining = $Limit - $written
        $toWrite = if ($remaining -gt 0) { [int][Math]::Min([double]$remaining, [double]$read) } else { 0 }
        if ($toWrite -gt 0) {
            $OutputStream.Write($buffer, 0, $toWrite)
            $written += $toWrite
        }
        if ($read -gt $toWrite -and -not $overflow) {
            $overflow = $true
            $OverflowState['observed'] = $true
            try {
                if (-not $ParentProcess.HasExited) { $ParentProcess.Kill($true) }
            } catch { $killError = $_.Exception.Message }
        }
    }
} catch [System.OperationCanceledException] {
    if ($CancellationToken.IsCancellationRequested) { $cancelled = $true }
    else { $readError = $_.Exception.Message }
} catch [System.ObjectDisposedException] {
    if ($CancellationToken.IsCancellationRequested) { $cancelled = $true }
    else { $readError = $_.Exception.Message }
} catch { $readError = $_.Exception.Message }
try { $OutputStream.Flush($true) } catch { if ([string]::IsNullOrEmpty($readError)) { $readError = $_.Exception.Message } }
[pscustomobject]@{ bytes = [long]$written; overflow = [bool]$overflow; killError = $killError; readError = $readError; cancelled = [bool]$cancelled }
'@
        $startPump = {
            param([IO.Stream] $InputStream, [IO.FileStream] $OutputStream, [long] $Limit, [Diagnostics.Process] $ParentProcess, [Threading.CancellationToken] $CancellationToken)
            $overflowState = [Collections.Concurrent.ConcurrentDictionary[string,bool]]::new()
            $overflowState['observed'] = $false
            $worker = [PowerShell]::Create()
            [void]$worker.AddScript($boundedPumpScript)
            [void]$worker.AddArgument($InputStream)
            [void]$worker.AddArgument($OutputStream)
            [void]$worker.AddArgument($Limit)
            [void]$worker.AddArgument($ParentProcess)
            [void]$worker.AddArgument($CancellationToken)
            [void]$worker.AddArgument($overflowState)
            $handle = $worker.BeginInvoke()
            return [pscustomobject]@{ worker = $worker; handle = $handle; overflowState = $overflowState }
        }
        $stdoutPump = & $startPump $process.StandardOutput.BaseStream $stdoutFile $maxOutputBytes $process $pumpCancellation.Token
        $stderrPump = & $startPump $process.StandardError.BaseStream $stderrFile $maxOutputBytes $process $pumpCancellation.Token
        while ($true) {
            if ($null -ne $reportOutputPath -and (Test-Path -LiteralPath $reportOutputPath -PathType Leaf)) {
                Assert-StandardCoreV2NoReparseAncestors -Path $reportOutputPath -Context "$Context run-owned --output report"
                $reportByteCount = [long](Get-Item -LiteralPath $reportOutputPath -Force -ErrorAction Stop).Length
                if ($reportByteCount -gt $maxOutputBytes) {
                    $reportOverflow = $true
                    try {
                        if (-not $process.HasExited) { $process.Kill($true) }
                    } catch { $reportKillError = $_.Exception.Message }
                    [void]$process.WaitForExit(5000)
                    break
                }
            }
            if ($process.WaitForExit(25)) {
                if ($null -ne $reportOutputPath -and (Test-Path -LiteralPath $reportOutputPath -PathType Leaf)) {
                    Assert-StandardCoreV2NoReparseAncestors -Path $reportOutputPath -Context "$Context run-owned --output report"
                    $reportByteCount = [long](Get-Item -LiteralPath $reportOutputPath -Force -ErrorAction Stop).Length
                    if ($reportByteCount -gt $maxOutputBytes) {
                        $reportOverflow = $true
                    }
                }
                break
            }
        }
        if (-not $reportOverflow) { $process.WaitForExit() }
        $captureEofGraceDeadline = [DateTime]::UtcNow.AddMilliseconds(500)
        while ((-not $stdoutPump.handle.IsCompleted -or -not $stderrPump.handle.IsCompleted) -and [DateTime]::UtcNow -lt $captureEofGraceDeadline) {
            foreach ($pump in @($stdoutPump, $stderrPump)) {
                if (-not $pump.handle.IsCompleted) {
                    $remainingMilliseconds = [int][Math]::Ceiling(($captureEofGraceDeadline - [DateTime]::UtcNow).TotalMilliseconds)
                    if ($remainingMilliseconds -gt 0) { [void]$pump.handle.AsyncWaitHandle.WaitOne([Math]::Min(25, $remainingMilliseconds)) }
                }
            }
        }
        $captureReachedEofBeforeCancellation = $stdoutPump.handle.IsCompleted -and $stderrPump.handle.IsCompleted
        if (-not $captureReachedEofBeforeCancellation) {
            $pumpCancellation.Cancel()
            $captureDeadline = [DateTime]::UtcNow.AddMilliseconds(1000)
            while ((-not $stdoutPump.handle.IsCompleted -or -not $stderrPump.handle.IsCompleted) -and [DateTime]::UtcNow -lt $captureDeadline) {
                foreach ($pump in @($stdoutPump, $stderrPump)) {
                    if (-not $pump.handle.IsCompleted) {
                        $remainingMilliseconds = [int][Math]::Ceiling(($captureDeadline - [DateTime]::UtcNow).TotalMilliseconds)
                        if ($remainingMilliseconds -gt 0) { [void]$pump.handle.AsyncWaitHandle.WaitOne([Math]::Min(25, $remainingMilliseconds)) }
                    }
                }
            }
        }
        $stdoutPumpCompleted = $stdoutPump.handle.IsCompleted
        $stderrPumpCompleted = $stderrPump.handle.IsCompleted
        $stdoutTaskResult = if ($stdoutPumpCompleted) { @($stdoutPump.worker.EndInvoke($stdoutPump.handle)) } else { @() }
        $stderrTaskResult = if ($stderrPumpCompleted) { @($stderrPump.worker.EndInvoke($stderrPump.handle)) } else { @() }
        if (($stdoutPumpCompleted -and $stdoutTaskResult.Count -ne 1) -or ($stderrPumpCompleted -and $stderrTaskResult.Count -ne 1)) {
            throw "$Context output-capture pump returned an invalid result."
        }
        $stdoutResult = if ($stdoutPumpCompleted) { $stdoutTaskResult[0] } else {
            [pscustomobject]@{ bytes = [long]$stdoutFile.Length; overflow = [bool]$stdoutPump.overflowState['observed']; killError = ''; readError = 'stdout capture pump did not complete before the bounded capture deadline.'; cancelled = $true }
        }
        $stderrResult = if ($stderrPumpCompleted) { $stderrTaskResult[0] } else {
            [pscustomobject]@{ bytes = [long]$stderrFile.Length; overflow = [bool]$stderrPump.overflowState['observed']; killError = ''; readError = 'stderr capture pump did not complete before the bounded capture deadline.'; cancelled = $true }
        }
        $captureReachedEof = $captureReachedEofBeforeCancellation -and
            -not [bool]$stdoutResult.cancelled -and -not [bool]$stderrResult.cancelled -and
            [string]::IsNullOrEmpty([string]$stdoutResult.readError) -and [string]::IsNullOrEmpty([string]$stderrResult.readError)
        $reportCleanupVerified = $process.HasExited -and $captureReachedEof
        if ($reportOverflow) {
            $exitCode = if ($process.HasExited) { [int]$process.ExitCode } else { -1 }
            $cleanupStatus = if ($reportCleanupVerified) { 'verified' } else { 'unverified' }
            $killErrorText = if ([string]::IsNullOrEmpty($reportKillError)) { '' } else { '; killError=' + $reportKillError }
            $rawCaptureErrorText = @(@($stdoutResult.readError, $stderrResult.readError) | Where-Object { -not [string]::IsNullOrEmpty([string]$_) }) -join ' | '
            $rawCaptureErrorText = if ([string]::IsNullOrEmpty($rawCaptureErrorText)) { '' } else { '; rawCaptureError=' + $rawCaptureErrorText }
            throw "$Context report file exceeded the $maxOutputBytes-byte cap; reportPath=$reportOutputPath; reportBytes=$reportByteCount; exitCode=$exitCode; processId=$reportProcessId; cleanup=$cleanupStatus; stdoutPath=$stdoutPath; stderrPath=$stderrPath$killErrorText$rawCaptureErrorText."
        }
        $overflowStreams = [Collections.Generic.List[string]]::new()
        if ([bool]$stdoutResult.overflow) { $overflowStreams.Add('stdout') }
        if ([bool]$stderrResult.overflow) { $overflowStreams.Add('stderr') }
        if ($overflowStreams.Count -gt 0) {
            $exitCode = if ($process.HasExited) { [int]$process.ExitCode } else { -1 }
            $cleanupStatus = if ($process.HasExited -and $captureReachedEof) { 'verified' } else { 'unverified' }
            $killErrors = @(@($stdoutResult.killError, $stderrResult.killError) | Where-Object { -not [string]::IsNullOrEmpty([string]$_) })
            $killErrorText = if ($killErrors.Count -gt 0) { '; killError=' + ($killErrors -join ' | ') } else { '' }
            $captureErrors = @(@($stdoutResult.readError, $stderrResult.readError) | Where-Object { -not [string]::IsNullOrEmpty([string]$_) })
            $captureErrorText = if ($captureErrors.Count -gt 0) { '; rawCaptureError=' + ($captureErrors -join ' | ') } else { '' }
            throw "$Context exceeded the $maxOutputBytes-byte raw output cap; overflow=$($overflowStreams -join ','); exitCode=$exitCode; cleanup=$cleanupStatus; stdoutBytes=$($stdoutResult.bytes); stdoutPath=$stdoutPath; stderrBytes=$($stderrResult.bytes); stderrPath=$stderrPath$killErrorText$captureErrorText."
        }
        if (-not $captureReachedEof) {
            throw "$Context raw output capture did not reach pipe EOF within the bounded capture deadline; cleanup=unverified; stdoutPath=$stdoutPath; stderrPath=$stderrPath; stdoutBytes=$($stdoutResult.bytes); stderrBytes=$($stderrResult.bytes)."
        }
        if (-not [string]::IsNullOrEmpty([string]$stdoutResult.readError) -or -not [string]::IsNullOrEmpty([string]$stderrResult.readError)) {
            throw "$Context raw output capture failed; stdoutPath=$stdoutPath; stderrPath=$stderrPath; stdoutError=$($stdoutResult.readError); stderrError=$($stderrResult.readError)."
        }
        return [pscustomobject]@{
            exitCode = [int]$process.ExitCode
            stdoutByteCount = [long]$stdoutResult.bytes
            stderrByteCount = [long]$stderrResult.bytes
            stdoutPath = $stdoutPath
            stderrPath = $stderrPath
        }
    }
    finally {
        try {
            if (-not $process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
        } catch { }
        if ($null -ne $pumpCancellation) { try { $pumpCancellation.Cancel() } catch { } }
        foreach ($pump in @($stdoutPump, $stderrPump)) {
            if ($null -ne $pump) {
                try { if (-not $pump.handle.IsCompleted) { [void]$pump.worker.Stop() } } catch { }
                try { $pump.worker.Dispose() } catch { }
            }
        }
        if ($null -ne $stdoutFile) { $stdoutFile.Dispose() }
        if ($null -ne $stderrFile) { $stderrFile.Dispose() }
        if ($null -ne $pumpCancellation) { $pumpCancellation.Dispose() }
        $process.Dispose()
    }
}

function Read-BoundedNativeJsonFile {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Context)
    $maxJsonBytes = 32L * 1024L * 1024L
    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-StandardCoreV2NoReparseAncestors -Path $fullPath -Context "$Context JSON evidence"
    $stream = $null
    $bytes = $null
    try {
        $stream = [IO.File]::Open($fullPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $length = [long]$stream.Length
        if ($length -gt $maxJsonBytes) { throw "$Context report exceeded the $maxJsonBytes-byte JSON cap; path=$fullPath; bytes=$length." }
        if ($length -le 0) { throw "$Context returned no JSON output; path=$fullPath." }
        $bytes = [byte[]]::new([int]$length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { throw "$Context JSON report changed or ended before its declared length; path=$fullPath." }
            $offset += $read
        }
        if ($stream.ReadByte() -ne -1) { throw "$Context report exceeded the $maxJsonBytes-byte JSON cap while being read; path=$fullPath." }
    }
    finally { if ($null -ne $stream) { $stream.Dispose() } }

    try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes).Trim() }
    catch { throw "$Context returned non-UTF-8 JSON output; path=$fullPath." }
    if ([string]::IsNullOrWhiteSpace($text)) { throw "$Context returned no JSON output; path=$fullPath." }
    try { return (ConvertFrom-Json -InputObject $text -Depth 100 -ErrorAction Stop) }
    catch { throw "$Context returned invalid JSON; path=$fullPath; $($_.Exception.Message)" }
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

function Convert-SkillToolsSarifFindings {
    param(
        [Parameter(Mandatory)][object] $Report,
        [Parameter(Mandatory)][string] $SkillRoot,
        [Parameter(Mandatory)][string] $SkillId,
        [Parameter(Mandatory)][string[]] $Inventory
    )

    $run = $Report.runs[0]
    $driver = $run.tool.driver
    if ($null -eq $driver.rules -or $driver.rules -isnot [array]) {
        throw "skill-tools SARIF rule table is missing or malformed for '$SkillId'."
    }
    $rules = @($driver.rules)
    $resultsProperty = $run.PSObject.Properties['results']
    if ($null -eq $resultsProperty -or $resultsProperty.Value -isnot [array]) {
        throw "skill-tools SARIF results are missing or malformed for '$SkillId'."
    }
    $results = @($resultsProperty.Value)
    $ruleById = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    for ($i = 0; $i -lt $rules.Count; $i++) {
        $rule = $rules[$i]
        if ($null -eq $rule -or $rule -is [string] -or $rule -is [ValueType] -or $rule -is [array]) {
            throw "skill-tools SARIF rule metadata is malformed for '$SkillId'."
        }
        $idProperty = $rule.PSObject.Properties['id']
        if ($null -eq $idProperty -or $idProperty.Value -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$idProperty.Value) -or $ruleById.ContainsKey([string]$idProperty.Value)) {
            throw "skill-tools SARIF rule ids are missing, duplicated, or malformed for '$SkillId'."
        }
        $ruleById.Add([string]$idProperty.Value, $rule)
    }

    $findings = [Collections.Generic.List[object]]::new()
    foreach ($result in $results) {
        if ($null -eq $result -or $result -is [string] -or $result -is [ValueType] -or $result -is [array]) {
            throw "skill-tools SARIF result is malformed for '$SkillId'."
        }
        $ruleIdProperty = $result.PSObject.Properties['ruleId']
        if ($null -eq $ruleIdProperty -or $ruleIdProperty.Value -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$ruleIdProperty.Value) -or -not $ruleById.ContainsKey([string]$ruleIdProperty.Value)) {
            throw "skill-tools SARIF result references an unknown or malformed ruleId for '$SkillId'."
        }
        $ruleId = [string]$ruleIdProperty.Value
        $rule = $ruleById[$ruleId]

        $ruleIndexProperty = $result.PSObject.Properties['ruleIndex']
        if ($null -ne $ruleIndexProperty) {
            $ruleIndex = $ruleIndexProperty.Value
            if (($ruleIndex -isnot [byte] -and $ruleIndex -isnot [sbyte] -and $ruleIndex -isnot [int16] -and
                    $ruleIndex -isnot [uint16] -and $ruleIndex -isnot [int32] -and $ruleIndex -isnot [uint32] -and
                    $ruleIndex -isnot [int64] -and $ruleIndex -isnot [uint64]) -or
                [long]$ruleIndex -lt 0 -or [long]$ruleIndex -ge $rules.Count -or
                [string]$rules[[int]$ruleIndex].id -cne $ruleId) {
                throw "skill-tools SARIF ruleIndex is invalid or inconsistent with ruleId for '$SkillId'."
            }
        }

        $levelProperty = $result.PSObject.Properties['level']
        if ($null -ne $levelProperty) {
            if ($levelProperty.Value -isnot [string]) { throw "skill-tools SARIF result level is malformed for '$SkillId'." }
            $level = [string]$levelProperty.Value
        } else {
            $configurationProperty = $rule.PSObject.Properties['defaultConfiguration']
            $defaultLevelProperty = if ($null -ne $configurationProperty -and $null -ne $configurationProperty.Value) {
                $configurationProperty.Value.PSObject.Properties['level']
            } else { $null }
            if ($null -eq $defaultLevelProperty -or $defaultLevelProperty.Value -isnot [string]) {
                throw "skill-tools SARIF result without level requires a valid rule defaultConfiguration.level for '$SkillId'."
            }
            $level = [string]$defaultLevelProperty.Value
        }
        if ($level -cnotin @('none', 'note', 'warning', 'error')) {
            throw "skill-tools SARIF result level is unknown or malformed for '$SkillId'."
        }
        if ($level -in @('warning', 'error')) { throw "skill-tools SARIF contains a blocking result for '$SkillId'." }

        $locationsProperty = $result.PSObject.Properties['locations']
        $locations = [Collections.Generic.List[object]]::new()
        if ($null -ne $locationsProperty -and $null -ne $locationsProperty.Value) {
            foreach ($location in @($locationsProperty.Value)) { $locations.Add($location) }
        }
        if ($locations.Count -eq 0 -and $level -ceq 'note') {
            throw "skill-tools SARIF note lacks a candidate-bound location for '$SkillId'."
        }
        $relativePaths = [Collections.Generic.List[string]]::new()
        foreach ($location in $locations) {
            $physicalProperty = if ($null -ne $location) { $location.PSObject.Properties['physicalLocation'] } else { $null }
            $artifactProperty = if ($null -ne $physicalProperty -and $null -ne $physicalProperty.Value) {
                $physicalProperty.Value.PSObject.Properties['artifactLocation']
            } else { $null }
            $uriProperty = if ($null -ne $artifactProperty -and $null -ne $artifactProperty.Value) {
                $artifactProperty.Value.PSObject.Properties['uri']
            } else { $null }
            if ($null -eq $uriProperty -or $uriProperty.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$uriProperty.Value)) {
                throw "skill-tools SARIF result has a malformed candidate location for '$SkillId'."
            }
            $resolvedPath = Resolve-CandidateFile -Value ([string]$uriProperty.Value) -SkillRoot $SkillRoot -Inventory $Inventory
            $relativePaths.Add([IO.Path]::GetRelativePath([IO.Path]::GetFullPath($SkillRoot), $resolvedPath).Replace('\', '/'))
        }
        if ($level -ceq 'none') { continue }

        $messageProperty = $result.PSObject.Properties['message']
        $message = ''
        if ($null -ne $messageProperty -and $null -ne $messageProperty.Value) {
            $textProperty = $messageProperty.Value.PSObject.Properties['text']
            $markdownProperty = $messageProperty.Value.PSObject.Properties['markdown']
            if ($null -ne $textProperty -and $textProperty.Value -is [string]) { $message = [string]$textProperty.Value }
            elseif ($null -ne $markdownProperty -and $markdownProperty.Value -is [string]) { $message = [string]$markdownProperty.Value }
        }
        if ([string]::IsNullOrWhiteSpace($message)) { throw "skill-tools SARIF note is missing its message for '$SkillId'." }
        foreach ($relativePath in $relativePaths) {
            $fingerprint = ''
            foreach ($fingerprintPropertyName in @('fingerprints', 'partialFingerprints')) {
                $fingerprintContainerProperty = $result.PSObject.Properties[$fingerprintPropertyName]
                if ($null -eq $fingerprintContainerProperty -or $null -eq $fingerprintContainerProperty.Value) { continue }
                $fingerprintValues = @($fingerprintContainerProperty.Value.PSObject.Properties |
                    Where-Object { $_.Value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$_.Value) } |
                    Sort-Object -Property Name -CaseSensitive)
                if ($fingerprintValues.Count -gt 0) { $fingerprint = [string]$fingerprintValues[0].Value; break }
            }
            if ([string]::IsNullOrWhiteSpace($fingerprint)) {
                $fingerprintInput = [Text.UTF8Encoding]::new($false).GetBytes($ruleId + "`n" + $message + "`n" + $relativePath)
                $fingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($fingerprintInput)).ToLowerInvariant()
            }
            $findings.Add([pscustomobject][ordered]@{
                severity = 'informational'
                fingerprint = $fingerprint
                ruleId = $ruleId
                message = $message
                path = "skills/$SkillId/$relativePath"
            })
        }
    }
    return $findings.ToArray()
}

function Convert-SkillValidatorFindings {
    param(
        [Parameter(Mandatory)][object[]] $Results,
        [Parameter(Mandatory)][string] $SkillRoot,
        [Parameter(Mandatory)][string] $SkillId,
        [Parameter(Mandatory)][string[]] $Inventory
    )

    $findings = [Collections.Generic.List[object]]::new()
    foreach ($result in $Results) {
        if ($null -eq $result -or $result -is [array] -or $result -is [string] -or $result -is [ValueType]) {
            throw "skill-validator returned a malformed result for '$SkillId'."
        }
        $levelProperty = $result.PSObject.Properties['level']
        if ($null -eq $levelProperty -or $levelProperty.Value -isnot [string] -or $levelProperty.Value -cnotin @('pass', 'info')) {
            throw "skill-validator returned an unknown or malformed level for '$SkillId'."
        }

        $relativePath = $null
        $fileProperty = $result.PSObject.Properties['file']
        if ($null -ne $fileProperty) {
            if ($fileProperty.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$fileProperty.Value)) {
                throw "skill-validator returned a malformed candidate file for '$SkillId'."
            }
            $resolvedPath = Resolve-CandidateFile -Value ([string]$fileProperty.Value) -SkillRoot $SkillRoot -Inventory $Inventory
            $relativePath = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($SkillRoot), $resolvedPath).Replace('\', '/')
        }
        if ($levelProperty.Value -ceq 'pass') { continue }

        $categoryProperty = $result.PSObject.Properties['category']
        $messageProperty = $result.PSObject.Properties['message']
        if ($null -eq $categoryProperty -or $categoryProperty.Value -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$categoryProperty.Value) -or
            $null -eq $messageProperty -or $messageProperty.Value -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$messageProperty.Value)) {
            throw "skill-validator informational result lacks a valid category or message for '$SkillId'."
        }

        $category = [string]$categoryProperty.Value
        $message = [string]$messageProperty.Value
        $fingerprintInput = $SkillId + "`n" + $category + "`n" + $message + "`n" + [string]$relativePath
        $fingerprintBytes = [Text.UTF8Encoding]::new($false).GetBytes($fingerprintInput)
        $finding = [ordered]@{
            severity = 'informational'
            fingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($fingerprintBytes)).ToLowerInvariant()
            ruleId = $category
            message = $message
        }
        if ($null -ne $relativePath) { $finding.path = "skills/$SkillId/$relativePath" }
        $findings.Add([pscustomobject]$finding)
    }
    return $findings.ToArray()
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
    try { $report = Read-BoundedNativeJsonFile -Path ([string]$execution.stdoutPath) -Context $Context }
    catch { throw "$Context did not return bounded valid JSON. $evidence $($_.Exception.Message)" }
    $path = Join-Path (Get-Location) "native-$Mode-$([guid]::NewGuid().ToString('N')).json"
    [IO.File]::Copy([string]$execution.stdoutPath, $path, $false)
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
        $setupRoot = [IO.Path]::GetFullPath((Split-Path -Parent $toolchainFull))
        $expectedArchivePath = [IO.Path]::GetFullPath((Join-Path $setupRoot "source-archive-$runId.tar"))
        $runRoot = [IO.Path]::GetFullPath((Split-Path -Parent $candidatePath))
        $childWorkingRoot = [IO.Path]::GetFullPath((Get-Location).Path)
        $pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if (-not (Test-PathWithin -Path $childWorkingRoot -Root $runRoot) -or $childWorkingRoot.Equals($runRoot, $pathComparison)) {
            throw 'Package adapter working directory must be a run-owned child working root.'
        }
        Assert-StandardCoreV2NoReparseAncestors -Path $childWorkingRoot -Context 'Package adapter child working root'
        $expectedUpstreamReportPath = [IO.Path]::GetFullPath((Join-Path $childWorkingRoot "upstream-adapter-report-$runId-$([guid]::NewGuid().ToString('N')).json"))
        $expectedValidatorPath = [IO.Path]::GetFullPath((Join-Path $adapterRoot 'authority-git/scripts/Validate-UpstreamAdapter.ps1'))
        $expectedPolicyPath = [IO.Path]::GetFullPath((Join-Path $adapterRoot 'authority-git/docs/standards/upstream-adapter.json'))
        $sourceProfile = Get-Content -LiteralPath (Join-Path $candidateRoot 'config/standard-core-v2-preparation.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 30 -ErrorAction Stop
        $expectedSourceRepository = [string]$sourceProfile.source.repository
        $currentRuntime = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        if ([string]$toolchain.sourceRepository -cne $expectedSourceRepository -or
            [string]$toolchain.sourceRevision -cne $binding.SourceRevision -or
            -not [IO.Path]::GetFullPath([string]$toolchain.sourceArchivePath).Equals($expectedArchivePath, $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal })) -or
            -not [IO.Path]::GetFullPath([string]$toolchain.upstreamAdapterValidatorPath).Equals($expectedValidatorPath, $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal })) -or
            -not [IO.Path]::GetFullPath([string]$toolchain.upstreamPolicyPath).Equals($expectedPolicyPath, $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal })) -or
            -not [IO.Path]::GetFullPath([string]$toolchain.runtimeExecutable).Equals($currentRuntime, $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }))) {
            throw 'Package adapter toolchain has a path or source identity outside the exact run-derived authority contract.'
        }
        foreach ($frozen in @(
            [pscustomobject]@{ path=$expectedArchivePath; sha256=[string]$toolchain.sourceArchiveSha256; context='source archive' },
            [pscustomobject]@{ path=$expectedValidatorPath; sha256=[string]$toolchain.upstreamAdapterValidatorSha256; context='upstream adapter validator' },
            [pscustomobject]@{ path=$expectedPolicyPath; sha256=[string]$toolchain.upstreamPolicySha256; context='upstream adapter policy' },
            [pscustomobject]@{ path=$currentRuntime; sha256=[string]$toolchain.runtimeSha256; context='PowerShell runtime' }
        )) {
            Assert-StandardCoreV2NoReparseAncestors -Path ([string]$frozen.path) -Context "Frozen $($frozen.context)"
            if (-not (Test-Path -LiteralPath ([string]$frozen.path) -PathType Leaf) -or (Get-FileSha256 -Path ([string]$frozen.path)) -cne [string]$frozen.sha256) {
                throw "Frozen $($frozen.context) bytes changed."
            }
        }
        $archiveItem = Get-Item -LiteralPath $expectedArchivePath -Force
        if ($archiveItem.PSIsContainer -or $archiveItem.Length -ne [long]$toolchain.sourceArchiveLength -or
            [string]$toolchain.sourceArchiveSha256 -cnotmatch '^[0-9a-f]{64}$' -or [long]$toolchain.sourceArchiveLength -le 0) {
            throw 'Frozen source archive length or identity is invalid.'
        }
        if (Test-Path -LiteralPath $expectedUpstreamReportPath) { throw 'Upstream adapter report output path already exists.' }
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
        $adapterArguments = @('-NoLogo','-NoProfile','-NonInteractive','-File',$expectedValidatorPath,
            '-PackageRoot',$candidateRoot,'-PolicyPath',$expectedPolicyPath,'-SourceRepository',[string]$toolchain.sourceRepository,
            '-SourceRevision',$binding.SourceRevision,'-ArchiveSha256',[string]$toolchain.sourceArchiveSha256,'-OutputPath',$expectedUpstreamReportPath)
        $adapterExecution = Invoke-NativeProcessWithEvidence -Command $currentRuntime -Arguments $adapterArguments -Context 'Frozen upstream adapter'
        if ([int]$adapterExecution.exitCode -ne 0) {
            throw "Frozen upstream adapter failed (exit=$($adapterExecution.exitCode)); stdoutPath=$($adapterExecution.stdoutPath); stderrPath=$($adapterExecution.stderrPath)."
        }
        if (-not (Test-Path -LiteralPath $expectedUpstreamReportPath -PathType Leaf)) { throw 'Frozen upstream adapter did not create its report.' }
        $adapterReport = Read-BoundedNativeJsonFile -Path $expectedUpstreamReportPath -Context 'Frozen upstream adapter'
        [void](Assert-StandardCoreV2UpstreamAdapterReport -Report $adapterReport -ExpectedPackageRoot $candidateRoot `
            -ExpectedSourceRepository ([string]$toolchain.sourceRepository) -ExpectedSourceRevision $binding.SourceRevision `
            -ExpectedArchiveSha256 ([string]$toolchain.sourceArchiveSha256))
        $stdoutReport = Read-BoundedNativeJsonFile -Path ([string]$adapterExecution.stdoutPath) -Context 'Frozen upstream adapter stdout'
        if ((ConvertTo-Json -InputObject $stdoutReport -Depth 40 -Compress) -cne (ConvertTo-Json -InputObject $adapterReport -Depth 40 -Compress)) {
            throw 'Frozen upstream adapter stdout differs from its create-new report file.'
        }
        $domainAdapterResult = [ordered]@{
            status='passed'; decision='PASS'; result='atlassian-ecosystem-source-adapter'
            upstreamReportPath=$expectedUpstreamReportPath; upstreamReportSha256=(Get-FileSha256 -Path $expectedUpstreamReportPath); upstreamReport=$adapterReport
            upstreamCommand=$currentRuntime; upstreamCommandSha256=[string]$toolchain.runtimeSha256; upstreamArguments=$adapterArguments; upstreamExitCode=[int]$adapterExecution.exitCode
            sourceArchivePath=$expectedArchivePath; sourceArchiveSha256=[string]$toolchain.sourceArchiveSha256; sourceArchiveLength=[long]$toolchain.sourceArchiveLength
            sourceRepository=[string]$toolchain.sourceRepository; sourceRevision=$binding.SourceRevision
        }
        Write-Envelope -ActiveSkills $activeSkills -Additional @{
            testInventory = @($activeSkills | ForEach-Object { [pscustomobject]@{ id=[string]$_ } })
            testResult = [ordered]@{ status='passed'; decision='PASS'; result='Test-Repository' }
            domainAdapterResult = $domainAdapterResult
        }
    }
    'skill-validator' {
        $skillId = [string]$env:STANDARD_VALIDATION_SKILL_ID
        $skillRoot = Join-Path ([string]$env:STANDARD_VALIDATION_SKILLS_ROOT) $skillId
        $inventory = Get-SkillInventory -SkillRoot $skillRoot
        $command = [string]$toolchain.skillValidatorPath
        if ((Get-FileSha256 -Path $command) -cne [string]$toolchain.skillValidatorSha256) { throw 'skill-validator executable hash changed.' }
        $launcherArguments = @()
        $launcherProperty = $toolchain.PSObject.Properties['skillValidatorLauncherArguments']
        if ($null -ne $launcherProperty) {
            $launcherArguments = @($launcherProperty.Value)
            $runtimePath = [IO.Path]::GetFullPath([string]$toolchain.runtimeExecutable)
            $runtimeHash = [string]$toolchain.runtimeSha256
            $scriptPath = if ($launcherArguments.Count -eq 4) { [IO.Path]::GetFullPath([string]$launcherArguments[3]) } else { '' }
            $workingDirectory = [IO.Path]::GetFullPath((Get-Location).Path)
            $pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
            if ($launcherArguments.Count -ne 4 -or [string]$launcherArguments[0] -cne '-NoProfile' -or
                [string]$launcherArguments[1] -cne '-NonInteractive' -or [string]$launcherArguments[2] -cne '-File' -or
                -not [IO.Path]::GetFullPath($command).Equals($runtimePath, $pathComparison) -or
                (Get-FileSha256 -Path $runtimePath) -cne $runtimeHash -or
                -not (Test-PathWithin -Path $scriptPath -Root $workingDirectory) -or
                -not (Test-Path -LiteralPath $scriptPath -PathType Leaf) -or
                [string]$toolchain.skillValidatorScriptSha256 -cnotmatch '^[0-9a-f]{64}$' -or
                (Get-FileSha256 -Path $scriptPath) -cne [string]$toolchain.skillValidatorScriptSha256) {
                throw 'PowerShell skill-validator launcher is not bound to the current runtime and child-owned script bytes.'
            }
            Assert-StandardCoreV2NoReparseAncestors -Path $scriptPath -Context 'PowerShell skill-validator fixture script'
        }
        $arguments = @($launcherArguments) + @('-o', 'json', 'validate', 'structure', '--allow-dirs=agents', $skillRoot)
        $report = Invoke-NativeJson -Command $command -Arguments $arguments -Context "skill-validator '$skillId'"
        $results = @(Assert-StandardValidationSkillValidatorReport -Report $report -SkillRoot $skillRoot -SkillId $skillId)
        $findings = @(Convert-SkillValidatorFindings -Results $results -SkillRoot $skillRoot -SkillId $skillId -Inventory $inventory)
        Write-Envelope -ActiveSkills $activeSkills -Findings $findings -Additional @{ skillId=$skillId; skillInventorySha256=[string]$env:STANDARD_VALIDATION_SKILL_INVENTORY_SHA256 }
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
        $findings = @(Convert-SkillToolsSarifFindings -Report $report -SkillRoot $skillRoot -SkillId $skillId -Inventory $inventory)
        Write-Envelope -ActiveSkills $activeSkills -Findings $findings -Additional @{ skillId=$skillId; skillInventorySha256=[string]$env:STANDARD_VALIDATION_SKILL_INVENTORY_SHA256 }
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
            try { $report = Read-BoundedNativeJsonFile -Path $reportPath -Context "SkillSpector '$skillId'" }
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
