# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param([string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($RepositoryRoot)
$checks = @(
    'scripts/Test-AtlassianRepository.ps1'
    'scripts/Test-AtlassianSharedReferences.ps1'
)
foreach ($relative in $checks) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Repository check is missing: $relative" }
    $output = @(& $path -RepositoryRoot $root -ReadOnlySnapshot) -join "`n"
    $result = $output | ConvertFrom-Json
    if ([string]$result.result -cne 'passed') { throw "Repository check did not report passed: $relative" }
}
Write-Host 'Atlassian consumer repository checks passed.'
