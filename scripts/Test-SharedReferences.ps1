# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()][AllowEmptyString()][string] $GitExecutable = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$runtimeManifestRelativePath = 'scripts/platform-runtime.psd1'
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

function Get-SharedReferencePaths {
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($mapping in $pathMappings) {
        $paths.Add([string]$mapping.Source)
        foreach ($destination in $mapping.Destinations) {
            $paths.Add([string]$destination)
        }
    }
    return [string[]]$paths.ToArray()
}

function Get-GitExecutablePath {
    param([AllowEmptyString()][string] $RequestedPath)

    if (-not [string]::IsNullOrEmpty($RequestedPath)) {
        return Resolve-PlatformPhysicalPath -Path ([IO.Path]::GetFullPath($RequestedPath))
    }
    $commands = @(Get-Command -Name git -CommandType Application -ErrorAction Stop)
    if ($commands.Count -lt 1 -or [string]::IsNullOrWhiteSpace([string]$commands[0].Path)) {
        throw [IO.FileNotFoundException]::new('Git executable could not be resolved.')
    }
    return Resolve-PlatformPhysicalPath -Path ([IO.Path]::GetFullPath([string]$commands[0].Path))
}

function Get-GitChildEnvironment {
    $environment = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($name in @('SystemRoot', 'WINDIR', 'HOME', 'USERPROFILE')) {
        $value = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if (-not [string]::IsNullOrEmpty($value)) {
            $environment[$name] = $value
        }
    }
    $environment['GIT_OPTIONAL_LOCKS'] = '0'
    $environment['LC_ALL'] = 'C'
    return $environment
}

function Invoke-GitIndexQuery {
    param(
        [Parameter(Mandatory)][string] $GitExecutablePath,
        [Parameter(Mandatory)][string] $PhysicalRepositoryRoot,
        [Parameter(Mandatory)][string[]] $RelativePaths
    )

    $workingDirectoryLease = $null
    $processLease = $null
    $cleanupReceipt = $null
    $captureToken = [Guid]::NewGuid().ToString('N')
    $physicalTemporaryRoot = Resolve-PlatformPhysicalPath -Path ([IO.Path]::GetTempPath())
    $stdoutPath = [IO.Path]::Combine($physicalTemporaryRoot, 'shared-references-' + $captureToken + '.stdout')
    $stderrPath = [IO.Path]::Combine($physicalTemporaryRoot, 'shared-references-' + $captureToken + '.stderr')
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @('-C', $PhysicalRepositoryRoot, 'ls-files', '-s', '-z', '--')) {
        $arguments.Add($argument)
    }
    foreach ($relativePath in $RelativePaths) {
        $arguments.Add($relativePath)
    }

    try {
        $workingDirectoryLease = Open-PlatformDirectory -Root $PhysicalRepositoryRoot -RootOnly
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
        $processLease = Start-PlatformOwnedProcess -ExecutablePath $GitExecutablePath -ArgumentList $arguments.ToArray() -Environment (Get-GitChildEnvironment) -WorkingDirectoryLease $workingDirectoryLease -Deadline $deadline -IsolationRequirement cooperative -StdoutPath $stdoutPath -StderrPath $stderrPath -StandardInputBytes ([byte[]]@()) -CaptureProfile semantic-bridge
        while (-not $processLease.HasExited -and $null -eq $processLease.Cleanup) {
            [void]$processLease.WaitForExit([TimeSpan]::FromMilliseconds(25))
        }
        $cleanupReceipt = Stop-PlatformOwnedProcess -Lease $processLease -ExpectedStartIdentity $processLease.StartIdentity
        if (-not $cleanupReceipt.CleanedUp) {
            throw [IO.IOException]::new(('Git owned-process cleanup failed: {0}' -f [string]$cleanupReceipt.Uncertainty))
        }
        if ($processLease.OutputLimitExceeded) {
            throw [IO.InvalidDataException]::new(('Git output exceeded the bounded {0} quota.' -f [string]$processLease.OutputLimitStream))
        }
        if ($processLease.TerminationReason -notin @($null, '', 'cancelled')) {
            throw [IO.IOException]::new(('Git owned process ended because of {0}.' -f [string]$processLease.TerminationReason))
        }
        $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
        $stdout = $strictUtf8.GetString($processLease.ReadCapture('stdout', 4194304))
        $stderr = $strictUtf8.GetString($processLease.ReadCapture('stderr', 49152))
        if ($processLease.ExitCode -ne 0) {
            throw [IO.IOException]::new(('Git index query failed with exit code {0}: {1}' -f [int]$processLease.ExitCode, $stderr.Trim()))
        }
        return $stdout
    }
    finally {
        try {
            if ($null -ne $processLease) {
                try {
                    if ($null -eq $cleanupReceipt -or -not $cleanupReceipt.CleanedUp) {
                        $cleanupReceipt = Stop-PlatformOwnedProcess -Lease $processLease -ExpectedStartIdentity $processLease.StartIdentity
                        if (-not $cleanupReceipt.CleanedUp) {
                            throw [IO.IOException]::new(('Git owned-process cleanup remained incomplete: {0}' -f [string]$cleanupReceipt.Uncertainty))
                        }
                    }
                }
                finally {
                    $processLease.Dispose()
                }
            }
        }
        finally {
            try {
                if ($null -ne $workingDirectoryLease) {
                    $workingDirectoryLease.Dispose()
                }
            }
            finally {
                try {
                    [IO.File]::Delete($stdoutPath)
                }
                finally {
                    [IO.File]::Delete($stderrPath)
                }
            }
        }
    }
}

