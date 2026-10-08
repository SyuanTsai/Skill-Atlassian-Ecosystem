# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $TargetPath,
    [Parameter(Mandatory)][string] $Root,
    [Parameter(Mandatory)][string] $ScopePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'StrictJson.psm1') -Force

function Write-PullResult {
    param([string] $Status, [string[]] $ReasonCodes, [string] $CapturePath)
    [pscustomobject]@{
        schemaVersion = 1; status = $Status; reasonCodes = @($ReasonCodes)
        capturePath = $CapturePath; nextAction = if ($Status -eq 'complete') { 'review-captured-candidates' } else { 'resolve-reason-codes' }
    } | ConvertTo-Json -Depth 5
    exit $(switch ($Status) { 'complete' { 0 } 'blocked' { 10 } 'partial' { 10 } 'invalid' { 30 } default { 20 } })
}

function Test-InRoot {
    param([string] $SelectedRoot, [string] $SelectedPath)
    $relative = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($SelectedRoot), [IO.Path]::GetFullPath($SelectedPath))
    return $relative -ceq '.' -or ($relative -cne '..' -and -not $relative.StartsWith("..$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::Ordinal) -and -not [IO.Path]::IsPathRooted($relative))
}

if (-not (Test-Path -LiteralPath $Root -PathType Container)) { Write-PullResult -Status 'invalid' -ReasonCodes @('RootUnavailable') -CapturePath '' }
$resolvedRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
if (-not (Test-InRoot -SelectedRoot $resolvedRoot -SelectedPath $TargetPath) -or
    -not (Test-InRoot -SelectedRoot $resolvedRoot -SelectedPath $ScopePath) -or
    -not (Test-Path -LiteralPath $ScopePath -PathType Leaf)) {
    Write-PullResult -Status 'invalid' -ReasonCodes @('InputOutsideRoot') -CapturePath ''
}
try { $scope = Read-Syp171StrictJsonFile -Path $ScopePath -Depth 10 }
catch { Write-PullResult -Status 'invalid' -ReasonCodes @('ScopeSchemaInvalid') -CapturePath '' }
if ($scope -isnot [System.Collections.IDictionary] -or [string]::IsNullOrWhiteSpace([string] $scope.siteOrigin)) {
    Write-PullResult -Status 'invalid' -ReasonCodes @('ScopeSchemaInvalid') -CapturePath ''
}
if ([string] $env:CONFLUENCE_BASE_URL -cne [string] $scope.siteOrigin) {
    Write-PullResult -Status 'blocked' -ReasonCodes @('TenantMismatch') -CapturePath ''
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$accessPath = Join-Path $repositoryRoot 'skills/configure-confluence-api-access/scripts/Test-ConfluenceApiAccess.ps1'
if (-not (Test-Path -LiteralPath $accessPath -PathType Leaf)) { Write-PullResult -Status 'blocked' -ReasonCodes @('AccessValidatorUnavailable') -CapturePath '' }
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceTransport.psm1') -Force
$access = & $accessPath -TestConnection
if (-not (Test-ConfluenceSelectedSessionAccess -Access $access)) {
    Write-PullResult -Status 'blocked' -ReasonCodes @('AccessNotReady') -CapturePath ''
}

$corePath = Join-Path $PSScriptRoot 'ConfluenceDocs.psm1'
Import-Module -Name $corePath -Force
try {
    $invoker = New-ConfluenceReadInvoker -ExpectedSiteOrigin $scope.siteOrigin -ConfiguredSiteOrigin $env:CONFLUENCE_BASE_URL `
        -ApiBase $env:CONFLUENCE_API_BASE_URL -CloudId $env:CONFLUENCE_CLOUD_ID -Email $env:CONFLUENCE_EMAIL -Token $env:CONFLUENCE_API_TOKEN
    $result = Invoke-ConfluenceCapture -Root $resolvedRoot -TargetPath $TargetPath -ScopePath $ScopePath -ExpectedSiteOrigin $scope.siteOrigin -HttpInvoker $invoker
    Write-PullResult -Status $result.status -ReasonCodes $result.reasonCodes -CapturePath $result.capturePath
}
catch {
    Write-PullResult -Status 'failed' -ReasonCodes @('PullFailure') -CapturePath ''
}
