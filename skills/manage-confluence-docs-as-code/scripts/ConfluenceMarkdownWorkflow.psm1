# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceMapping.psm1') -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluenceValidation.psm1') -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'MarkdownProjection.psm1') -Scope Local
Import-Module -Name (Join-Path $PSScriptRoot 'ConfluencePlan.psm1') -Scope Local

function Get-MarkdownPreviewScopeBlockers {
    param([object[]]$Payloads,[System.Collections.IDictionary]$ScopeRecord,[string]$Mode)
    if($Mode -ceq 'draft'){
        return [pscustomobject]@{reasonCode='DraftScopeUnsupported';blockers=@(Get-ConfluenceDraftScopeBlockers -Payloads $Payloads)}
    }
    $excluded=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($entry in @($ScopeRecord.excludedEntries)){$null=$excluded.Add([string]$entry.projectionId)}
    $blockers=[System.Collections.Generic.List[object]]::new()
    foreach($payload in $Payloads){
        $codes=[System.Collections.Generic.List[string]]::new()
        $targets=@(@($payload.deferredTargets)|Where-Object {$excluded.Contains([string]$_)}|ForEach-Object {[string]$_})
        if($targets.Count -gt 0){$codes.Add('LinkTargetExcluded')}
        if([string]$payload.parentProjectionId -ne '' -and $excluded.Contains([string]$payload.parentProjectionId)){$codes.Add('ParentExcluded')}
        if($codes.Count -gt 0){
            $blockers.Add((New-ConfluenceScopeBlocker -ProjectionId ([string]$payload.projectionId) -ReasonCodes $codes.ToArray() -LinkTargets $targets))
        }
    }
    $blockers.Sort([Comparison[object]]{param($left,$right)[string]::CompareOrdinal([string]$left.projectionId,[string]$right.projectionId)})
    return [pscustomobject]@{reasonCode='ProjectionScopeDependencyExcluded';blockers=@($blockers.ToArray())}
}

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
        [ValidateSet('current','draft')][string]$PublishMode='current',
        [AllowEmptyCollection()][AllowNull()][string[]]$ProjectionScope
    )
    $mode=$PublishMode.ToLowerInvariant()
    $scoped=$PSBoundParameters.ContainsKey('ProjectionScope')
    $InvokeConfluenceValidationParameters = @{
        Root = $Root
        MappingPath = $MappingPath
        DocsCommit = $DocsCommit
        CodeBindingPath = $CodeBindingPath
        ReviewPath = $ReviewPath
        CodeReviewPath = $CodeReviewPath
    }
    $validation=Invoke-ConfluenceValidation @InvokeConfluenceValidationParameters
    if($validation.status -cne 'valid'){
        return [pscustomobject]@{status=$validation.status;reasonCodes=@($validation.reasonCodes);validation=$validation;planPath='';planSha256=''}
    }
    $rootFull=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    $mappingFull=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $MappingPath).Path)
    $mappingRelative=[IO.Path]::GetRelativePath($rootFull,$mappingFull)
    $gitPathSeparator = '/'
    $mappingRelative=$mappingRelative.Replace([string][IO.Path]::DirectorySeparatorChar,$gitPathSeparator)
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
    $scopeRecord=$null
    if($scoped){
        $scopeRecord=New-ConfluenceProjectionScopeRecord -Entries @($mapping.entries) -ProjectionIds $ProjectionScope
        if($null -eq $scopeRecord){
            return [pscustomobject]@{status='invalid';reasonCodes=@('ProjectionScopeInvalid');validation=$validation;planPath='';planSha256='';blockers=@();projectionScope=$null}
        }
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
        $ConvertToConfluenceMarkdownStorageParameters = @{
            Markdown = $markdown
            Root = $rootFull
            SourcePath = ([string]$entry.sourceArtifact)
            ProjectionId = ([string]$entry.projectionId)
            ManagedAssets = @($entry.assets)
            LinkBindings = @($entry.linkBindings)
            PageMappings = @($mapping.entries)
            SourceSnapshots = $sourceSnapshots
            SiteOrigin = ([string]$validation.siteOrigin)
        }
        $projection=ConvertTo-ConfluenceMarkdownStorage @ConvertToConfluenceMarkdownStorageParameters
        if($projection.status -notin @('supported','deferred')){
            return [pscustomobject]@{status='blocked';reasonCodes=@($projection.reasonCodes);validation=$validation;planPath='';planSha256=''}
        }
        if($scoped -and [string]$entry.projectionId -cnotin @($scopeRecord.projectionIds)){continue}
        $payloads.Add([pscustomobject]@{
            projectionId=[string]$entry.projectionId;pageId=[string]$entry.pageId;spaceId=[string]$entry.spaceId
            parentId=[string]$entry.parentId;parentProjectionId=[string]$entry.parentProjectionId;title=[string]$entry.title
            bodyStorage=$(if($projection.status -ceq 'deferred'){[string]$projection.storageTemplate}else{[string]$projection.storage})
            deferredTargets=@($projection.deferredTargets);assetChanges=@($entry.assets)
        })
    }
    if($scoped){
        $scopeBlockers=Get-MarkdownPreviewScopeBlockers -Payloads $payloads.ToArray() -ScopeRecord $scopeRecord -Mode $mode
        if(@($scopeBlockers.blockers).Count -gt 0){
            return [pscustomobject]@{status='blocked';reasonCodes=@($scopeBlockers.reasonCode);validation=$validation;planPath='';planSha256=''
                blockers=@($scopeBlockers.blockers);projectionScope=$scopeRecord}
        }
    }
    $InvokeConfluenceValidationParameters = @{
        Root = $Root
        MappingPath = $MappingPath
        DocsCommit = $DocsCommit
        CodeBindingPath = $CodeBindingPath
        ReviewPath = $ReviewPath
        CodeReviewPath = $CodeReviewPath
    }
    $stable=Invoke-ConfluenceValidation @InvokeConfluenceValidationParameters
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
    $NewConfluencePreviewPlanParameters = @{
        PlanPath = $PlanPath
        Validation = $validation
        Payloads = $payloads.ToArray()
        ExpectedSiteOrigin = $ExpectedSiteOrigin
        ApiBase = $ApiBase
        HttpInvoker = $HttpInvoker
        ValidationInputs = $inputs
        PublishMode = $mode
    }
    if($scoped){$NewConfluencePreviewPlanParameters.ProjectionScope=$scopeRecord}
    $plan=New-ConfluencePreviewPlan @NewConfluencePreviewPlanParameters
    return [pscustomobject]@{
        status=$plan.status;reasonCodes=@($plan.reasonCodes);validation=$validation;planPath=$plan.planPath;planSha256=$plan.planSha256
        blockers=@($plan.blockers);projectionScope=$scopeRecord
    }
}

Export-ModuleMember -Function New-ConfluenceMarkdownPreviewPlan