function ConvertFrom-GitIndexOutput {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Output,
        [Parameter(Mandatory)][string[]] $ExpectedPaths
    )

    $entries = [Collections.Generic.Dictionary[string, Collections.Generic.List[object]]]::new([StringComparer]::Ordinal)
    foreach ($path in $ExpectedPaths) {
        $entries.Add($path, [Collections.Generic.List[object]]::new())
    }
    foreach ($record in @($Output.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries))) {
        $match = [regex]::Match($record, '^(?<mode>[0-9]{6}) (?<blob>[0-9a-f]+) (?<stage>[0-3])\t(?<path>.+)$', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
        if (-not $match.Success) {
            throw [IO.InvalidDataException]::new('Git returned an invalid index record.')
        }
        $path = $match.Groups['path'].Value
        if (-not $entries.ContainsKey($path)) {
            throw [IO.InvalidDataException]::new(('Git returned an unexpected index path: {0}' -f $path))
        }
        $entries[$path].Add([pscustomobject]@{
            Mode = $match.Groups['mode'].Value
            Blob = $match.Groups['blob'].Value
            Stage = [int]$match.Groups['stage'].Value
        })
    }
    return $entries
}

function Get-SharedReferenceProblems {
    param(
        [Parameter(Mandatory)] $Entries,
        [Parameter(Mandatory)][string[]] $ExpectedPaths
    )

    $problems = [Collections.Generic.List[object]]::new()
    $validEntries = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($path in $ExpectedPaths) {
        $pathEntries = $Entries[$path]
        if ($pathEntries.Count -eq 0) {
            $problems.Add([pscustomobject]@{ Path = $path; Detail = 'not in index' })
            continue
        }
        if ($pathEntries.Count -ne 1 -or $pathEntries[0].Stage -ne 0) {
            $observed = @($pathEntries | ForEach-Object { 'mode={0} blob={1} stage={2}' -f $_.Mode, $_.Blob, $_.Stage }) -join '; '
            $problems.Add([pscustomobject]@{ Path = $path; Detail = 'expected exactly one stage 0 entry; actual ' + $observed })
            continue
        }
        $entry = $pathEntries[0]
        $validEntries.Add($path, $entry)
        if ($entry.Mode -cne '100644') {
            $problems.Add([pscustomobject]@{ Path = $path; Detail = ('mode={0} blob={1}' -f $entry.Mode, $entry.Blob) })
        }
    }

    $sourcePath = $ExpectedPaths[0]
    if ($validEntries.ContainsKey($sourcePath)) {
        $sourceBlob = [string]$validEntries[$sourcePath].Blob
        foreach ($path in $ExpectedPaths) {
            if (-not $validEntries.ContainsKey($path)) { continue }
            $entry = $validEntries[$path]
            if ([string]$entry.Blob -cne $sourceBlob) {
                $alreadyReported = @($problems | Where-Object { $_.Path -ceq $path }).Count -gt 0
                if (-not $alreadyReported) {
                    $problems.Add([pscustomobject]@{ Path = $path; Detail = ('mode={0} blob={1}' -f $entry.Mode, $entry.Blob) })
                }
            }
        }
    }
    return $problems
}

function Invoke-SharedReferenceCheck {
    param([AllowEmptyString()][string] $RequestedGitExecutable)

    $authorityReceipt = Assert-PlatformRuntimeAuthority
    $runtimeModule = Import-VerifiedPlatformRuntime -AuthorityReceipt $authorityReceipt
    if ($null -eq $runtimeModule) {
        throw [IO.InvalidDataException]::new('The verified platform runtime module receipt is missing.')
    }

    $physicalRepositoryRoot = Resolve-PlatformPhysicalPath -Path $repositoryRoot
    $gitExecutablePath = Get-GitExecutablePath -RequestedPath $RequestedGitExecutable
    $referencePaths = Get-SharedReferencePaths
    $output = Invoke-GitIndexQuery -GitExecutablePath $gitExecutablePath -PhysicalRepositoryRoot $physicalRepositoryRoot -RelativePaths $referencePaths
    $entries = ConvertFrom-GitIndexOutput -Output $output -ExpectedPaths $referencePaths
    $problems = @(Get-SharedReferenceProblems -Entries $entries -ExpectedPaths $referencePaths)
    if ($problems.Count -gt 0) {
        foreach ($problem in $problems) {
            [Console]::Error.WriteLine('Shared reference problem: {0}: {1}', $problem.Path, $problem.Detail)
        }
        [Console]::Error.WriteLine('Copy the bytes of {0} to each listed copy, stage them, then rerun this check.', [string]$pathMappings[0].Source)
        return 1
    }
    return 0
}

try {
    $exitCode = Invoke-SharedReferenceCheck -RequestedGitExecutable $GitExecutable
    exit $exitCode
}
catch {
    [Console]::Error.WriteLine('Shared reference check failed closed: {0}', $_.Exception.Message)
    exit 1
}
