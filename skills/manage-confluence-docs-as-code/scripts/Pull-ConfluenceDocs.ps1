# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $TargetPath,
    [Parameter(Mandatory)][string] $Root,
    [Parameter(Mandatory)][string] $ScopePath,
    [long] $MaxAttachmentDownloadBytes = 1GB,
    [int] $MaxAttachmentAttempts = 1000,
    [long] $MaxCaptureBytes = 1GB
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
if ($scope -isnot [System.Collections.IDictionary]) {
    Write-PullResult -Status 'invalid' -ReasonCodes @('ScopeSchemaInvalid') -CapturePath ''
}
foreach ($identityField in @('siteOrigin', 'cloudId', 'apiBase')) {
    if (-not $scope.Contains($identityField)) {
        Write-PullResult -Status 'invalid' -ReasonCodes @('ScopeSchemaInvalid') -CapturePath ''
    }
    if ($scope[$identityField] -isnot [string]) {
        Write-PullResult -Status 'invalid' -ReasonCodes @('ScopeSchemaInvalid') -CapturePath ''
    }
}
$scopeCloudId = $scope['cloudId']
$format = '\A[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\z'
if ($scopeCloudId.Length -ne 36 -or $scopeCloudId -cnotmatch $format) { Write-PullResult -Status 'invalid' -ReasonCodes @('ScopeSchemaInvalid') -CapturePath '' }
$parsedCloudId = [Guid]::Empty
if (-not [Guid]::TryParseExact($scopeCloudId, 'D', [ref] $parsedCloudId)) { Write-PullResult -Status 'invalid' -ReasonCodes @('ScopeSchemaInvalid') -CapturePath '' }
$scopeSiteOrigin = $scope['siteOrigin']
if ([string]::IsNullOrWhiteSpace($scopeSiteOrigin)) {
    Write-PullResult -Status 'invalid' -ReasonCodes @('ScopeSchemaInvalid') -CapturePath ''
}
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceTransport.psm1') -Force
$scopeApiBase = $scope['apiBase']
$tenantReason = Test-ConfluenceTenantConfiguration -ExpectedSiteOrigin ([string] $scope.siteOrigin) `
    -ConfiguredSiteOrigin ([string] $env:CONFLUENCE_BASE_URL) -ApiBase ([string] $env:CONFLUENCE_API_BASE_URL) -CloudId ([string] $env:CONFLUENCE_CLOUD_ID) `
    -ExpectedApiBase $scopeApiBase -ExpectedCloudId $scopeCloudId
if (-not [string]::IsNullOrWhiteSpace([string] $tenantReason)) {
    Write-PullResult -Status 'blocked' -ReasonCodes @([string] $tenantReason) -CapturePath ''
}

$corePath = Join-Path $PSScriptRoot 'ConfluenceDocs.psm1'
if (-not (Test-Path -LiteralPath $corePath -PathType Leaf)) { Write-PullResult -Status 'blocked' -ReasonCodes @('CaptureEngineUnavailable') -CapturePath '' }
Import-Module -Name $corePath -Force
$budgetReason = Test-ConfluenceCaptureBudgetLimits -MaxAttachmentDownloadBytes $MaxAttachmentDownloadBytes -MaxAttachmentAttempts $MaxAttachmentAttempts -MaxCaptureBytes $MaxCaptureBytes
if (-not [string]::IsNullOrWhiteSpace([string] $budgetReason)) {
    Write-PullResult -Status 'invalid' -ReasonCodes @([string] $budgetReason) -CapturePath ''
}
if (-not (Test-ConfluenceCapturePrivatePermissions)) {
    Write-PullResult -Status 'blocked' -ReasonCodes @('CapturePrivatePermissionsUnavailable') -CapturePath ''
}

$skillInstallRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$accessPath = Join-Path $skillInstallRoot 'configure-confluence-api-access/scripts/Test-ConfluenceApiAccess.ps1'
if (-not (Test-Path -LiteralPath $accessPath -PathType Leaf)) { Write-PullResult -Status 'blocked' -ReasonCodes @('AccessValidatorUnavailable') -CapturePath '' }
$access = & $accessPath -TestConnection
if (-not (Test-ConfluenceSelectedSessionAccess -Access $access)) {
    Write-PullResult -Status 'blocked' -ReasonCodes @('AccessNotReady') -CapturePath ''
}

try {
    $invoker = New-ConfluenceReadInvoker -ExpectedSiteOrigin $scope.siteOrigin -ConfiguredSiteOrigin $env:CONFLUENCE_BASE_URL          -ApiBase $env:CONFLUENCE_API_BASE_URL -CloudId $env:CONFLUENCE_CLOUD_ID -Email $env:CONFLUENCE_EMAIL -Token $env:CONFLUENCE_API_TOKEN
    $result = Invoke-ConfluenceCapture -Root $resolvedRoot -TargetPath $TargetPath -ScopePath $ScopePath -ExpectedSiteOrigin $scope.siteOrigin -HttpInvoker $invoker `
        -MaxAttachmentDownloadBytes $MaxAttachmentDownloadBytes -MaxAttachmentAttempts $MaxAttachmentAttempts -MaxCaptureBytes $MaxCaptureBytes
    Write-PullResult -Status $result.status -ReasonCodes $result.reasonCodes -CapturePath $result.capturePath
}
catch {
    Write-PullResult -Status 'failed' -ReasonCodes @('PullFailure') -CapturePath ''
}
