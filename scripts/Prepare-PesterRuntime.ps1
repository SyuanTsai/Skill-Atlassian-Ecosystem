# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RuntimeExecutable,
    [Parameter(Mandatory)][string] $OwnedRoot,
    [string] $ClosureLockPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$helperPath = Join-Path $PSScriptRoot 'CorePesterIntegrity.psm1'
Import-Module -Name $helperPath -Force -ErrorAction Stop
$expectedLockSha256 = '72df3af4707809f5e0974e77a4d8ea575033baa1fbea0d92fc7ef9bdbc545b52'
$lockPath = if ([string]::IsNullOrWhiteSpace($ClosureLockPath)) {
    [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../config/pester-6.2.0-closure.lock.json'))
}
else {
    [IO.Path]::GetFullPath($ClosureLockPath)
}
$lockRecord = Read-CorePesterClosureLock -LiteralPath $lockPath
if ($lockRecord.Sha256 -cne $expectedLockSha256) { throw 'Pester closure lock bytes differ from the protected tracked source lock.' }
$runtimeExecutable = [IO.Path]::GetFullPath($RuntimeExecutable)
$actualExecutable = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$ownedRoot = [IO.Path]::GetFullPath($OwnedRoot)
$ownedBoundary = Test-CorePesterPathBoundary -Path $ownedRoot -Boundary $ownedRoot
if (-not $ownedBoundary.IsValid) { throw ('Pester setup evidence root is unsafe: ' + (@($ownedBoundary.Errors) -join '; ')) }
$registeredOwnedRoot = [Environment]::GetEnvironmentVariable('STANDARD_VALIDATION_RUN_OWNED_ROOT', 'Process')
$workflowRegisteredOwnedRoot = [Environment]::GetEnvironmentVariable('RUN_OWNED_ROOT', 'Process')
if (-not [string]::IsNullOrWhiteSpace($registeredOwnedRoot) -and
    -not [string]::IsNullOrWhiteSpace($workflowRegisteredOwnedRoot) -and
    -not ([IO.Path]::GetFullPath($registeredOwnedRoot)).Equals([IO.Path]::GetFullPath($workflowRegisteredOwnedRoot), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Namespaced and workflow Pester setup root registrations disagree.'
}
if ([string]::IsNullOrWhiteSpace($registeredOwnedRoot)) { $registeredOwnedRoot = $workflowRegisteredOwnedRoot }
if ([string]::IsNullOrWhiteSpace($registeredOwnedRoot) -or
    -not ([IO.Path]::GetFullPath($registeredOwnedRoot)).Equals($ownedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Pester setup root does not match the workflow-registered run-owned root.'
}
$runtimeIdentity = Assert-CorePesterOwnedRuntime -RuntimeExecutable $runtimeExecutable `
    -OwnedRoot $ownedRoot -CurrentExecutable $actualExecutable
$runtimeModuleRoot = [string]$runtimeIdentity.ModuleRoot
$setupRoot = Join-Path $ownedRoot 'pester-setup'
$setupBoundary = Test-CorePesterPathBoundary -Path $setupRoot -Boundary $ownedRoot
if (-not $setupBoundary.IsValid) { throw ('Pester setup evidence path is unsafe: ' + (@($setupBoundary.Errors) -join '; ')) }
if (Test-Path -LiteralPath $setupRoot) { throw 'Pester setup evidence directory already exists.' }
[void](New-Item -ItemType Directory -Path $setupRoot -ErrorAction Stop)
$setupBoundary = Test-CorePesterPathBoundary -Path $setupRoot -Boundary $ownedRoot
if (-not $setupBoundary.IsValid) { throw ('Pester setup evidence path became unsafe: ' + (@($setupBoundary.Errors) -join '; ')) }
$archivePath = Join-Path $setupRoot 'Pester.6.2.0.nupkg'
$stageRoot = Join-Path $setupRoot 'staging'
$maximumPackageBytes = 33554432L
$destinationCreated = $false
$destinationModuleRoot = $runtimeModuleRoot
$cleanupFailed = $false
$successMessage = $null

try {
    $sourceUri = [string]$lockRecord.Value.source.packageUri
    if ($sourceUri -cne 'https://www.powershellgallery.com/api/v2/package/Pester/6.2.0') {
        throw 'Pester setup source URI differs from the pinned official PSGallery endpoint.'
    }
    $downloadResult = Receive-CorePesterBoundedPackage -Uri ([uri]$sourceUri) -DestinationPath $archivePath `
        -MaximumBytes $maximumPackageBytes -TimeoutSeconds 180 -MaximumRedirections 3
    if ([long]$downloadResult.byteCount -le 0 -or [long]$downloadResult.byteCount -gt $maximumPackageBytes -or
        [string]$downloadResult.sourceUri -cne $sourceUri -or [string]::IsNullOrWhiteSpace([string]$downloadResult.finalUri)) {
        throw 'PSGallery package acquisition returned incomplete or out-of-bound transfer evidence.'
    }
    $observedFinalPackageUri = [string]$downloadResult.finalUri
    $package = Test-CorePesterPackageArchive -ArchivePath $archivePath -Lock $lockRecord.Value
    if (-not $package.IsValid) { throw ('Official Pester package does not match the complete reviewed lock: ' + (@($package.Errors) -join '; ')) }

    if (Test-Path -LiteralPath $destinationModuleRoot) { throw 'The verified PowerShell runtime already contains a Pester destination; setup refuses overwrite.' }
    $runtimeRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $destinationModuleRoot))
    $destinationBoundary = Test-CorePesterPathBoundary -Path $destinationModuleRoot -Boundary $runtimeRoot
    if (-not $destinationBoundary.IsValid) {
        throw ('Pester destination is outside the verified runtime or has a reparse-point ancestor: ' + (@($destinationBoundary.Errors) -join '; '))
    }

    $stageBoundary = Test-CorePesterPathBoundary -Path $stageRoot -Boundary $setupRoot
    if (-not $stageBoundary.IsValid) { throw ('Pester staging path is unsafe: ' + (@($stageBoundary.Errors) -join '; ')) }
    [void](New-Item -ItemType Directory -Path $stageRoot -ErrorAction Stop)
    $stageBoundary = Test-CorePesterPathBoundary -Path $stageRoot -Boundary $setupRoot
    if (-not $stageBoundary.IsValid) { throw ('Pester staging path became unsafe: ' + (@($stageBoundary.Errors) -join '; ')) }
    $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        foreach ($payload in $lockRecord.Value.modulePayload) {
            $relative = [string]$payload.path
            $archiveEntry = @($archive.Entries | Where-Object { [string]$_.FullName -ceq $relative })
            if ($archiveEntry.Count -ne 1) { throw "Verified package payload does not have one exact entry: $relative" }
            $targetPath = [IO.Path]::GetFullPath((Join-Path $stageRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))))
            $stagePrefix = $stageRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            if (-not $targetPath.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Package path escaped owned staging: $relative" }
            $targetDirectory = Split-Path -Parent $targetPath
            [void](New-Item -ItemType Directory -Path $targetDirectory -Force -ErrorAction Stop)
            $inputStream = $archiveEntry[0].Open()
            $outputStream = [IO.FileStream]::new($targetPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $inputStream.CopyTo($outputStream); $outputStream.Flush($true) }
            finally { $inputStream.Dispose(); $outputStream.Dispose() }
        }
    }
    finally { $archive.Dispose() }

    $stagedClosure = Test-CorePesterClosure -ModuleRoot $stageRoot -Lock $lockRecord.Value
    if (-not $stagedClosure.IsValid) { throw ('Staged Pester package closure failed: ' + (@($stagedClosure.Errors) -join '; ')) }
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $destinationModuleRoot) -Force -ErrorAction Stop)
    [void](New-Item -ItemType Directory -Path $destinationModuleRoot -ErrorAction Stop)
    $destinationCreated = $true
    foreach ($payload in $lockRecord.Value.modulePayload) {
        $relative = [string]$payload.path
        $sourcePath = Join-Path $stageRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $targetPath = Join-Path $destinationModuleRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $targetPath) -Force -ErrorAction Stop)
        [IO.File]::Copy($sourcePath, $targetPath, $false)
    }
    $runtimeClosure = Test-CorePesterClosure -ModuleRoot $destinationModuleRoot -Lock $lockRecord.Value
    if (-not $runtimeClosure.IsValid) { throw ('Installed PowerShell runtime closure failed: ' + (@($runtimeClosure.Errors) -join '; ')) }

    $archiveSha = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    $receipt = [ordered]@{
        schemaVersion = 1
        report = 'verified-pester-runtime-setup-v1'
        sourceUri = $sourceUri
        observedFinalPackageUri = $observedFinalPackageUri
        finalPackageUriObserved = ($null -ne $observedFinalPackageUri)
        sourceName = [string]$lockRecord.Value.source.sourceName
        version = [string]$lockRecord.Value.source.version
        officialArchiveDigestClaimed = $false
        observedArchiveSha256 = $archiveSha
        archiveEntryCount = $package.EntryCount
        modulePayloadCount = $package.PayloadCount
        installerMetadata = [ordered]@{ path = 'PSGetModuleInfo.xml'; observedInOfficialPackage = $false; copied = $false }
        lockPath = $lockRecord.Path
        lockSha256 = $lockRecord.Sha256
        runtimeExecutable = $runtimeExecutable
        runtimeModuleRoot = $destinationModuleRoot
        closureSha256 = $runtimeClosure.ClosureSha256
        payload = @($runtimeClosure.Inventory)
        terminalStatus = 'verified'
    }
    $receiptPath = Join-Path $setupRoot 'setup-receipt.json'
    $receiptBytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $receipt -Depth 6 -Compress) + "`n")
    $receiptStream = [IO.FileStream]::new($receiptPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $receiptStream.Write($receiptBytes, 0, $receiptBytes.Length); $receiptStream.Flush($true) }
    finally { $receiptStream.Dispose() }
    $receiptHash = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    [Console]::Error.WriteLine("Verified Pester setup: path=`"$receiptPath`" sha256=$receiptHash archiveSha256=$archiveSha payloads=$($package.PayloadCount) closureSha256=$($runtimeClosure.ClosureSha256)")
    $successMessage = "Pester 6.2.0 exact closure installed under verified PowerShell runtime; receipt SHA256 $receiptHash"
}
catch {
    [Console]::Error.WriteLine("Pester runtime setup failed: $($_.Exception.Message)")
    if ($destinationCreated) {
        try {
            $runtimeRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $destinationModuleRoot))
            $destinationBoundary = Test-CorePesterPathBoundary -Path $destinationModuleRoot -Boundary $runtimeRoot
            if (-not $destinationBoundary.IsValid) { throw ('Refusing unsafe recursive runtime cleanup: ' + (@($destinationBoundary.Errors) -join '; ')) }
            if (Test-Path -LiteralPath $destinationModuleRoot -PathType Container) {
                Remove-Item -LiteralPath $destinationModuleRoot -Recurse -Force -ErrorAction Stop
            }
            if (Test-Path -LiteralPath $destinationModuleRoot) { throw 'Owned runtime destination cleanup did not remove the Pester directory.' }
        }
        catch {
            $cleanupFailed = $true
            [Console]::Error.WriteLine("Pester runtime cleanup failed closed: $($_.Exception.Message)")
        }
    }
    exit 1
}
finally {
    try {
        $stageBoundary = Test-CorePesterPathBoundary -Path $stageRoot -Boundary $setupRoot
        if (-not $stageBoundary.IsValid) { throw ('Refusing unsafe recursive staging cleanup: ' + (@($stageBoundary.Errors) -join '; ')) }
        if (Test-Path -LiteralPath $stageRoot -PathType Container) {
            Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $stageRoot) { throw 'Owned staging cleanup did not remove the staging directory.' }
    }
    catch {
        $cleanupFailed = $true
        [Console]::Error.WriteLine("Pester staging cleanup failed closed: $($_.Exception.Message)")
    }
}
if ($cleanupFailed) { exit 1 }
if ($null -ne $successMessage) { Write-Output $successMessage }
