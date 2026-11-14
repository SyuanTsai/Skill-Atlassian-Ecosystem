# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This developer generator is not run by CI. It follows the Build-AiInstructions
# precedent of comparing bytes before calling WriteAllBytes. Under the 2026-11-14
# controller decision, developer generators are outside the path-safety rules.
$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$sourceRelativePath = 'docs/shared-references/configure-api-access/manual-persistence-linux-macos.md'
$destinationRelativePaths = @(
    'skills/configure-bitbucket-api-access/references/manual-persistence-linux-macos.md'
    'skills/configure-confluence-api-access/references/manual-persistence-linux-macos.md'
    'skills/configure-jira-api-access/references/manual-persistence-linux-macos.md'
)
$pathComparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    [StringComparison]::OrdinalIgnoreCase
}
else {
    [StringComparison]::Ordinal
}

function Test-FileSystemInfoLink {
    param([Parameter(Mandatory)][IO.FileSystemInfo] $Info)

    $linkTargetProperty = $Info.PSObject.Properties['LinkTarget']
    if (
        $null -ne $linkTargetProperty -and
        $null -ne $linkTargetProperty.Value -and
        [string]$linkTargetProperty.Value -cne ''
    ) {
        return $true
    }
    try {
        $attributes = $Info.Attributes
        if ([int]$attributes -eq -1) { return $false }
        return ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    }
    catch {
        return $false
    }
}

function Test-ByteArrayEqual {
    param(
        [Parameter(Mandatory)][byte[]] $Left,
        [Parameter(Mandatory)][byte[]] $Right
    )

    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -cne $Right[$index]) { return $false }
    }
    return $true
}

function Assert-SafeRelativePath {
    param([Parameter(Mandatory)][string] $RelativePath)

    $segments = @($RelativePath.Replace('\', '/').Split('/'))
    if ([IO.Path]::IsPathRooted($RelativePath) -or $segments -contains '..') {
        throw [IO.InvalidDataException]::new(('Mapped path must be relative and contain no parent segment: {0}' -f $RelativePath))
    }
}

function Assert-DestinationPreflight {
    param(
        [Parameter(Mandatory)][string] $RelativePath,
        [Parameter(Mandatory)][byte[]] $SourceBytes
    )

    Assert-SafeRelativePath -RelativePath $RelativePath
    $fullPath = [IO.Path]::GetFullPath([IO.Path]::Combine($repositoryRoot, $RelativePath))
    $rootPrefix = $repositoryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($rootPrefix, $pathComparison)) {
        throw [IO.InvalidDataException]::new(('Mapped destination is outside the repository root: {0}' -f $RelativePath))
    }

    $destinationInfo = [IO.FileInfo]::new($fullPath)
    $destinationInfo.Refresh()
    if (Test-FileSystemInfoLink -Info $destinationInfo) {
        throw [IO.IOException]::new(('Destination must not be a link or reparse point: {0}' -f $RelativePath))
    }
    $destinationDirectoryInfo = [IO.DirectoryInfo]::new($fullPath)
    $destinationDirectoryInfo.Refresh()
    if ($destinationDirectoryInfo.Exists) {
        throw [IO.IOException]::new(('Destination must be a regular file: {0}' -f $RelativePath))
    }

    $parentPath = [IO.Path]::GetDirectoryName($fullPath)
    while ($null -ne $parentPath) {
        $parentInfo = [IO.DirectoryInfo]::new($parentPath)
        $parentInfo.Refresh()
        if (Test-FileSystemInfoLink -Info $parentInfo) {
            throw [IO.IOException]::new(('Destination ancestor must not be a link or reparse point: {0}' -f $RelativePath))
        }
        if (-not $parentInfo.Exists) {
            throw [IO.DirectoryNotFoundException]::new(('Destination parent directory does not exist: {0}' -f $RelativePath))
        }
        if ($parentPath.Equals($repositoryRoot, $pathComparison)) { break }
        $nextParent = [IO.Path]::GetDirectoryName($parentPath)
        if ($null -eq $nextParent -or $nextParent.Equals($parentPath, $pathComparison)) {
            throw [IO.InvalidDataException]::new(('Destination ancestor traversal did not reach the repository root: {0}' -f $RelativePath))
        }
        $parentPath = $nextParent
    }

    $currentBytes = if ($destinationInfo.Exists) {
        [IO.File]::ReadAllBytes($fullPath)
    }
    else {
        $null
    }
    return [pscustomobject]@{
        RelativePath = $RelativePath
        FullPath = $fullPath
        NeedsWrite = $null -eq $currentBytes -or -not (Test-ByteArrayEqual -Left $currentBytes -Right $SourceBytes)
    }
}

function Write-SharedReferenceCopy {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][byte[]] $Bytes
    )

    [IO.File]::WriteAllBytes($Path, $Bytes)
}

try {
    Assert-SafeRelativePath -RelativePath $sourceRelativePath
    $sourcePath = [IO.Path]::GetFullPath([IO.Path]::Combine($repositoryRoot, $sourceRelativePath))
    $sourceInfo = [IO.FileInfo]::new($sourcePath)
    $sourceInfo.Refresh()
    if (Test-FileSystemInfoLink -Info $sourceInfo) {
        throw [IO.IOException]::new(('Source must not be a link or reparse point: {0}' -f $sourceRelativePath))
    }
    if (-not $sourceInfo.Exists) {
        throw [IO.FileNotFoundException]::new(('Source does not exist: {0}' -f $sourceRelativePath))
    }
    $sourceBytes = [IO.File]::ReadAllBytes($sourcePath)
    if ($sourceBytes.Length -eq 0) {
        throw [IO.InvalidDataException]::new(('Source is empty: {0}' -f $sourceRelativePath))
    }

    $destinations = @(
        foreach ($relativePath in $destinationRelativePaths) {
            Assert-DestinationPreflight -RelativePath $relativePath -SourceBytes $sourceBytes
        }
    )
    foreach ($destination in $destinations) {
        if ($destination.NeedsWrite) {
            Write-SharedReferenceCopy -Path $destination.FullPath -Bytes $sourceBytes
            [Console]::WriteLine('updated {0}', $destination.RelativePath)
        }
        else {
            [Console]::WriteLine('unchanged {0}', $destination.RelativePath)
        }
    }
    [Console]::WriteLine('Stage the copies, then run scripts/Test-SharedReferences.ps1.')
    exit 0
}
catch {
    [Console]::Error.WriteLine('Shared reference sync failed: {0}', $_.Exception.Message)
    exit 1
}
