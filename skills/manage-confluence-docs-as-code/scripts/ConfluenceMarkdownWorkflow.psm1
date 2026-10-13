# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceMapping.psm1') -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceValidation.psm1') -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'MarkdownProjection.psm1') -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluencePlan.psm1') -Scope Local

function New-ConfluenceMarkdownPreviewPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$MappingPath,
        [Parameter(Mandatory)][string]$DocsCommit,
        [string]$CodeBindingPath='',
        [string]$ReviewPath='',
        [string]$CodeReviewPath='',
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$ExpectedSiteOrigin,
        [Parameter(Mandatory)][string]$ApiBase,
        [Parameter(Mandatory)][scriptblock]$HttpInvoker,
        [ValidateSet('current','draft')][string]$PublishMode='current'
    )
    $mode=$PublishMode.ToLowerInvariant()
    $validation=Invoke-ConfluenceValidation -Root $Root -MappingPath $MappingPath -DocsCommit $DocsCommit `
        -CodeBindingPath $CodeBindingPath -ReviewPath $ReviewPath -CodeReviewPath $CodeReviewPath
    if($validation.status -cne 'valid'){
        return [pscustomobject]@{status=$validation.status;reasonCodes=@($validation.reasonCodes);validation=$validation;planPath='';planSha256=''}
    }
    $rootFull=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $mappingFull=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $MappingPath).Path)
    $mappingRelative=[IO.Path]::GetRelativePath($rootFull,$mappingFull).Replace([string][IO.Path]::DirectorySeparatorChar,'/')
    try{$committedMapping=Get-ConfluenceCommittedBlob -Root $rootFull -Commit $DocsCommit -Path $mappingRelative}
    catch{return [pscustomobject]@{status='blocked';reasonCodes=@('MappingCommitMismatch');validation=$validation;planPath='';planSha256=''}}
    $committedMappingDigest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$committedMapping.bytes)).ToLowerInvariant()
    $mapping=Test-ConfluenceMapping -Root $rootFull -MappingPath $MappingPath -ExpectedSiteOrigin $ExpectedSiteOrigin
    if($mapping.status -cne 'valid'){
        return [pscustomobject]@{status='blocked';reasonCodes=@($mapping.reasonCodes);validation=$validation;planPath='';planSha256=''}
    }
    if($mapping.mappingSha256 -cne $validation.mappingWorkingDigest -or $committedMappingDigest -cne $validation.mappingDigest){
        return [pscustomobject]@{status='blocked';reasonCodes=@('MappingCommitMismatch');validation=$validation;planPath='';planSha256=''}
    }
    $sourceSnapshots=[System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach($entry in @($mapping.entries)){
        $sourcePath=[string]$entry.sourceArtifact
        try{
            $committedSource=Get-ConfluenceCommittedBlob -Root $rootFull -Commit $DocsCommit -Path $sourcePath
            $sourceSnapshots.Add($sourcePath,[Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$committedSource.bytes))
        }catch{
            return [pscustomobject]@{status='invalid';reasonCodes=@('MarkdownSourceInvalid');validation=$validation;planPath='';planSha256=''}
        }
    }
    $payloads=[System.Collections.Generic.List[object]]::new()
    foreach($entry in @($mapping.entries)){
        $markdown=$sourceSnapshots[[string]$entry.sourceArtifact]
        $projection=ConvertTo-ConfluenceMarkdownStorage -Markdown $markdown -Root $rootFull -SourcePath ([string]$entry.sourceArtifact) `
            -ProjectionId ([string]$entry.projectionId) -ManagedAssets @($entry.assets) -LinkBindings @($entry.linkBindings) `
            -PageMappings @($mapping.entries) -SourceSnapshots $sourceSnapshots -SiteOrigin ([string]$validation.siteOrigin)
        if($projection.status -notin @('supported','deferred')){
            return [pscustomobject]@{status='blocked';reasonCodes=@($projection.reasonCodes);validation=$validation;planPath='';planSha256=''}
        }
        $payloads.Add([pscustomobject]@{
            projectionId=[string]$entry.projectionId;pageId=[string]$entry.pageId;spaceId=[string]$entry.spaceId
            parentId=[string]$entry.parentId;parentProjectionId=[string]$entry.parentProjectionId;title=[string]$entry.title
            bodyStorage=$(if($projection.status -ceq 'deferred'){[string]$projection.storageTemplate}else{[string]$projection.storage})
            deferredTargets=@($projection.deferredTargets);assetChanges=@($entry.assets)
        })
    }
    $stable=Invoke-ConfluenceValidation -Root $Root -MappingPath $MappingPath -DocsCommit $DocsCommit `
        -CodeBindingPath $CodeBindingPath -ReviewPath $ReviewPath -CodeReviewPath $CodeReviewPath
    if($stable.status -cne 'valid' -or $stable.docsCommit -cne $validation.docsCommit -or
        $stable.sourceDigest -cne $validation.sourceDigest -or $stable.mappingDigest -cne $validation.mappingDigest -or
        $stable.mappingWorkingDigest -cne $validation.mappingWorkingDigest -or
        $stable.reviewDigest -cne $validation.reviewDigest -or $stable.codeCommit -cne $validation.codeCommit -or
        $stable.sourceMode -cne $validation.sourceMode -or $stable.rendererVersion -cne $validation.rendererVersion){
        return [pscustomobject]@{status='blocked';reasonCodes=@('SourceChangedDuringPreview');validation=$validation;planPath='';planSha256=''}
    }
    $inputs=[ordered]@{root=$rootFull;mappingPath=$mappingFull;docsCommit=$DocsCommit}
    if(-not [string]::IsNullOrWhiteSpace($CodeBindingPath)){$inputs['codeBindingPath']=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $CodeBindingPath).Path)}
    if(-not [string]::IsNullOrWhiteSpace($ReviewPath)){$inputs['reviewPath']=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ReviewPath).Path)}
    if(-not [string]::IsNullOrWhiteSpace($CodeReviewPath)){$inputs['codeReviewPath']=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $CodeReviewPath).Path)}
    $plan=New-ConfluencePreviewPlan -PlanPath $PlanPath -Validation $validation -Payloads $payloads.ToArray() `
        -ExpectedSiteOrigin $ExpectedSiteOrigin -ApiBase $ApiBase -HttpInvoker $HttpInvoker -ValidationInputs $inputs -PublishMode $mode
    return [pscustomobject]@{
        status=$plan.status;reasonCodes=@($plan.reasonCodes);validation=$validation;planPath=$plan.planPath;planSha256=$plan.planSha256
    }
}

Export-ModuleMember -Function New-ConfluenceMarkdownPreviewPlan
