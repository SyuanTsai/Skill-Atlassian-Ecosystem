# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

#Requires -Version 7.3
[CmdletBinding(DefaultParameterSetName='Preview')]
param(
    [Parameter(Mandatory,ParameterSetName='Preview')][string]$Root,
    [Parameter(Mandatory,ParameterSetName='Preview')][string]$MappingPath,
    [Parameter(Mandatory,ParameterSetName='Preview')][string]$DocsCommit,
    [Parameter(ParameterSetName='Preview')][string]$CodeBindingPath,
    [Parameter(ParameterSetName='Preview')][string]$ReviewPath,
    [Parameter(ParameterSetName='Preview')][string]$CodeReviewPath,
    [Parameter(ParameterSetName='Preview')][ValidateSet('current','draft')][string]$PublishMode='current',
    [Parameter(Mandatory)][string]$PlanPath,
    [Parameter(Mandatory,ParameterSetName='Execute')][switch]$Execute,
    [Parameter(Mandatory,ParameterSetName='Execute')][string]$AuthorizationPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Write-PushResult {
    param([string]$Status,[string[]]$ReasonCodes,[object]$Fields)
    $result=[ordered]@{schemaVersion=1;status=$Status;reasonCodes=@($ReasonCodes)}
    if($null -ne $Fields){foreach($key in $Fields.Keys){$result[$key]=$Fields[$key]}}
    $result|ConvertTo-Json -Depth 12
    exit $(switch($Status){'preview'{0}'published'{0}drafted{0}'no-op'{0}'blocked'{10}'uncertain'{10}'invalid'{30}default{20}})
}

$skillInstallRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$accessPath=Join-Path $skillInstallRoot 'configure-confluence-api-access/scripts/Test-ConfluenceApiAccess.ps1'
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceValidation.psm1') -Force
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceMapping.psm1') -Force
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceMarkdownWorkflow.psm1') -Force
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluencePlan.psm1') -Force
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluencePublish.psm1') -Force
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceTransport.psm1') -Force
Import-Module -Name (Join-Path $PSScriptRoot 'StrictJson.psm1') -Force

try{
    if($PSCmdlet.ParameterSetName -eq 'Execute'){
        if(-not(Test-Path -LiteralPath $PlanPath -PathType Leaf) -or -not(Test-Path -LiteralPath $AuthorizationPath -PathType Leaf)){
            Write-PushResult -Status 'invalid' -ReasonCodes @('PlanOrAuthorizationUnavailable') -Fields $null
        }
        $plan=Read-Syp171StrictJsonFile -Path $PlanPath -Depth 18
        if($plan -is [System.Collections.IDictionary] -and $plan.schemaVersion -eq 5 -and
            $plan.Contains('publishMode') -and $plan.publishMode -ceq 'draft' -and
            (-not $plan.Contains('draftSnapshotTiming') -or $plan.draftSnapshotTiming -cne 'prewrite')){
            Write-PushResult -Status 'blocked' -ReasonCodes @('PlanRequiresRepreview') -Fields $null
        }
        if(-not(Test-ConfluencePlanShape -Plan $plan)){
            Write-PushResult -Status 'invalid' -ReasonCodes @('PlanSchemaInvalid') -Fields $null
        }
        $inputs=$plan.validationInputs
        $requiredInputKeys=@('docsCommit','mappingPath','root')
        $optionalInputKeys=@('codeBindingPath','codeReviewPath','reviewPath')
        if($inputs -isnot [System.Collections.IDictionary] -or
            @($requiredInputKeys|Where-Object {$_ -cnotin $inputs.Keys}).Count -gt 0 -or
            @($inputs.Keys|Where-Object {$_ -cnotin ($requiredInputKeys+$optionalInputKeys)}).Count -gt 0){
            Write-PushResult -Status 'blocked' -ReasonCodes @('ValidationInputsUnavailable') -Fields $null
        }
        $validationArgs=@{Root=[string]$inputs.root;MappingPath=[string]$inputs.mappingPath;DocsCommit=[string]$inputs.docsCommit}
        foreach($key in $optionalInputKeys){if($inputs.Contains($key)){$validationArgs[$key]=[string]$inputs[$key]}}
        $validation=Invoke-ConfluenceValidation @validationArgs
        if($validation.status -cne 'valid'){
            Write-PushResult -Status 'blocked' -ReasonCodes @('ValidationNotReady') -Fields @{validationStatus=$validation.status}
        }
        $site=[string]$validation.siteOrigin
        $planCloudId=[Guid]::Empty
        $validationCloudId=[Guid]::Empty
        if(-not [Guid]::TryParse([string]$plan.cloudId,[ref]$planCloudId) -or
            -not [Guid]::TryParse([string]$validation.cloudId,[ref]$validationCloudId) -or
            $planCloudId -ne $validationCloudId){
            Write-PushResult -Status 'blocked' -ReasonCodes @('ApiBaseMismatch') -Fields $null
        }
        $tenantReason=Test-ConfluenceTenantConfiguration -ExpectedSiteOrigin $site -ConfiguredSiteOrigin ([string]$env:CONFLUENCE_BASE_URL) `
            -ApiBase ([string]$env:CONFLUENCE_API_BASE_URL) -CloudId ([string]$env:CONFLUENCE_CLOUD_ID) -ExpectedCloudId ([string]$plan.cloudId)
        if(-not [string]::IsNullOrWhiteSpace([string]$tenantReason)){Write-PushResult -Status 'blocked' -ReasonCodes @([string]$tenantReason) -Fields $null}
        if(-not(Test-Path -LiteralPath $accessPath -PathType Leaf)){Write-PushResult -Status 'blocked' -ReasonCodes @('AccessValidatorUnavailable') -Fields $null}
        $access=& $accessPath -TestConnection
        if(-not(Test-ConfluenceSelectedSessionAccess -Access $access)){
            Write-PushResult -Status 'blocked' -ReasonCodes @('AccessNotReady') -Fields $null
        }
        $http=New-ConfluenceOperationInvoker -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $env:CONFLUENCE_BASE_URL `
            -ApiBase $env:CONFLUENCE_API_BASE_URL -CloudId $env:CONFLUENCE_CLOUD_ID -Email $env:CONFLUENCE_EMAIL -Token $env:CONFLUENCE_API_TOKEN
        $result=Invoke-ConfluencePlan -PlanPath $PlanPath -CurrentValidation $validation -AuthorizationPath $AuthorizationPath `
            -JournalPath "$PlanPath.journal.json" -SyncPath "$PlanPath.sync.json" -ExpectedSiteOrigin $site `
            -ApiBase $env:CONFLUENCE_API_BASE_URL -HttpInvoker $http
        Write-PushResult -Status $result.status -ReasonCodes $result.reasonCodes -Fields @{journalPath=$result.journalPath;syncPath=$result.syncPath}
    }

    $validationArgs=@{Root=$Root;MappingPath=$MappingPath;DocsCommit=$DocsCommit}
    if(-not [string]::IsNullOrWhiteSpace($CodeBindingPath)){$validationArgs.CodeBindingPath=$CodeBindingPath}
    if(-not [string]::IsNullOrWhiteSpace($ReviewPath)){$validationArgs.ReviewPath=$ReviewPath}
    if(-not [string]::IsNullOrWhiteSpace($CodeReviewPath)){$validationArgs.CodeReviewPath=$CodeReviewPath}
    $validation=Invoke-ConfluenceValidation @validationArgs
    if($validation.status -cne 'valid'){
        Write-PushResult -Status 'blocked' -ReasonCodes $validation.reasonCodes -Fields @{validationStatus=$validation.status}
    }
    $site=[string]$validation.siteOrigin
    $tenantReason=Test-ConfluenceTenantConfiguration -ExpectedSiteOrigin $site -ConfiguredSiteOrigin ([string]$env:CONFLUENCE_BASE_URL) `
        -ApiBase ([string]$env:CONFLUENCE_API_BASE_URL) -CloudId ([string]$env:CONFLUENCE_CLOUD_ID) -ExpectedCloudId ([string]$validation.cloudId)
    if(-not [string]::IsNullOrWhiteSpace([string]$tenantReason)){Write-PushResult -Status 'blocked' -ReasonCodes @([string]$tenantReason) -Fields $null}
    if(-not(Test-Path -LiteralPath $accessPath -PathType Leaf)){Write-PushResult -Status 'blocked' -ReasonCodes @('AccessValidatorUnavailable') -Fields $null}
    $access=& $accessPath -TestConnection
    if(-not(Test-ConfluenceSelectedSessionAccess -Access $access)){
        Write-PushResult -Status 'blocked' -ReasonCodes @('AccessNotReady') -Fields $null
    }
    $http=New-ConfluenceReadInvoker -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $env:CONFLUENCE_BASE_URL `
        -ApiBase $env:CONFLUENCE_API_BASE_URL -CloudId $env:CONFLUENCE_CLOUD_ID -Email $env:CONFLUENCE_EMAIL -Token $env:CONFLUENCE_API_TOKEN
    $previewArgs=@{
        Root=$Root;MappingPath=$MappingPath;DocsCommit=$DocsCommit;PlanPath=$PlanPath
        ExpectedSiteOrigin=$site;ApiBase=$env:CONFLUENCE_API_BASE_URL;HttpInvoker=$http;PublishMode=$PublishMode
    }
    if(-not [string]::IsNullOrWhiteSpace($CodeBindingPath)){$previewArgs.CodeBindingPath=$CodeBindingPath}
    if(-not [string]::IsNullOrWhiteSpace($ReviewPath)){$previewArgs.ReviewPath=$ReviewPath}
    if(-not [string]::IsNullOrWhiteSpace($CodeReviewPath)){$previewArgs.CodeReviewPath=$CodeReviewPath}
    $result=New-ConfluenceMarkdownPreviewPlan @previewArgs
    if($result.status -cne 'preview'){
        Write-PushResult -Status $result.status -ReasonCodes $result.reasonCodes -Fields @{validationStatus=$result.validation.status}
    }
    Write-PushResult -Status $result.status -ReasonCodes $result.reasonCodes -Fields @{
        planPath=$result.planPath;planSha256=$result.planSha256
        publishMode=$PublishMode.ToLowerInvariant()
    }
}catch{
    Write-PushResult -Status 'failed' -ReasonCodes @('PushFailure') -Fields $null
}
