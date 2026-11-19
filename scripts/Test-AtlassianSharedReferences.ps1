# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [string] $RepositoryRoot,
    [switch] $ReadOnlySnapshot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
}
else {
    [IO.Path]::GetFullPath($RepositoryRoot)
}

$pathMappings = @(
    [pscustomobject]@{
        Source = 'docs/shared-references/configure-api-access/manual-persistence-linux-macos.md'
        Destinations = @(
            'skills/configure-bitbucket-api-access/references/manual-persistence-linux-macos.md'
            'skills/configure-confluence-api-access/references/manual-persistence-linux-macos.md'
            'skills/configure-jira-api-access/references/manual-persistence-linux-macos.md'
        )
    }
    [pscustomobject]@{
        Source = 'docs/shared-references/configure-api-access/shared-workflow.md'
        Destinations = @(
            'skills/configure-bitbucket-api-access/references/shared-workflow.md'
            'skills/configure-confluence-api-access/references/shared-workflow.md'
            'skills/configure-jira-api-access/references/shared-workflow.md'
        )
    }
    [pscustomobject]@{
        Source = 'docs/shared-references/environment-separation/environment-separation.md'
        Destinations = @(
            'skills/configure-bitbucket-api-access/references/environment-separation.md'
            'skills/configure-confluence-api-access/references/environment-separation.md'
            'skills/configure-jira-api-access/references/environment-separation.md'
            'skills/manage-confluence-docs-as-code/references/environment-separation.md'
            'skills/publish-requirements-to-confluence/references/environment-separation.md'
            'skills/work-with-jira/references/environment-separation.md'
        )
    }
)

function Get-RegularFileBytes {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $RelativePath
    )

    if ($RelativePath -cnotmatch '^[A-Za-z0-9._/-]+$' -or $RelativePath -match '(?:^|/)\.{1,2}(?:/|$)') {
        throw "Shared reference path is unsafe: $RelativePath"
    }
    $path = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    $rootPrefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $path.StartsWith($rootPrefix, $comparison)) {
        throw "Shared reference path escapes the repository: $RelativePath"
    }
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Shared reference is not a regular non-reparse file: $RelativePath"
    }
    [IO.File]::ReadAllBytes($path)
}

if (-not (Test-Path -LiteralPath $repoRoot -PathType Container)) {
    throw "Repository root does not exist: $repoRoot"
}

$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$verified = [Collections.Generic.List[object]]::new()
foreach ($mapping in $pathMappings) {
    if (-not $seen.Add([string]$mapping.Source)) {
        throw "Duplicate shared reference source: $($mapping.Source)"
    }
    $sourceBytes = Get-RegularFileBytes -Root $repoRoot -RelativePath ([string]$mapping.Source)
    $sourceHash = (Get-FileHash -LiteralPath (Join-Path $repoRoot ([string]$mapping.Source)) -Algorithm SHA256).Hash.ToLowerInvariant()
    foreach ($destination in @($mapping.Destinations)) {
        if (-not $seen.Add([string]$destination)) {
            throw "Duplicate shared reference destination: $destination"
        }
        $destinationBytes = Get-RegularFileBytes -Root $repoRoot -RelativePath ([string]$destination)
        if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$sourceBytes, [byte[]]$destinationBytes)) {
            throw "Shared reference bytes differ: $destination"
        }
        $verified.Add([pscustomobject][ordered]@{
                source = [string]$mapping.Source
                destination = [string]$destination
                sha256 = $sourceHash
            })
    }
}

[pscustomobject][ordered]@{
    schemaVersion = 1
    repository = 'atlassian-ecosystem'
    mappingCount = $pathMappings.Count
    destinationCount = $verified.Count
    result = 'passed'
} | ConvertTo-Json -Compress
