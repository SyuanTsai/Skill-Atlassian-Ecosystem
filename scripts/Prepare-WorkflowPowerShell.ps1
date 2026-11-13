# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Resolve', 'Install', 'Verify')][string] $Mode,
    [Parameter(Mandatory)][ValidateSet('windows', 'linux', 'macos')][string] $Platform,
    [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string] $ExpectedArchitecture,
    [Parameter(Mandatory)][string] $ExecutableName,
    [string] $AssetTemplate,
    [string] $RuntimeRoot,
    [string] $OwnedRoot,
    [string] $ArtifactsRoot,
    [string] $CacheRoot,
    [string] $Version,
    [string] $ReleaseTag,
    [string] $AssetName,
    [string] $ArchiveUrl,
    [string] $HashesUrl,
    [string] $OfficialArchiveSha256,
    [string] $HashesManifestSha256,
    [string] $FreshHashesPath,
    [switch] $DefineFunctionsOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-WorkflowArchitecture {
    $actual = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    if ($actual -cne $ExpectedArchitecture) {
        throw "Expected $ExpectedArchitecture runner architecture, got $actual."
    }
}

function Resolve-WorkflowPhysicalPath {
    param([Parameter(Mandatory)][string] $Path)
    if ($IsWindows) { return [IO.Path]::GetFullPath($Path) }
    $resolved = @(& realpath $Path)
    if ($LASTEXITCODE -ne 0 -or $resolved.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$resolved[0])) {
        throw "Could not resolve physical path: $Path"
    }
    return ([string]$resolved[0]).Trim()
}

function Assert-RequiredValue {
    param([AllowNull()][AllowEmptyString()][string] $Value, [Parameter(Mandatory)][string] $Name)
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Name is required for workflow PowerShell $Mode mode." }
}

function Get-OfficialManifestArchiveSha256 {
    param([Parameter(Mandatory)][string] $ManifestPath, [Parameter(Mandatory)][string] $ArchiveName)
    $pattern = '^(?<hash>[0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($ArchiveName) + '\s*$'
    $digests = @(foreach ($line in [IO.File]::ReadAllLines($ManifestPath)) {
        if ($line -match $pattern) { $Matches.hash.ToLowerInvariant() }
    })
    if ($digests.Count -ne 1) { throw "Official PowerShell hash manifest must contain one exact $ArchiveName digest." }
    return [string]$digests[0]
}

function Select-WorkflowPowerShellReleaseAsset {
    param([Parameter(Mandatory)][object] $Release, [Parameter(Mandatory)][string] $AssetTemplate)
    $tag = [string]$Release.tag_name
    if ($Release.draft -or $Release.prerelease -or $tag -cnotmatch '^v(?<version>[0-9]+\.[0-9]+\.[0-9]+)$') {
        throw 'PowerShell latest release is not a stable semantic-version release.'
    }
    $resolvedVersion = [string]$Matches.version
    $resolvedAssetName = $AssetTemplate -f $resolvedVersion
    $archiveAssets = @($Release.assets | Where-Object { [string]$_.name -ceq $resolvedAssetName })
    $hashAssets = @($Release.assets | Where-Object { [string]$_.name -ceq 'hashes.sha256' })
    if ($archiveAssets.Count -ne 1 -or $hashAssets.Count -ne 1) {
        throw 'Latest official PowerShell release is missing the exact platform archive or hashes.sha256.'
    }
    $releasePrefix = 'https://github.com/PowerShell/PowerShell/releases/download/{0}/' -f $tag
    foreach ($asset in @($archiveAssets[0], $hashAssets[0])) {
        $uri = [Uri][string]$asset.browser_download_url
        if ($uri.Scheme -cne 'https' -or $uri.Host -cne 'github.com' -or
            -not $uri.AbsoluteUri.StartsWith($releasePrefix, [StringComparison]::Ordinal) -or
            [string]$asset.digest -cnotmatch '^sha256:(?<hash>[0-9a-fA-F]{64})$') {
            throw ("PowerShell release asset '{0}' lacks an official immutable URL or SHA-256 digest." -f [string]$asset.name)
        }
    }
    return [pscustomobject]@{
        Version = $resolvedVersion
        Tag = $tag
        AssetName = $resolvedAssetName
        ArchiveUrl = [string]$archiveAssets[0].browser_download_url
        HashesUrl = [string]$hashAssets[0].browser_download_url
        ArchiveApiSha256 = ([string]$archiveAssets[0].digest).Substring(7).ToLowerInvariant()
        ManifestApiSha256 = ([string]$hashAssets[0].digest).Substring(7).ToLowerInvariant()
    }
}

