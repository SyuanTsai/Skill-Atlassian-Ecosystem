# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

#Requires -Version 7.0
[CmdletBinding(DefaultParameterSetName='Preview')]
param(
    [Parameter(Mandatory,ParameterSetName='Preview')][string]$Root,
    [Parameter(Mandatory,ParameterSetName='Preview')][string]$MappingPath,
    [Parameter(Mandatory,ParameterSetName='Preview')][string]$DocsCommit,
    [Parameter(Mandatory,ParameterSetName='Preview')][string]$CodeBindingPath,
    [Parameter(Mandatory,ParameterSetName='Preview')][string]$ReviewPath,
    [Parameter(Mandatory,ParameterSetName='Preview')][string]$RuntimeRoot,
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

$repositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$accessPath=Join-Path $repositoryRoot 'skills/configure-confluence-api-access/scripts/Test-ConfluenceApiAccess.ps1'
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceValidation.psm1') -Force
Import-Module -Name (Join-Path $PSScriptRoot 'OpenSpecSource.psm1') -Force
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceMapping.psm1') -Force
Import-Module -Name (Join-Path $PSScriptRoot 'StorageProjection.psm1') -Force
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
        $inputs=$plan.validationInputs
        if($inputs -isnot [System.Collections.IDictionary] -or
            (($inputs.Keys|Sort-Object)-join ',') -cne 'codeBindingPath,docsCommit,mappingPath,reviewPath,root,runtimeRoot'){
            Write-PushResult -Status 'blocked' -ReasonCodes @('ValidationInputsUnavailable') -Fields $null
        }
        $validation=Invoke-ConfluenceValidation -Root $inputs.root -MappingPath $inputs.mappingPath -DocsCommit $inputs.docsCommit `
            -CodeBindingPath $inputs.codeBindingPath -ReviewPath $inputs.reviewPath -RuntimeRoot $inputs.runtimeRoot
        if($validation.status -cne 'valid' -or $validation.publishEligibility -cne 'candidate'){
            Write-PushResult -Status 'blocked' -ReasonCodes @('CanonicalCandidateNotReady') -Fields @{validationStatus=$validation.status;publishEligibility=$validation.publishEligibility}
        }
        $site=[string]$validation.siteOrigin
        if([string]$env:CONFLUENCE_BASE_URL -cne $site){Write-PushResult -Status 'blocked' -ReasonCodes @('TenantMismatch') -Fields $null}
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

    $validation=Invoke-ConfluenceValidation -Root $Root -MappingPath $MappingPath -DocsCommit $DocsCommit `
        -CodeBindingPath $CodeBindingPath -ReviewPath $ReviewPath -RuntimeRoot $RuntimeRoot
    if($validation.status -cne 'valid'){
        Write-PushResult -Status 'blocked' -ReasonCodes $validation.reasonCodes -Fields @{validationStatus=$validation.status}
    }
    $site=[string]$validation.siteOrigin
    if([string]$env:CONFLUENCE_BASE_URL -cne $site){Write-PushResult -Status 'blocked' -ReasonCodes @('TenantMismatch') -Fields $null}
    if(-not(Test-Path -LiteralPath $accessPath -PathType Leaf)){Write-PushResult -Status 'blocked' -ReasonCodes @('AccessValidatorUnavailable') -Fields $null}
    $access=& $accessPath -TestConnection
    if(-not(Test-ConfluenceSelectedSessionAccess -Access $access)){
        Write-PushResult -Status 'blocked' -ReasonCodes @('AccessNotReady') -Fields $null
    }
    $mapping=Test-ConfluenceMapping -Root $Root -MappingPath $MappingPath -ExpectedSiteOrigin $site
    $source=Test-OpenSpecSource -Root $Root -ChangeId $validation.changeId -RuntimeRoot $RuntimeRoot
    if($mapping.status -cne 'valid' -or $source.status -cne 'valid'){
        Write-PushResult -Status 'blocked' -ReasonCodes @('SourceRevalidationFailed') -Fields $null
    }
    $payloads=[System.Collections.Generic.List[object]]::new()
    foreach($entry in @($mapping.entries)){
        $projection=ConvertTo-ConfluenceSpecStorage -SourceInventory $source -Validation $validation -RequirementId $entry.sourceSectionId `
            -Root $Root -ProjectionId $entry.projectionId -ManagedAssets @($entry.assets) `
            -LinkBindings @($entry.linkBindings) -PageMappings @($mapping.entries)
        if($projection.status -cnotin @('supported','deferred')){
            Write-PushResult -Status 'blocked' -ReasonCodes $projection.reasonCodes -Fields @{projectionId=$entry.projectionId}
        }
        $deferredTargets=@()
        if($projection.status -ceq 'deferred'){$deferredTargets=@($projection.deferredTargets)}
        $payloads.Add([pscustomobject]@{
            projectionId=$entry.projectionId;pageId=$entry.pageId;spaceId=$entry.spaceId;parentId=$entry.parentId
            parentProjectionId=$entry.parentProjectionId
            title=$entry.title;bodyStorage=$(if($projection.status -ceq 'deferred'){$projection.storageTemplate}else{$projection.storage})
            deferredTargets=$deferredTargets
            assetChanges=@($entry.assets)
        })
    }
    $http=New-ConfluenceReadInvoker -ExpectedSiteOrigin $site -ConfiguredSiteOrigin $env:CONFLUENCE_BASE_URL `
        -ApiBase $env:CONFLUENCE_API_BASE_URL -CloudId $env:CONFLUENCE_CLOUD_ID -Email $env:CONFLUENCE_EMAIL -Token $env:CONFLUENCE_API_TOKEN
    $inputs=[ordered]@{
        root=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
        mappingPath=[IO.Path]::GetFullPath($MappingPath);docsCommit=$DocsCommit
        codeBindingPath=[IO.Path]::GetFullPath($CodeBindingPath);reviewPath=[IO.Path]::GetFullPath($ReviewPath)
        runtimeRoot=[IO.Path]::GetFullPath($RuntimeRoot)
    }
    $result=New-ConfluencePreviewPlan -PlanPath $PlanPath -Validation $validation -Payloads $payloads.ToArray() `
        -ExpectedSiteOrigin $site -ApiBase $env:CONFLUENCE_API_BASE_URL -HttpInvoker $http -ValidationInputs $inputs -PublishMode $PublishMode
    Write-PushResult -Status $result.status -ReasonCodes $result.reasonCodes -Fields @{
        planPath=$result.planPath;planSha256=$result.planSha256;publishEligibility=$validation.publishEligibility
        publishMode=$PublishMode
        scenarioAcceptance=$validation.scenarioAcceptance;scenarioIds=@($validation.scenarioIds)
    }
}catch{
    Write-PushResult -Status 'failed' -ReasonCodes @('PushFailure') -Fields $null
}
