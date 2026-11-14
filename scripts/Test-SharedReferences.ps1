# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$runtimeManifestRelativePath = 'scripts/platform-runtime.psd1'
$maximumReferenceBytes = 16MB
$maximumAuthorityTextBytes = 64MB
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

function Read-AuthorityText {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][int64] $MaximumBytes
    )

    # OpenRead is the only pathname-based file read used before the authority
    # runtime is verified and imported. It is read-only and hash-bound below.
    $stream = [IO.File]::OpenRead($Path)
    try {
        if ($stream.Length -gt $MaximumBytes) {
            throw [IO.InvalidDataException]::new('Authority data exceeds the bounded read limit.')
        }
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, $true), $true)
        try { return $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-PathSha256 {
    param([Parameter(Mandatory)][string] $Path)

    # This read is intentionally limited to pre-import authority verification.
    $stream = [IO.File]::OpenRead($Path)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Get-BytesSha256 {
    param([Parameter(Mandatory)][byte[]] $Bytes)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha256.Dispose() }
}

function Assert-PlatformRuntimeAuthority {
    $configPath = [IO.Path]::Combine($repositoryRoot, 'config', 'standard-v1.json')
    $configText = Read-AuthorityText -Path $configPath -MaximumBytes $maximumAuthorityTextBytes
    $config = $configText | ConvertFrom-Json -Depth 100
    if ($null -eq $config.authority -or $null -eq $config.authority.files) {
        throw [IO.InvalidDataException]::new('config/standard-v1.json has no authority file inventory.')
    }

    $authority = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($config.authority.files)) {
        $properties = @($entry.PSObject.Properties.Name)
        if ($properties.Count -ne 2 -or $properties -cnotcontains 'path' -or $properties -cnotcontains 'sha256' -or
            $entry.path -isnot [string] -or $entry.sha256 -isnot [string] -or
            [string]$entry.path -cnotmatch '^[^\\]+(?:/[^\\]+)*$' -or
            [string]$entry.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            -not $authority.TryAdd([string]$entry.path, [string]$entry.sha256)) {
            throw [IO.InvalidDataException]::new('config/standard-v1.json has an invalid or duplicate authority file entry.')
        }
    }

    if (-not $authority.ContainsKey($runtimeManifestRelativePath)) {
        throw [IO.InvalidDataException]::new('The platform runtime manifest is not pinned by standard authority.')
    }
    $manifestPath = [IO.Path]::Combine($repositoryRoot, 'scripts', 'platform-runtime.psd1')
    if ((Get-PathSha256 -Path $manifestPath) -cne $authority[$runtimeManifestRelativePath]) {
        throw [IO.InvalidDataException]::new('Platform runtime authority hash mismatch: scripts/platform-runtime.psd1')
    }

    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    if ([string]$manifest.RootModule -cne 'platform-runtime.psm1' -or $null -eq $manifest.FileList) {
        throw [IO.InvalidDataException]::new('The verified platform runtime manifest has an invalid closure.')
    }

    $runtimePaths = [Collections.Generic.List[string]]::new()
    $seenRuntimePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($relativePathValue in @($manifest.FileList)) {
        if ($relativePathValue -isnot [string]) {
            throw [IO.InvalidDataException]::new('The verified platform runtime manifest contains a non-string FileList entry.')
        }
        $relativePath = ([string]$relativePathValue).Replace('\', '/')
        $segments = @($relativePath.Split('/'))
        if ([string]::IsNullOrWhiteSpace($relativePath) -or [IO.Path]::IsPathRooted($relativePath) -or
            @($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -ceq '.' -or $_ -ceq '..' }).Count -gt 0) {
            throw [IO.InvalidDataException]::new('The verified platform runtime manifest contains an unsafe FileList entry.')
        }
        $repositoryRelativePath = 'scripts/' + $relativePath
        if (-not $seenRuntimePaths.Add($repositoryRelativePath)) {
            throw [IO.InvalidDataException]::new('The verified platform runtime manifest contains a duplicate FileList entry.')
        }
        $runtimePaths.Add($repositoryRelativePath)
    }
    if (-not $seenRuntimePaths.Contains($runtimeManifestRelativePath) -or
        -not $seenRuntimePaths.Contains('scripts/platform-runtime.psm1')) {
        throw [IO.InvalidDataException]::new('The verified platform runtime manifest omits its manifest or root module.')
    }

    $platformRoot = [IO.Path]::Combine($repositoryRoot, 'scripts', 'platform')
    if (@([IO.Directory]::EnumerateDirectories($platformRoot)).Count -ne 0) {
        throw [IO.InvalidDataException]::new('The vendored platform runtime directory contains an unpinned subdirectory.')
    }
    $actualPlatformPaths = @(
        [IO.Directory]::EnumerateFiles($platformRoot) |
            ForEach-Object { 'scripts/platform/' + [IO.Path]::GetFileName($_) } |
            Sort-Object
    )
    $declaredPlatformPaths = @(
        $runtimePaths |
            Where-Object { $_.StartsWith('scripts/platform/', [StringComparison]::Ordinal) } |
            Sort-Object
    )
    if (($actualPlatformPaths -join [char]10) -cne ($declaredPlatformPaths -join [char]10)) {
        throw [IO.InvalidDataException]::new('The vendored platform runtime directory differs from its pinned FileList.')
    }

    foreach ($runtimePath in $runtimePaths) {
        if (-not $authority.ContainsKey($runtimePath)) {
            throw [IO.InvalidDataException]::new(('Platform runtime file is not pinned by standard authority: {0}' -f $runtimePath))
        }
        $fullPath = [IO.Path]::Combine($repositoryRoot, $runtimePath.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if ((Get-PathSha256 -Path $fullPath) -cne $authority[$runtimePath]) {
            throw [IO.InvalidDataException]::new(('Platform runtime authority hash mismatch: {0}' -f $runtimePath))
        }
    }

    return [pscustomobject]@{
        ManifestPath = $manifestPath
        RuntimePaths = [string[]]$runtimePaths.ToArray()
        Authority = $authority
    }
}

function Import-VerifiedPlatformRuntime {
    param([Parameter(Mandatory)] $AuthorityReceipt)

    $loadedModules = @(Import-Module -Name $AuthorityReceipt.ManifestPath -PassThru -Scope Global -ErrorAction Stop)
    $expectedRootModulePath = [IO.Path]::Combine($repositoryRoot, 'scripts', 'platform-runtime.psm1')
    if ($loadedModules.Count -ne 1 -or
        -not [StringComparer]::Ordinal.Equals(
            [IO.Path]::GetFullPath([string]$loadedModules[0].Path),
            [IO.Path]::GetFullPath($expectedRootModulePath))) {
        throw [IO.InvalidDataException]::new('The platform runtime did not load the verified root module.')
    }

    $inventory = Assert-PlatformRuntimeInventory -Root $PSScriptRoot -ManifestPath $AuthorityReceipt.ManifestPath
    if ([string]$inventory.apiVersion -cne '1.0' -or [string]$inventory.hashMode -cne 'sha256-utf8-lf') {
        throw [IO.InvalidDataException]::new('The platform runtime returned an unsupported verified inventory receipt.')
    }
    foreach ($entry in @($inventory.files)) {
        $repositoryRelativePath = 'scripts/' + ([string]$entry.path).Replace('\', '/')
        if (-not $AuthorityReceipt.Authority.ContainsKey($repositoryRelativePath) -or
            [string]$entry.sha256 -cne $AuthorityReceipt.Authority[$repositoryRelativePath]) {
            throw [IO.InvalidDataException]::new(('Imported platform runtime inventory differs from authority: {0}' -f $repositoryRelativePath))
        }
    }

    return $loadedModules[0]
}

function Split-SharedReferencePath {
    param([Parameter(Mandatory)][string] $RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathFullyQualified($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath)) {
        throw ('Shared reference path must be repository-relative: {0}' -f $RelativePath)
    }
    $segments = @($RelativePath -split '[\\/]')
    if ($segments.Count -lt 2 -or
        @($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -ceq '.' -or $_ -ceq '..' }).Count -gt 0) {
        throw ('Shared reference path has an invalid component: {0}' -f $RelativePath)
    }
    return [pscustomobject]@{
        Parent = [string]::Join('/', $segments[0..($segments.Count - 2)])
        Leaf = $segments[-1]
    }
}

function Get-PlatformIdentityReceipt {
    param(
        [Parameter(Mandatory)] $Observation,
        [Parameter(Mandatory)][string] $Platform
    )

    if ($Platform -ceq 'windows') {
        return [pscustomobject][ordered]@{
            kind = 'windows-file-id'
            device = '0x{0:x}' -f [uint64]$Observation.Device
            fileId = '0x{0:x}' -f [uint64]$Observation.Inode
        }
    }
    return [pscustomobject][ordered]@{
        kind = 'unix-device-inode'
        device = ([uint64]$Observation.Device).ToString([Globalization.CultureInfo]::InvariantCulture)
        fileId = ([uint64]$Observation.Inode).ToString([Globalization.CultureInfo]::InvariantCulture)
    }
}

function Get-OpenFileReceipt {
    param(
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][string] $Platform,
        [Parameter(Mandatory)][int] $MaximumBytes
    )

    Assert-PlatformFileIdentity -Lease $Lease -Expected $Lease.Observation -SingleLink -VerifyPath | Out-Null
    [byte[]]$bytes = $Lease.ReadAllBytes($MaximumBytes)
    $observation = Assert-PlatformFileIdentity -Lease $Lease -Expected $Lease.Observation -SingleLink -VerifyPath
    $sha256 = Get-BytesSha256 -Bytes $bytes
    return [pscustomobject]@{
        Bytes = $bytes
        State = [pscustomobject][ordered]@{
            exists = $true
            sha256 = $sha256
            length = [int64]$bytes.Length
            identity = Get-PlatformIdentityReceipt -Observation $observation -Platform $Platform
        }
    }
}

