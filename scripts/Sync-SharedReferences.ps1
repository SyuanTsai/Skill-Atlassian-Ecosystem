# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()][switch] $Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$pathMappings = @(
    [pscustomobject]@{
        Source = 'docs/shared-references/configure-api-access/manual-persistence-linux-macos.md'
        Destinations = @(
            'skills/configure-bitbucket-api-access/references/manual-persistence-linux-macos.md'
            'skills/configure-confluence-api-access/references/manual-persistence-linux-macos.md'
            'skills/configure-jira-api-access/references/manual-persistence-linux-macos.md'
        )
    }
)

function Resolve-RepositoryRelativePath {
    param(
        [Parameter(Mandatory)][string] $RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathFullyQualified($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath)) {
        throw "Shared reference path must be repository-relative: $RelativePath"
    }

    $segments = @($RelativePath -split '[\\/]')
    if ($segments.Count -eq 0 -or @($segments | Where-Object { $_ -ceq '..' }).Count -gt 0) {
        throw "Shared reference path must not contain '..': $RelativePath"
    }

    $fullPath = [IO.Path]::GetFullPath((Join-Path $repositoryRoot $RelativePath))
    $rootPrefix = $repositoryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($rootPrefix, $pathComparison)) {
        throw "Shared reference path escapes the repository: $RelativePath"
    }
    return $fullPath
}

function Assert-NoRepositoryReparsePoint {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $RelativePath
    )

    $relative = [IO.Path]::GetRelativePath($repositoryRoot, $Path)
    $cursor = $repositoryRoot
    $pathsToInspect = [Collections.Generic.List[string]]::new()
    $pathsToInspect.Add($repositoryRoot)
    foreach ($segment in @($relative -split '[\\/]')) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -ceq '.') { continue }
        $cursor = Join-Path $cursor $segment
        $pathsToInspect.Add($cursor)
    }

    foreach ($candidate in $pathsToInspect) {
        # FileInfo reads link metadata without resolving the target, including for
        # dangling symbolic links and junctions. Missing entries report -1 for
        # Attributes and have no LinkTarget.
        $item = [IO.FileInfo]::new($candidate)
        $attributes = $item.Attributes
        $linkTarget = $item.LinkTarget
        if (([int]$attributes -ne -1 -and ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
            -not [string]::IsNullOrEmpty($linkTarget)) {
            throw "Shared reference path contains a reparse point: $RelativePath"
        }
    }
}

function Test-ByteEquality {
    param(
        [Parameter(Mandatory)][byte[]] $Expected,
        [Parameter(Mandatory)][byte[]] $Actual
    )

    if ($Expected.Length -ne $Actual.Length) { return $false }
    for ($index = 0; $index -lt $Expected.Length; $index++) {
        if ($Expected[$index] -ne $Actual[$index]) { return $false }
    }
    return $true
}

$resolvedMappings = foreach ($mapping in $pathMappings) {
    $sourcePath = Resolve-RepositoryRelativePath -RelativePath $mapping.Source
    Assert-NoRepositoryReparsePoint -Path $sourcePath -RelativePath $mapping.Source
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw ("Shared reference source is missing or is not a file: {0}" -f $mapping.Source)
    }

    $sourceBytes = [IO.File]::ReadAllBytes($sourcePath)
    foreach ($destination in $mapping.Destinations) {
        $destinationPath = Resolve-RepositoryRelativePath -RelativePath $destination
        Assert-NoRepositoryReparsePoint -Path $destinationPath -RelativePath $destination
        if ((Test-Path -LiteralPath $destinationPath) -and -not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
            throw "Shared reference destination is not a file: $destination"
        }
        [pscustomobject]@{
            RelativePath = $destination
            FullPath = $destinationPath
            SourceBytes = $sourceBytes
        }
    }
}

$inconsistent = [Collections.Generic.List[object]]::new()
foreach ($resolved in $resolvedMappings) {
    $matches = $false
    if (Test-Path -LiteralPath $resolved.FullPath -PathType Leaf) {
        $matches = Test-ByteEquality -Expected $resolved.SourceBytes -Actual ([IO.File]::ReadAllBytes($resolved.FullPath))
    }

    if ($matches) { continue }
    $inconsistent.Add($resolved)
}

if ($Check -and $inconsistent.Count -gt 0) {
    foreach ($resolved in $inconsistent) {
        [Console]::Error.WriteLine("Shared reference is missing or differs: {0}", $resolved.RelativePath)
    }
    exit 1
}

if ($inconsistent.Count -eq 0) { exit 0 }

$failStagingIndex = 0
$failStagingSetting = $env:SYP_SHARED_REFERENCES_TEST_FAIL_STAGING_INDEX
if (-not [string]::IsNullOrWhiteSpace($failStagingSetting) -and
    -not [int]::TryParse($failStagingSetting, [ref]$failStagingIndex)) {
    throw 'SYP_SHARED_REFERENCES_TEST_FAIL_STAGING_INDEX must be an integer.'
}

$staged = [Collections.Generic.List[object]]::new()
try {
    $stagingIndex = 0
    foreach ($resolved in $inconsistent) {
        $stagingIndex++
        if ($failStagingIndex -gt 0 -and $stagingIndex -eq $failStagingIndex) {
            throw ("Test-only staging failure at index {0}." -f $stagingIndex)
        }

        $parentPath = Split-Path -Parent $resolved.FullPath
        $destinationName = Split-Path -Leaf $resolved.FullPath
        $temporaryName = ".{0}.{1}.tmp" -f $destinationName, [guid]::NewGuid().ToString('N')
        $temporaryPath = Join-Path $parentPath $temporaryName
        $stream = [IO.File]::Open(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        $staged.Add([pscustomobject]@{
            RelativePath = $resolved.RelativePath
            FullPath = $resolved.FullPath
            TemporaryPath = $temporaryPath
            SourceBytes = $resolved.SourceBytes
        })
        try {
            $stream.Write($resolved.SourceBytes, 0, $resolved.SourceBytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }

        $stagedBytes = [IO.File]::ReadAllBytes($temporaryPath)
        if (-not (Test-ByteEquality -Expected $resolved.SourceBytes -Actual $stagedBytes)) {
            throw ("Staged shared reference differs after write: {0}" -f $resolved.RelativePath)
        }
    }
}
catch {
    foreach ($entry in $staged) {
        if ([IO.File]::Exists($entry.TemporaryPath)) {
            [IO.File]::Delete($entry.TemporaryPath)
        }
    }
    throw ("Shared reference staging failed; destination files were not changed: {0}" -f $_.Exception.Message)
}

try {
    # Each move is an atomic same-directory replacement. If a later commit fails,
    # rerunning this script safely converges any already-replaced destinations.
    foreach ($entry in $staged) {
        [IO.File]::Move($entry.TemporaryPath, $entry.FullPath, $true)
    }
    foreach ($entry in $staged) {
        $destinationBytes = [IO.File]::ReadAllBytes($entry.FullPath)
        if (-not (Test-ByteEquality -Expected $entry.SourceBytes -Actual $destinationBytes)) {
            throw ("Committed shared reference differs after replacement: {0}" -f $entry.RelativePath)
        }
    }
}
catch {
    foreach ($entry in $staged) {
        if ([IO.File]::Exists($entry.TemporaryPath)) {
            [IO.File]::Delete($entry.TemporaryPath)
        }
    }
    throw ("Shared reference commit failed; rerun synchronization to converge: {0}" -f $_.Exception.Message)
}

exit 0
