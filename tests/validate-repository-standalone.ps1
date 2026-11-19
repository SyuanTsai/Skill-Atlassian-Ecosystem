# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param([string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($RepositoryRoot)
$check = Join-Path $root 'scripts/Test-AtlassianRepository.ps1'
$before = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | ForEach-Object { [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/') } | Sort-Object -CaseSensitive)
$result = (@(& $check -RepositoryRoot $root -ReadOnlySnapshot) -join "`n") | ConvertFrom-Json
if ([string]$result.result -cne 'passed') { throw 'Standalone repository check did not pass.' }
$after = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | ForEach-Object { [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/') } | Sort-Object -CaseSensitive)
if (($before -join "`n") -cne ($after -join "`n")) { throw 'Standalone repository check changed the candidate snapshot.' }
Write-Host 'Standalone snapshot validation passed.'
