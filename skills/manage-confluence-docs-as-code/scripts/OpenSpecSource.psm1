# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceRuntime.psm1') -Force -Scope Local

function New-SourceInvalidResult {
    param([Parameter(Mandatory)][string] $Code)
    return [pscustomobject]@{
        status = 'invalid'
        reasonCodes = @($Code)
        diagnostics = @([pscustomobject]@{ code = $Code; path = ''; line = 0 })
        nativeValidation = [pscustomobject]@{ valid = $false }
        requirements = @()
        scenarios = @()
    }
}

function New-SourceEnvironmentContract {
    $variables = [ordered]@{}
    $pathValue = [Environment]::GetEnvironmentVariable('PATH', 'Process')
    if ([string]::IsNullOrWhiteSpace($pathValue)) {
        $pathValue = [Environment]::GetEnvironmentVariable('Path', 'Process')
    }
    if (-not [string]::IsNullOrWhiteSpace($pathValue)) { $variables['PATH'] = $pathValue }

    foreach ($name in @('SystemRoot', 'TEMP', 'TMP')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if (-not [string]::IsNullOrWhiteSpace($value)) { $variables[$name] = $value }
    }
    $isWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    $missingWindowsVariables = @('SystemRoot', 'TEMP', 'TMP' | Where-Object { -not $variables.Contains([string]$_) })
    if (-not $variables.Contains('PATH') -or ($isWindows -and $missingWindowsVariables.Count -gt 0)) {
        return $null
    }

    $variables['CI'] = '1'
    $variables['OPENSPEC_TELEMETRY'] = '0'
    $variables['OPENSPEC_NO_UPDATE_CHECK'] = '1'
    foreach ($entry in $variables.GetEnumerator()) {
        if ($entry.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$entry.Value) -or
            ([string]$entry.Value).Length -gt 32767 -or ([string]$entry.Value).IndexOf([char]0) -ge 0) {
            return $null
        }
    }

    return [ordered]@{
        contract = 'syp171-openspec-native-environment-v1'
        version = 1
        variables = $variables
    }
}

function Test-OpenSpecSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,99}$')][string] $ChangeId,
        [Parameter(Mandatory)][string] $RuntimeRoot,
        [ref] $RuntimeReceiptSha256
    )

    $readerPath = Join-Path $PSScriptRoot 'source-reader.mjs'
    if (-not (Test-Path -LiteralPath $readerPath -PathType Leaf)) { return New-SourceInvalidResult -Code 'SourceReaderUnavailable' }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return New-SourceInvalidResult -Code 'SourceRootUnavailable' }

    $resolvedRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $resolvedReader = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $readerPath).Path)
    $resolvedRuntime = [IO.Path]::GetFullPath($RuntimeRoot)
    $receiptPath = "$($resolvedRuntime.TrimEnd('\','/')).receipt.json"
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { return New-SourceInvalidResult -Code 'RuntimeReceiptUnavailable' }
    try {
        $receiptHash = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $runtimeCheck = Test-ConfluenceDocsRuntimeReceipt -ReceiptPath $receiptPath -ReceiptSha256 $receiptHash -RuntimeSourceRoot $PSScriptRoot
    }
    catch { return New-SourceInvalidResult -Code 'RuntimeReceiptInvalid' }
    if ($runtimeCheck.status -cne 'valid') {
        $runtimeCode = [string]@($runtimeCheck.reasonCodes | Select-Object -First 1)[0]
        if ([string]::IsNullOrWhiteSpace($runtimeCode)) { $runtimeCode = 'RuntimeReceiptInvalid' }
        return New-SourceInvalidResult -Code $runtimeCode
    }
    $verifiedRuntime = [IO.Path]::GetFullPath([string]$runtimeCheck.runtimeRoot).TrimEnd('\','/')
    if ($verifiedRuntime -cne $resolvedRuntime.TrimEnd('\','/')) { return New-SourceInvalidResult -Code 'RuntimeReceiptInvalid' }
    $verifiedNode = [IO.Path]::GetFullPath([string]$runtimeCheck.nodePath)
    if (-not (Test-Path -LiteralPath $verifiedNode -PathType Leaf)) { return New-SourceInvalidResult -Code 'RuntimeReceiptInvalid' }
    if ($null -ne $RuntimeReceiptSha256) { $RuntimeReceiptSha256.Value = $receiptHash }
    $environmentContract = New-SourceEnvironmentContract
    if ($null -eq $environmentContract) { return New-SourceInvalidResult -Code 'SourceEnvironmentContractInvalid' }
    $request = [ordered]@{
        operation = 'validateOpenSpec'
        root = $resolvedRoot
        changeId = $ChangeId
        environmentContract = $environmentContract
    } | ConvertTo-Json -Depth 8 -Compress

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $verifiedNode
    $start.ArgumentList.Add($resolvedReader)
    $start.ArgumentList.Add($resolvedRuntime)
    $start.WorkingDirectory = $resolvedRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardInputEncoding = [Text.UTF8Encoding]::new($false, $true)
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false, $true)
    $start.Environment.Clear()
    foreach ($entry in $environmentContract.variables.GetEnumerator()) {
        $start.Environment[[string]$entry.Key] = [string]$entry.Value
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { return New-SourceInvalidResult -Code 'SourceReaderFailure' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($request)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill($true)
            return New-SourceInvalidResult -Code 'SourceReaderTimeout'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $null = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or $stdout.Length -gt 4MB) { return New-SourceInvalidResult -Code 'SourceReaderFailure' }
        try { $result = $stdout | ConvertFrom-Json -Depth 30 -ErrorAction Stop }
        catch { return New-SourceInvalidResult -Code 'SourceReaderOutputInvalid' }
        if ($result.status -notin @('valid', 'invalid') -or $null -eq $result.reasonCodes) {
            return New-SourceInvalidResult -Code 'SourceReaderOutputInvalid'
        }
        return $result
    }
    catch { return New-SourceInvalidResult -Code 'SourceReaderFailure' }
    finally { $process.Dispose() }
}

Export-ModuleMember -Function Test-OpenSpecSource
