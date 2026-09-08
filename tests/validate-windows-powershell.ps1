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
if (($source.schemaVersion -is [int] -or $source.schemaVersion -is [long]) -and [int64]$source.schemaVersion -eq 1) {
    Assert-Contract -Condition ($sourceProperties.Count -eq $allowedV1Properties.Count -and
        (@($sourceProperties | Where-Object { $allowedV1Properties -notcontains $_ }).Count -eq 0) -and
        (@($allowedV1Properties | Where-Object { $sourceProperties -notcontains $_ }).Count -eq 0)) `
        -Message 'Schema v1 source inventory has an unexpected property set.'
}
elseif (($source.schemaVersion -is [int] -or $source.schemaVersion -is [long]) -and [int64]$source.schemaVersion -eq 2) {
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
Assert-Contract -Condition ($workflow -match 'Assert-NoDuplicateJsonProperties' -and
    $workflow -match 'TryGetInt64') `
    -Message 'Protected workflow must reject duplicate or non-integer bootstrap schema values.'
Assert-Contract -Condition ($workflow -match 'Parse candidate PowerShell trust-anchor files' -and
    $workflow -match 'ls-files -z') `
    -Message 'Protected workflow must parse candidate PowerShell trust-anchor files before publishing compatibility checks.'

# The protected compatibility job must still parse every candidate PowerShell
# file under Windows PowerShell 5.1. It never executes candidate code; it only
# uses the parser so a PowerShell 7-only syntax change cannot receive a green
# compatibility context.
$gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
$gitPath = [IO.Path]::GetFullPath([string]$gitCommand.Path)
$trackedPsOutput = [string]((& $gitPath -C $repositoryRoot ls-files -z -- '*.ps1') -join '')
Assert-Contract -Condition ($LASTEXITCODE -eq 0) -Message 'Git failed while enumerating candidate PowerShell files.'
$trackedPsFiles = @($trackedPsOutput.Split([char]0) | Where-Object { -not [string]::IsNullOrEmpty([string]$_) })
foreach ($relativePath in $trackedPsFiles) {
    if ([IO.Path]::IsPathRooted([string]$relativePath) -or
        [string]$relativePath -cmatch '(^|/)\.{1,2}(/|$)' -or
        [string]$relativePath -cmatch '[\x00\r\n]' -or
        [string]$relativePath.Contains('\')) {
        throw "Candidate PowerShell path is unsafe: $relativePath"
    }
    $candidatePath = Join-Path $repositoryRoot ([string]$relativePath)
    Assert-Contract -Condition (Test-Path -LiteralPath $candidatePath -PathType Leaf) `
        -Message "Candidate PowerShell file is missing: $relativePath"
    $candidateItem = Get-Item -LiteralPath $candidatePath -Force
    Assert-Contract -Condition (($candidateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) `
        -Message "Candidate PowerShell file is a reparse point: $relativePath"
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($candidatePath, [ref]$tokens, [ref]$errors) | Out-Null
    if (@($errors).Count -gt 0) {
        throw "Candidate PowerShell file does not parse under Windows PowerShell 5.1: $relativePath"
    }
}

Write-Host 'Windows PowerShell compatibility contract passed.'