function Test-MissingPlatformFileError {
    param(
        [Parameter(Mandatory)][Exception] $Exception,
        [Parameter(Mandatory)][string] $Platform
    )

    $candidate = $Exception
    while ($null -ne $candidate) {
        if ($Platform -ceq 'windows' -and
            $candidate.GetType().FullName -ceq 'SyuanTsai.AIInstructions.PlatformRuntime.PlatformWin32Exception' -and
            [int]$candidate.Win32Error -eq 2) {
            return $true
        }
        if ($Platform -cne 'windows' -and
            $candidate.GetType().FullName -ceq 'SyuanTsai.AIInstructions.PlatformRuntime.PlatformErrnoException' -and
            [int]$candidate.Errno -eq 2) {
            return $true
        }
        $candidate = $candidate.InnerException
    }
    return $false
}

function Open-SharedReferenceParent {
    param([Parameter(Mandatory)][string] $RelativePath)

    $parts = Split-SharedReferencePath -RelativePath $RelativePath
    $parentLease = Open-PlatformDirectory -Root $repositoryRoot -RelativePath $parts.Parent
    return [pscustomobject]@{
        ParentLease = $parentLease
        Leaf = $parts.Leaf
    }
}

function Read-SharedReferenceFile {
    param(
        [Parameter(Mandatory)] $ParentLease,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][string] $Platform,
        [Parameter()][switch] $AllowMissing
    )

    $fileLease = $null
    try {
        try {
            $fileLease = Open-PlatformFile -ParentLease $ParentLease -Leaf $Leaf -Access Read -CreateMode OpenExisting
        }
        catch {
            if ($AllowMissing -and (Test-MissingPlatformFileError -Exception $_.Exception -Platform $Platform)) {
                return [pscustomobject]@{
                    Bytes = $null
                    State = [pscustomobject][ordered]@{
                        exists = $false
                        sha256 = $null
                        length = $null
                        identity = $null
                    }
                }
            }
            throw
        }
        return Get-OpenFileReceipt -Lease $fileLease -Platform $Platform -MaximumBytes $maximumReferenceBytes
    }
    finally {
        if ($null -ne $fileLease) { $fileLease.Dispose() }
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

function Assert-ImportedRuntimeFilesByLease {
    param(
        [Parameter(Mandatory)] $AuthorityReceipt,
        [Parameter(Mandatory)][string] $Platform
    )

    foreach ($runtimePath in $AuthorityReceipt.RuntimePaths) {
        $parts = Split-SharedReferencePath -RelativePath $runtimePath
        $parentLease = $null
        $fileLease = $null
        try {
            $parentLease = Open-PlatformDirectory -Root $repositoryRoot -RelativePath $parts.Parent
            $fileLease = Open-PlatformFile -ParentLease $parentLease -Leaf $parts.Leaf -Access Read -CreateMode OpenExisting
            $receipt = Get-OpenFileReceipt -Lease $fileLease -Platform $Platform -MaximumBytes $maximumReferenceBytes
            if ([string]$receipt.State.sha256 -cne $AuthorityReceipt.Authority[$runtimePath]) {
                throw [IO.InvalidDataException]::new(('Platform runtime lease read differs from authority: {0}' -f $runtimePath))
            }
        }
        finally {
            if ($null -ne $fileLease) { $fileLease.Dispose() }
            if ($null -ne $parentLease) { $parentLease.Dispose() }
        }
    }
}

function Invoke-SharedReferenceCheck {
    $authorityReceipt = Assert-PlatformRuntimeAuthority
    $runtimeModule = Import-VerifiedPlatformRuntime -AuthorityReceipt $authorityReceipt
    if ($null -eq $runtimeModule) {
        throw [IO.InvalidDataException]::new('The verified platform runtime module receipt is missing.')
    }

    $capabilities = Get-PlatformCapabilities -Required @(
        'directory-lease'
        'file-lease'
        'file-identity'
    )
    $platform = [string]$capabilities.os
    $repositoryLease = $null
    $problems = [Collections.Generic.List[object]]::new()
    try {
        $repositoryLease = Open-PlatformDirectory -Root $repositoryRoot -RootOnly
        Assert-ImportedRuntimeFilesByLease -AuthorityReceipt $authorityReceipt -Platform $platform

        foreach ($mapping in $pathMappings) {
            $sourceParent = $null
            $source = $null
            try {
                $sourceParent = Open-SharedReferenceParent -RelativePath $mapping.Source
                $source = Read-SharedReferenceFile -ParentLease $sourceParent.ParentLease -Leaf $sourceParent.Leaf -Platform $platform
            }
            catch {
                $problems.Add([pscustomobject]@{ Path = $mapping.Source; Detail = $_.Exception.Message })
            }
            finally {
                if ($null -ne $sourceParent -and $null -ne $sourceParent.ParentLease) {
                    $sourceParent.ParentLease.Dispose()
                }
            }

            foreach ($destination in $mapping.Destinations) {
                if ($null -eq $source) {
                    $problems.Add([pscustomobject]@{ Path = $destination; Detail = 'Source could not be read safely.' })
                    continue
                }
                $destinationParent = $null
                try {
                    $destinationParent = Open-SharedReferenceParent -RelativePath $destination
                    $current = Read-SharedReferenceFile -ParentLease $destinationParent.ParentLease -Leaf $destinationParent.Leaf -Platform $platform -AllowMissing
                    if (-not $current.State.exists) {
                        $problems.Add([pscustomobject]@{ Path = $destination; Detail = 'Copy is missing.' })
                    }
                    elseif (-not (Test-ByteEquality -Expected $source.Bytes -Actual $current.Bytes)) {
                        $problems.Add([pscustomobject]@{ Path = $destination; Detail = 'Copy bytes differ from the source.' })
                    }
                }
                catch {
                    $problems.Add([pscustomobject]@{ Path = $destination; Detail = $_.Exception.Message })
                }
                finally {
                    if ($null -ne $destinationParent -and $null -ne $destinationParent.ParentLease) {
                        $destinationParent.ParentLease.Dispose()
                    }
                }
            }
        }

        if ($problems.Count -gt 0) {
            foreach ($problem in $problems) {
                [Console]::Error.WriteLine('Shared reference problem: {0}: {1}', $problem.Path, $problem.Detail)
            }
            [Console]::Error.WriteLine(
                'Copy the bytes of {0} to each listed copy, then rerun this check.',
                [string]$pathMappings[0].Source
            )
            return 1
        }
        return 0
    }
    finally {
        if ($null -ne $repositoryLease) { $repositoryLease.Dispose() }
    }
}

$exitCode = Invoke-SharedReferenceCheck
exit $exitCode