function Assert-WorkflowPowerShellManifestDigest {
    param(
        [Parameter(Mandatory)][string] $ManifestPath,
        [Parameter(Mandatory)][string] $ArchiveName,
        [Parameter(Mandatory)][string] $ManifestApiSha256,
        [Parameter(Mandatory)][string] $ArchiveApiSha256
    )
    if ((Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ManifestApiSha256) {
        throw 'PowerShell hashes.sha256 bytes differ from the official release asset digest.'
    }
    if ((Get-OfficialManifestArchiveSha256 -ManifestPath $ManifestPath -ArchiveName $ArchiveName) -cne $ArchiveApiSha256) {
        throw 'PowerShell archive API digest differs from hashes.sha256.'
    }
}

function Test-WorkflowPowerShellCacheEntry {
    param(
        [Parameter(Mandatory)][string] $ArchivePath,
        [Parameter(Mandatory)][string] $ManifestPath,
        [Parameter(Mandatory)][string] $ArchiveName,
        [Parameter(Mandatory)][string] $OfficialArchiveSha256,
        [Parameter(Mandatory)][string] $HashesManifestSha256
    )
    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf) -or -not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        return $false
    }
    try {
        if ((Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $OfficialArchiveSha256) { throw 'cached archive hash mismatch' }
        if ((Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $HashesManifestSha256) { throw 'cached manifest hash mismatch' }
        if ((Get-OfficialManifestArchiveSha256 -ManifestPath $ManifestPath -ArchiveName $ArchiveName) -cne $OfficialArchiveSha256) { throw 'cached manifest entry mismatch' }
        return $true
    }
    catch {
        Remove-Item -LiteralPath $ArchivePath, $ManifestPath -Force -ErrorAction SilentlyContinue
        Write-Warning ('Discarded invalid PowerShell cache entry: {0}' -f $_.Exception.Message)
        return $false
    }
}

function Assert-WorkflowRuntimeRootEmpty {
    param([Parameter(Mandatory)][string] $Path)
    if (@(Get-ChildItem -LiteralPath $Path -Force).Count -ne 0) {
        throw 'Verified PowerShell runtime root must be fresh and empty.'
    }
}

if ($DefineFunctionsOnly) { return }

Assert-WorkflowArchitecture

switch ($Mode) {
    'Resolve' {
        Assert-RequiredValue -Value $AssetTemplate -Name 'AssetTemplate'
        Assert-RequiredValue -Value $env:GITHUB_OUTPUT -Name 'GITHUB_OUTPUT'
        $releaseUri = [Uri]'https://api.github.com/repos/PowerShell/PowerShell/releases/latest'
        $metadataHeaders = @{
            Accept = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
            'User-Agent' = 'Skill-Atlassian-Ecosystem-Source-Validation'
        }
        if (-not [string]::IsNullOrWhiteSpace($env:SOURCE_GITHUB_API_TOKEN) -and $releaseUri.Host -ceq 'api.github.com') {
            $metadataHeaders.Authorization = 'Bearer {0}' -f $env:SOURCE_GITHUB_API_TOKEN
        }
        $metadataResponse = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                # Do not use -PreserveAuthorizationOnRedirect: PowerShell drops Authorization on redirects by default.
                $metadataResponse = Invoke-WebRequest -Uri $releaseUri -Headers $metadataHeaders -TimeoutSec 60 -ErrorAction Stop
                break
            }
            catch {
                $responseProperty = $_.Exception.PSObject.Properties['Response']
                $statusCode = if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) { [int]$responseProperty.Value.StatusCode } else { 0 }
                if ($attempt -eq 3 -or -not ($statusCode -eq 403 -or $statusCode -eq 429 -or $statusCode -ge 500)) { throw }
                Start-Sleep -Seconds 10
            }
        }
        if ($null -eq $metadataResponse) { throw 'PowerShell release metadata request did not return a response.' }
        $finalUri = [Uri]$metadataResponse.BaseResponse.RequestMessage.RequestUri
        if ($finalUri.Host -cne 'api.github.com') {
            throw ('PowerShell release metadata request redirected to an unexpected host: {0}' -f $finalUri.Host)
        }
        $release = $metadataResponse.Content | ConvertFrom-Json
        $selection = Select-WorkflowPowerShellReleaseAsset -Release $release -AssetTemplate $AssetTemplate
        $metadataRoot = Join-Path ([IO.Path]::GetTempPath()) ('source-pwsh-metadata-{0}-{1}' -f $Platform, [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $metadataRoot -ErrorAction Stop)
        $manifestPath = Join-Path $metadataRoot 'hashes.sha256'
        Invoke-WebRequest -Uri $selection.HashesUrl -OutFile $manifestPath -MaximumRedirection 3 -TimeoutSec 60 -ErrorAction Stop
        Assert-WorkflowPowerShellManifestDigest -ManifestPath $manifestPath -ArchiveName $selection.AssetName `
            -ManifestApiSha256 $selection.ManifestApiSha256 -ArchiveApiSha256 $selection.ArchiveApiSha256
        $outputs = @(
            ('version={0}' -f $selection.Version), ('tag={0}' -f $selection.Tag), ('asset={0}' -f $selection.AssetName),
            ('archive_url={0}' -f $selection.ArchiveUrl),
            ('hashes_url={0}' -f $selection.HashesUrl),
            ('official_sha256={0}' -f $selection.ArchiveApiSha256), ('hashes_sha256={0}' -f $selection.ManifestApiSha256),
            ('fresh_hashes_path={0}' -f $manifestPath)
        )
        [IO.File]::AppendAllText($env:GITHUB_OUTPUT, ($outputs -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
        break
    }
    'Install' {
        foreach ($required in @{
            RuntimeRoot = $RuntimeRoot; OwnedRoot = $OwnedRoot; ArtifactsRoot = $ArtifactsRoot; CacheRoot = $CacheRoot
            Version = $Version; ReleaseTag = $ReleaseTag; AssetName = $AssetName; ArchiveUrl = $ArchiveUrl
            HashesUrl = $HashesUrl; OfficialArchiveSha256 = $OfficialArchiveSha256
            HashesManifestSha256 = $HashesManifestSha256; FreshHashesPath = $FreshHashesPath
            GITHUB_ENV = $env:GITHUB_ENV; GITHUB_PATH = $env:GITHUB_PATH
        }.GetEnumerator()) { Assert-RequiredValue -Value ([string]$required.Value) -Name ([string]$required.Key) }
        foreach ($sha in @($OfficialArchiveSha256, $HashesManifestSha256)) {
            if ($sha -cnotmatch '^[0-9a-f]{64}$') { throw 'Official PowerShell SHA-256 inputs must be lowercase hex.' }
        }
        [void](New-Item -ItemType Directory -Path $CacheRoot -Force -ErrorAction Stop)
        $archivePath = Join-Path $CacheRoot $AssetName
        $cachedManifestPath = Join-Path $CacheRoot 'hashes.sha256'
        $cacheValid = Test-WorkflowPowerShellCacheEntry -ArchivePath $archivePath -ManifestPath $cachedManifestPath -ArchiveName $AssetName `
            -OfficialArchiveSha256 $OfficialArchiveSha256 -HashesManifestSha256 $HashesManifestSha256
        if (-not $cacheValid) {
            Invoke-WebRequest -Uri $ArchiveUrl -OutFile $archivePath -MaximumRedirection 3 -TimeoutSec 300 -ErrorAction Stop
            [IO.File]::Copy($FreshHashesPath, $cachedManifestPath, $true)
        }
        if ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $OfficialArchiveSha256 -or
            (Get-FileHash -LiteralPath $cachedManifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $HashesManifestSha256 -or
            (Get-OfficialManifestArchiveSha256 -ManifestPath $cachedManifestPath -ArchiveName $AssetName) -cne $OfficialArchiveSha256) {
            throw 'PowerShell release bytes failed mandatory post-cache verification.'
        }
        Assert-WorkflowRuntimeRootEmpty -Path $RuntimeRoot
        if ($IsWindows) { Expand-Archive -LiteralPath $archivePath -DestinationPath $RuntimeRoot -ErrorAction Stop }
        else {
            & tar -xzf $archivePath -C $RuntimeRoot
            if ($LASTEXITCODE -ne 0) { throw 'PowerShell tar archive extraction failed.' }
            & chmod +x (Join-Path $RuntimeRoot $ExecutableName)
            if ($LASTEXITCODE -ne 0) { throw 'Could not mark the PowerShell executable as executable.' }
        }
        $executable = Join-Path $RuntimeRoot $ExecutableName
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'Official archive did not contain the expected PowerShell executable.' }
        $signatureStatus = $null; $signerSubject = $null; $signerThumbprint = $null
        if ($IsWindows) {
            $signature = Get-AuthenticodeSignature -LiteralPath $executable
            if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or $null -eq $signature.SignerCertificate -or
                $signature.SignerCertificate.Subject -notmatch 'CN=Microsoft Corporation') {
                throw 'PowerShell executable Authenticode signature is not valid and Microsoft-signed.'
            }
            $signatureStatus = [string]$signature.Status
            $signerSubject = [string]$signature.SignerCertificate.Subject
            $signerThumbprint = [string]$signature.SignerCertificate.Thumbprint
        }
        $versionOutput = @(& $executable -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()')
        if ($LASTEXITCODE -ne 0 -or $versionOutput.Count -ne 1 -or ([string]$versionOutput[0]).Trim() -cne $Version) {
            throw 'Installed PowerShell version differs from the latest stable release tag.'
        }
        $executableFullPath = [IO.Path]::GetFullPath($executable)
        $receipt = [ordered]@{
            schemaVersion = 1; report = 'verified-latest-official-powershell-runtime-v1'
            sourceRepository = 'https://github.com/PowerShell/PowerShell'; releaseApi = 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest'
            releaseTag = $ReleaseTag; version = $Version; platform = $Platform; architecture = $ExpectedArchitecture
            archiveUri = $ArchiveUrl; hashesManifestUri = $HashesUrl; officialArchiveSha256 = $OfficialArchiveSha256
            observedArchiveSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
            executablePath = $executableFullPath; executableAuthenticodeStatus = $signatureStatus
            executableSignerSubject = $signerSubject; executableSignerThumbprint = $signerThumbprint; cacheRestoredAndValid = $cacheValid
        }
        $receiptPath = Join-Path $OwnedRoot 'powershell-runtime-setup.json'
        [IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
        [IO.File]::Copy($receiptPath, (Join-Path $ArtifactsRoot 'powershell-runtime-setup.json'), $false)
        [IO.File]::Copy($cachedManifestPath, (Join-Path $ArtifactsRoot 'powershell-release-hashes.sha256'), $false)
        $environmentLines = @(
            ('SOURCE_POWERSHELL_EXECUTABLE={0}' -f $executableFullPath),
            ('SOURCE_POWERSHELL_VERSION={0}' -f $Version),
            ('SOURCE_POWERSHELL_ARCHIVE_SHA256={0}' -f $OfficialArchiveSha256)
        )
        [IO.File]::AppendAllText($env:GITHUB_ENV, ($environmentLines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::AppendAllText($env:GITHUB_PATH, $RuntimeRoot + "`n", [Text.UTF8Encoding]::new($false))
        break
    }
    'Verify' {
        Assert-RequiredValue -Value $env:SOURCE_POWERSHELL_EXECUTABLE -Name 'SOURCE_POWERSHELL_EXECUTABLE'
        Assert-RequiredValue -Value $env:SOURCE_POWERSHELL_VERSION -Name 'SOURCE_POWERSHELL_VERSION'
        if ([string]$env:SOURCE_POWERSHELL_ARCHIVE_SHA256 -cnotmatch '^[0-9a-f]{64}$') { throw 'SOURCE_POWERSHELL_ARCHIVE_SHA256 is invalid.' }
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        $expected = Resolve-WorkflowPhysicalPath $env:SOURCE_POWERSHELL_EXECUTABLE
        $process = Resolve-WorkflowPhysicalPath ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        $selected = Resolve-WorkflowPhysicalPath ((Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
        $pshomeExecutable = Resolve-WorkflowPhysicalPath (Join-Path $PSHOME $ExecutableName)
        if (-not $process.Equals($expected, $comparison) -or -not $selected.Equals($expected, $comparison) -or -not $pshomeExecutable.Equals($expected, $comparison)) {
            throw ('The GitHub step shell is not the verified PowerShell: expected={0} process={1} selected={2} pshome={3}' -f $expected, $process, $selected, $pshomeExecutable)
        }
        if ($PSVersionTable.PSVersion.ToString() -cne $env:SOURCE_POWERSHELL_VERSION) { throw 'Selected PowerShell version differs from its release receipt.' }
        break
    }
}
