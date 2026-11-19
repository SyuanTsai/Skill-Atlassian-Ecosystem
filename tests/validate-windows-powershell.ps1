# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param([string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($RepositoryRoot)
$scriptNames = @(
    'Invoke-PinnedAuthority.ps1'
    'Sync-SharedReferences.ps1'
    'Test-AtlassianRepository.ps1'
    'Test-AtlassianSharedReferences.ps1'
)
$testNames = @(
    'AtomicOutput.Tests.ps1'
    'CanonicalValidation.Tests.ps1'
    'CentralRunner.Tests.ps1'
    'CorePesterIntegrity.Tests.ps1'
    'ProtectedRunner.Tests.ps1'
    'RepositoryValidation.Tests.ps1'
    'ShardedPesterQueue.Tests.ps1'
    'SharedReferences.Tests.ps1'
    'SkillSpectorExceptions.Tests.ps1'
    'SourcePackageBridge.Tests.ps1'
    'SourceStaticBridge.Tests.ps1'
    'SourceValidationPreparation.Tests.ps1'
    'StandardV1Conformance.Tests.ps1'
    'Test-Repository.Tests.ps1'
    'validate-repository-standalone.ps1'
    'validate-repository.ps1'
    'validate-windows-powershell.ps1'
)
$scriptRoot = Join-Path $root 'scripts'
$testRoot = Join-Path $root 'tests'
$files = @($scriptNames | ForEach-Object { Get-Item -LiteralPath (Join-Path $scriptRoot $_) -Force })
$files += @($testNames | ForEach-Object { Get-Item -LiteralPath (Join-Path $testRoot $_) -Force })
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) { throw "PowerShell syntax validation failed: $($file.FullName)" }
}
Write-Host "PowerShell syntax validation passed for $($files.Count) conversion files."
