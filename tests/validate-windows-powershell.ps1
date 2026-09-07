# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param(
    [string] $RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Contract {
    param(
        [Parameter(Mandatory = $true)][bool] $Condition,
        [Parameter(Mandatory = $true)][string] $Message
    )

    if (-not $Condition) { throw $Message }
}

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}
$repositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$sourcePath = Join-Path $repositoryRoot 'catalog/source.json'
$workflowPath = Join-Path $repositoryRoot '.github/workflows/standard-v1-protected.yml'
Assert-Contract -Condition (Test-Path -LiteralPath $sourcePath -PathType Leaf) -Message "Source inventory is missing: $sourcePath"
Assert-Contract -Condition (Test-Path -LiteralPath $workflowPath -PathType Leaf) -Message "Protected workflow is missing: $workflowPath"

# This compatibility contract intentionally only parses candidate data. It never
# dot-sources or executes a candidate script under Windows PowerShell 5.1.
$source = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8 | ConvertFrom-Json
$sourceProperties = @($source.PSObject.Properties.Name)
$allowedV1Properties = @('schemaVersion', 'license', 'sourceId', 'repository', 'skillsRoot', 'skills')
$allowedV2Properties = @('schemaVersion', 'sourceId', 'repository', 'skillsRoot', 'skills')
if ($source.schemaVersion -eq 1) {
    Assert-Contract -Condition ($sourceProperties.Count -eq $allowedV1Properties.Count -and
        (@($sourceProperties | Where-Object { $allowedV1Properties -notcontains $_ }).Count -eq 0) -and
        (@($allowedV1Properties | Where-Object { $sourceProperties -notcontains $_ }).Count -eq 0)) `
        -Message 'Schema v1 source inventory has an unexpected property set.'
}
elseif ($source.schemaVersion -eq 2) {
    Assert-Contract -Condition ($sourceProperties.Count -eq $allowedV2Properties.Count -and
        (@($sourceProperties | Where-Object { $allowedV2Properties -notcontains $_ }).Count -eq 0) -and
        (@($allowedV2Properties | Where-Object { $sourceProperties -notcontains $_ }).Count -eq 0)) `
        -Message 'Schema v2 source inventory has an unexpected property set.'
}
else {
    throw "Unsupported source inventory schema version: $($source.schemaVersion)"
}

Assert-Contract -Condition ($source.sourceId -is [string] -and [string]$source.sourceId -ceq 'atlassian-ecosystem') `
    -Message 'Source inventory sourceId is not the approved Atlassian Ecosystem identity.'
Assert-Contract -Condition ($source.repository -is [string] -and [string]$source.repository -ceq 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git') `
    -Message 'Source inventory repository is not the approved repository.'
Assert-Contract -Condition ($source.skillsRoot -is [string] -and [string]$source.skillsRoot -ceq 'skills') `
    -Message 'Source inventory skillsRoot must be the canonical skills directory.'
Assert-Contract -Condition ($null -ne $source.skills -and @($source.skills).Count -gt 0) `
    -Message 'Source inventory must expose a non-empty Skill list.'
foreach ($skillId in @($source.skills)) {
    Assert-Contract -Condition ($skillId -is [string] -and [string]$skillId -match '^[a-z0-9]+(?:-[a-z0-9]+)*$') `
        -Message 'Source inventory contains an invalid Skill identifier.'
}

$workflow = Get-Content -LiteralPath $workflowPath -Raw -Encoding UTF8
Assert-Contract -Condition ($workflow -match '(?m)^\s*shell:\s*powershell') `
    -Message 'Protected workflow must retain a Windows PowerShell 5.1 compatibility job.'
Assert-Contract -Condition ($workflow -match 'go-version:' -and $workflow -match 'stable') `
    -Message 'Protected workflow must resolve the latest stable Go runtime.'
Assert-Contract -Condition ($workflow -match '(?m)check-latest:\s*true') `
    -Message 'Protected workflow must request the latest stable Go runtime.'
Assert-Contract -Condition ($workflow -notmatch '(?m)go-version:\s*[''\"]?[0-9]+\.[0-9]+\.[0-9]+') `
    -Message 'Protected workflow must not pin Go to a patch version.'

Write-Host 'Windows PowerShell compatibility contract passed.'
