# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest

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

function Test-OpenSpecSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,99}$')][string] $ChangeId,
        [Parameter(Mandatory)][string] $RuntimeRoot
    )

    $readerPath = Join-Path $PSScriptRoot 'source-reader.mjs'
    if (-not (Test-Path -LiteralPath $readerPath -PathType Leaf)) { return New-SourceInvalidResult -Code 'SourceReaderUnavailable' }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return New-SourceInvalidResult -Code 'SourceRootUnavailable' }
    $nodeCommand = Get-Command -Name node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $nodeCommand) { return New-SourceInvalidResult -Code 'NodeUnavailable' }

    $resolvedRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $resolvedReader = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $readerPath).Path)
    $resolvedRuntime = [IO.Path]::GetFullPath($RuntimeRoot)
    $request = [ordered]@{ operation = 'validateOpenSpec'; root = $resolvedRoot; changeId = $ChangeId } | ConvertTo-Json -Compress

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = [string] $nodeCommand.Source
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
    foreach ($key in @('PATH', 'Path', 'SystemRoot', 'TEMP', 'TMP')) {
        $value = [Environment]::GetEnvironmentVariable($key, 'Process')
        if (-not [string]::IsNullOrWhiteSpace($value)) { $start.Environment[$key] = $value }
    }
    $start.Environment['CI'] = '1'
    $start.Environment['OPENSPEC_TELEMETRY'] = '0'
    $start.Environment['OPENSPEC_NO_UPDATE_CHECK'] = '1'

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
