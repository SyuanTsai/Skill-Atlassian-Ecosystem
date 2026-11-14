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
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        $item = Get-Item -LiteralPath $candidate -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $item.LinkType) {
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
        throw "Shared reference source is missing or is not a file: $($mapping.Source)"
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

$inconsistent = [Collections.Generic.List[string]]::new()
foreach ($resolved in $resolvedMappings) {
    $matches = $false
    if (Test-Path -LiteralPath $resolved.FullPath -PathType Leaf) {
        $matches = Test-ByteEquality -Expected $resolved.SourceBytes -Actual ([IO.File]::ReadAllBytes($resolved.FullPath))
    }

    if ($matches) { continue }
    $inconsistent.Add($resolved.RelativePath)
    if (-not $Check) {
        [IO.File]::WriteAllBytes($resolved.FullPath, $resolved.SourceBytes)
    }
}

if ($Check -and $inconsistent.Count -gt 0) {
    foreach ($relativePath in $inconsistent) {
        [Console]::Error.WriteLine("Shared reference is missing or differs: $relativePath")
    }
    exit 1
}

exit 0
